# Suivi mémoire Star Citizen — petite application (fenêtre)
# Lancer avec le raccourci « Suivi mémoire SC » (dossier parent).
#
# - Indicateur en continu (nominal / attention / critique) + courbe des 30 dernières minutes
# - Alerte sonore au passage du seuil, puis à chaque palier de 10 Go supplémentaire
# - Tracking : CSV (séparateur ;) dans ..\tracking, démarrage/arrêt automatiques avec le jeu (option),
#   copie du Game.log de la session à la fin (+ ceux de logbackups si le jeu a été relancé pendant la session)
# - Repères : Ctrl+Alt+R (même en jeu) + repères automatiques lus en direct dans le Game.log
# - Ctrl+Alt+D : afficher / masquer la fenêtre (même en jeu, sans lui voler le focus)
# - Capteurs : CPU (charge, fréquence), GPU NVIDIA (charge, température, puissance, fréquence, ventilateur),
#   disque et pagination ; température CPU via MSI Afterburner s'il tourne (Windows ne la donne pas sans admin)
# - Analyse : sessions enregistrées en panneaux superposés (mémoire, vitesse mémoire SC, charge, températures, puissance, fréquences, disque)
# - Fuite mémoire : vitesse de la mémoire validée de SC (pente 15 s / 30 s, Mo/s) et état « FUITE SUSPECTÉE »
#   quand la hausse dépasse un seuil pendant une durée donnée (début estimé, repères, son, colonnes du CSV)
# - Capture des incidents : tampon circulaire (une mesure toutes les 5 s, 1 par seconde dès qu'une hausse est
#   suspectée) ; à la confirmation, fichier incident_*.csv avec les 2 min d'avant + la suite, écrit à chaque mesure
# - Mémoire détaillée, sans confondre :
#     RAM physique (Working Set, Private Working Set, RAM disponible) — ce qui est réellement en mémoire vive ;
#     mémoire engagée / validée (Private Bytes de SC, total système, limite d'engagement = RAM + fichier d'échange) ;
#     mémoire virtuelle (Virtual Bytes) — espace d'adresses réservé : ne consomme ni RAM ni engagement tant qu'il
#     n'est pas engagé (plusieurs To sont normaux en 64 bits).
#   Défauts de page : la plupart sont « doux » (page déjà en RAM ou page neuve) ; seuls les défauts durs lisent le disque.

param([int]$TestSeconds = 0, [switch]$TestTrack, [string]$Snapshot = '', [string]$TestLog = '')

$ErrorActionPreference = 'Stop'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $AppDir
$TrackDir = Join-Path $Root 'tracking'
# dossier du jeu : détecté depuis StarCitizen.exe en cours d'exécution (n'importe quel disque, LIVE / PTU…),
# mémorisé dans les réglages ; emplacement par défaut tant que le jeu n'a jamais été vu
$GameDir = 'C:\Program Files\Roberts Space Industries\StarCitizen\LIVE'
$GameLog = if ($TestLog) { $TestLog } else { Join-Path $GameDir 'Game.log' }
$AppStart = Get-Date
function Set-GameDir([string]$dir) { if ($TestLog -or -not $dir) { return }; $script:GameDir = $dir; $script:GameLog = Join-Path $dir 'Game.log' }
$SettingsFile = Join-Path $AppDir 'reglages.json'
$ErrFile = Join-Path $AppDir 'erreurs.log'
if (-not (Test-Path $TrackDir)) { New-Item -ItemType Directory -Path $TrackDir | Out-Null }

function Log-Error($msg) { try { "$(Get-Date -Format s)  $msg" | Out-File -FilePath $ErrFile -Append -Encoding utf8 } catch { } }

try {
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Core -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class SCMem {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    // PID de la fenêtre au premier plan (détection des alt-tab)
    public static int ForegroundPid() { uint pid = 0; IntPtr h = GetForegroundWindow(); if (h != IntPtr.Zero) GetWindowThreadProcessId(h, out pid); return (int)pid; }
    [StructLayout(LayoutKind.Sequential)]
    public struct PERFORMANCE_INFORMATION {
        public uint cb; public UIntPtr CommitTotal; public UIntPtr CommitLimit; public UIntPtr CommitPeak;
        public UIntPtr PhysicalTotal; public UIntPtr PhysicalAvailable; public UIntPtr SystemCache;
        public UIntPtr KernelTotal; public UIntPtr KernelPaged; public UIntPtr KernelNonpaged;
        public UIntPtr PageSize; public uint HandleCount; public uint ProcessCount; public uint ThreadCount;
    }
    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool GetPerformanceInfo(out PERFORMANCE_INFORMATION pi, uint cb);
    // [0] validée, [1] limite, [2] RAM physique disponible (octets)
    public static double[] Commit() {
        PERFORMANCE_INFORMATION pi;
        GetPerformanceInfo(out pi, (uint)Marshal.SizeOf(typeof(PERFORMANCE_INFORMATION)));
        double page = (double)pi.PageSize.ToUInt64();
        return new double[] { pi.CommitTotal.ToUInt64() * page, pi.CommitLimit.ToUInt64() * page, pi.PhysicalAvailable.ToUInt64() * page };
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    // barre de titre sombre (Windows 10/11) ; couleurs au format 0x00BBGGRR
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    // texte gris affiché dans une zone de saisie vide (EM_SETCUEBANNER)
    public static void Cue(IntPtr h, string text) { SendMessage(h, 0x1501, (IntPtr)1, text); }
    // déplacer la fenêtre en cliquant n'importe où dessus (comme sur la barre de titre : WM_NCLBUTTONDOWN + HTCAPTION)
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    public static void DragWindow(IntPtr h) { ReleaseCapture(); SendMessage(h, 0xA1, (IntPtr)2, IntPtr.Zero); }
    // réafficher une fenêtre réduite dans la barre des tâches sans l'activer (SW_SHOWNOACTIVATE) : le jeu garde le focus
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    public static void ShowNoActivate(IntPtr h) { ShowWindow(h, 4); }
    public static void DarkTitle(IntPtr h, int caption, int border, int text) {
        int one = 1;
        DwmSetWindowAttribute(h, 20, ref one, 4);
        DwmSetWindowAttribute(h, 35, ref caption, 4);
        DwmSetWindowAttribute(h, 34, ref border, 4);
        DwmSetWindowAttribute(h, 36, ref text, 4);
    }
}
// raccourcis clavier globaux Ctrl+Alt+R (repère) et Ctrl+Alt+D (afficher / masquer) via hook clavier bas niveau (WH_KEYBOARD_LL).
// RegisterHotKey ne suffit pas : Star Citizen lit le clavier en raw input sans les raccourcis système
// (RIDEV_NOHOTKEYS), donc WM_HOTKEY n'arrive jamais quand le jeu a le focus. Le hook tourne sur son
// propre thread (boucle de messages dédiée) pour ne jamais retarder les frappes, même si l'interface est occupée.
// La touche n'est pas interceptée : elle continue vers l'application active.
public static class SCKeyHook {
    public static int Count = 0;    // Ctrl+Alt+R
    public static int CountD = 0;   // Ctrl+Alt+D
    public static bool Ok = false;
    delegate IntPtr LLProc(int nCode, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, LLProc fn, IntPtr hMod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint tid, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    static LLProc proc = Hook;   // référence gardée : le délégué ne doit pas être collecté
    static IntPtr hook = IntPtr.Zero;
    static uint tid = 0;
    static bool down = false, downD = false;
    public static bool Start() {
        if (tid != 0) return Ok;
        var ready = new System.Threading.ManualResetEvent(false);
        var t = new System.Threading.Thread(() => {
            tid = GetCurrentThreadId();
            hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);
            Ok = hook != IntPtr.Zero;
            ready.Set();
            if (!Ok) return;
            MSG m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
            UnhookWindowsHookEx(hook); hook = IntPtr.Zero;
        });
        t.IsBackground = true; t.Start();
        ready.WaitOne(3000);
        return Ok;
    }
    public static void Stop() { if (tid != 0) PostThreadMessage(tid, 0x0012, IntPtr.Zero, IntPtr.Zero); }   // WM_QUIT
    static IntPtr Hook(int n, IntPtr w, IntPtr l) {
        int vk = n >= 0 ? Marshal.ReadInt32(l) : 0;
        if (vk == 0x52 || vk == 0x44) {                 // touches R / D
            bool isR = vk == 0x52;
            int msg = w.ToInt32();
            if (msg == 0x100 || msg == 0x104) {         // WM_KEYDOWN / WM_SYSKEYDOWN
                bool mods = (GetAsyncKeyState(0x11) & 0x8000) != 0 && (GetAsyncKeyState(0x12) & 0x8000) != 0;   // Ctrl + Alt (AltGr inclus)
                if (isR) { if (mods && !down) Count++; down = mods; }          // ignore la répétition auto tant que la touche reste enfoncée
                else { if (mods && !downD) CountD++; downD = mods; }
            } else if (msg == 0x101 || msg == 0x105) { if (isR) down = false; else downD = false; }
        }
        return CallNextHookEx(hook, n, w, l);
    }
}
// compteurs de performance Windows par leur nom anglais (fonctionne sur un Windows en français)
public class SCPdh {
    [StructLayout(LayoutKind.Explicit)] struct FMT { [FieldOffset(0)] public uint CStatus; [FieldOffset(8)] public double Value; }
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhOpenQuery(string src, IntPtr user, out IntPtr q);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhAddEnglishCounter(IntPtr q, string path, IntPtr user, out IntPtr c);
    [DllImport("pdh.dll")] static extern int PdhCollectQueryData(IntPtr q);
    [DllImport("pdh.dll")] static extern int PdhGetFormattedCounterValue(IntPtr c, uint fmt, IntPtr type, out FMT v);
    IntPtr q; IntPtr[] cs;
    public SCPdh(string[] paths) {
        PdhOpenQuery(null, IntPtr.Zero, out q); cs = new IntPtr[paths.Length];
        for (int i = 0; i < paths.Length; i++) { IntPtr c; cs[i] = PdhAddEnglishCounter(q, paths[i], IntPtr.Zero, out c) == 0 ? c : IntPtr.Zero; }
        PdhCollectQueryData(q);
    }
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhGetFormattedCounterArray(IntPtr c, uint fmt, ref uint size, ref uint count, IntPtr buf);
    // compteur à instances multiples « \GPU Engine(*)\Utilization Percentage » : charge GPU comme le Gestionnaire des
    // tâches = moteur le plus chargé (somme des processus par moteur), limité à la carte dont le LUID est donné
    public double GpuEngineMax(int idx, string luid) {
        if (idx >= cs.Length || cs[idx] == IntPtr.Zero) return double.NaN;
        uint size = 0, count = 0;
        PdhGetFormattedCounterArray(cs[idx], 0x200 | 0x8000, ref size, ref count, IntPtr.Zero);
        if (size == 0) return double.NaN;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (PdhGetFormattedCounterArray(cs[idx], 0x200 | 0x8000, ref size, ref count, buf) != 0) return double.NaN;
            var perEngine = new System.Collections.Generic.Dictionary<string, double>();
            int item = IntPtr.Size + 16;   // PDH_FMT_COUNTERVALUE_ITEM : nom + valeur
            for (int i = 0; i < count; i++) {
                IntPtr p = buf + i * item;
                string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p));
                if (name == null || (luid != null && name.IndexOf(luid, StringComparison.OrdinalIgnoreCase) < 0)) continue;
                if ((uint)Marshal.ReadInt32(p, IntPtr.Size) > 1) continue;   // valeur pas encore valide
                double v = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(p, IntPtr.Size + 8));
                int k = name.IndexOf("_eng_"); string eng = k >= 0 ? name.Substring(k) : name;   // « _eng_N_engtype_X »
                double cur; perEngine.TryGetValue(eng, out cur); perEngine[eng] = cur + v;
            }
            double best = 0; foreach (double v in perEngine.Values) if (v > best) best = v;
            return Math.Min(100, best);
        } finally { Marshal.FreeHGlobal(buf); }
    }
    // somme des instances d'un compteur à instances multiples dont le nom contient filter
    // (ex. « \GPU Process Memory(*)\Dedicated Usage » filtré sur « pid_1234_ » = VRAM d'un processus) ; NaN si aucune
    public double ArraySum(int idx, string filter) {
        if (idx >= cs.Length || cs[idx] == IntPtr.Zero) return double.NaN;
        uint size = 0, count = 0;
        PdhGetFormattedCounterArray(cs[idx], 0x200 | 0x8000, ref size, ref count, IntPtr.Zero);
        if (size == 0) return double.NaN;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (PdhGetFormattedCounterArray(cs[idx], 0x200 | 0x8000, ref size, ref count, buf) != 0) return double.NaN;
            int item = IntPtr.Size + 16; double sum = 0; bool any = false;
            for (int i = 0; i < count; i++) {
                IntPtr p = buf + i * item;
                string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p));
                if (name == null || (filter != null && name.IndexOf(filter, StringComparison.OrdinalIgnoreCase) < 0)) continue;
                if ((uint)Marshal.ReadInt32(p, IntPtr.Size) > 1) continue;
                sum += BitConverter.Int64BitsToDouble(Marshal.ReadInt64(p, IntPtr.Size + 8)); any = true;
            }
            return any ? sum : double.NaN;
        } finally { Marshal.FreeHGlobal(buf); }
    }
    // valeurs moyennes depuis l'appel précédent ; NaN si indisponible
    public double[] Read() {
        PdhCollectQueryData(q); double[] r = new double[cs.Length];
        for (int i = 0; i < cs.Length; i++) {
            r[i] = double.NaN; if (cs[i] == IntPtr.Zero) continue;
            FMT v; if (PdhGetFormattedCounterValue(cs[i], 0x200 | 0x8000, IntPtr.Zero, out v) == 0 && v.CStatus <= 1) r[i] = v.Value;   // DOUBLE | NOCAP100
        }
        return r;
    }
}
// GPU NVIDIA via nvml.dll (installée avec le pilote) : charge, température, puissance, fréquence, ventilateur
public static class SCNvml {
    [StructLayout(LayoutKind.Sequential)] struct Util { public uint gpu; public uint memory; }
    [DllImport("nvml.dll")] static extern int nvmlInit_v2();
    [DllImport("nvml.dll")] static extern int nvmlDeviceGetHandleByIndex_v2(uint i, out IntPtr d);
    [DllImport("nvml.dll")] static extern int nvmlDeviceGetUtilizationRates(IntPtr d, out Util u);
    [DllImport("nvml.dll")] static extern int nvmlDeviceGetTemperature(IntPtr d, int sensor, out uint t);
    [DllImport("nvml.dll")] static extern int nvmlDeviceGetPowerUsage(IntPtr d, out uint mw);
    [DllImport("nvml.dll")] static extern int nvmlDeviceGetClockInfo(IntPtr d, int type, out uint mhz);
    [DllImport("nvml.dll")] static extern int nvmlDeviceGetFanSpeed(IntPtr d, out uint pct);
    static IntPtr dev = IntPtr.Zero; static bool tried = false;
    public static bool Ok { get { if (!tried) { tried = true; try { if (nvmlInit_v2() == 0 && nvmlDeviceGetHandleByIndex_v2(0, out dev) == 0) return true; } catch { } dev = IntPtr.Zero; } return dev != IntPtr.Zero; } }
    // [charge %, température °C, puissance W, fréquence MHz, ventilateur %]
    public static double[] Read() {
        double[] r = { double.NaN, double.NaN, double.NaN, double.NaN, double.NaN };
        if (!Ok) return r;
        try {
            Util u; uint v;
            if (nvmlDeviceGetUtilizationRates(dev, out u) == 0) r[0] = u.gpu;
            if (nvmlDeviceGetTemperature(dev, 0, out v) == 0) r[1] = v;
            if (nvmlDeviceGetPowerUsage(dev, out v) == 0) r[2] = v / 1000.0;
            if (nvmlDeviceGetClockInfo(dev, 0, out v) == 0) r[3] = v;
            if (nvmlDeviceGetFanSpeed(dev, out v) == 0) r[4] = v;
        } catch { }
        return r;
    }
}
// GPU toutes marques (NVIDIA, AMD, Intel) via Windows, comme le Gestionnaire des tâches (pilote WDDM 2.4+) :
// température, puissance (% du TDP), fréquence mémoire. Carte retenue : celle qui a le plus de mémoire dédiée.
public static class SCGpuWin {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct ADAPTERINFO { public uint hAdapter; public LUID Luid; public uint NumOfSources; public int bPrecise; }
    [StructLayout(LayoutKind.Sequential)] struct ENUM2 { public uint NumAdapters; public IntPtr pAdapters; }
    [StructLayout(LayoutKind.Sequential)] struct QAI { public uint hAdapter; public int Type; public IntPtr pData; public uint Size; }
    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref ENUM2 e);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QAI q);
    static uint hAdapter = 0; static bool tried = false;
    public static string Luid = null;   // « luid_0x........_0x........ », pour filtrer les compteurs GPU Engine
    public static string Name = null;
    static int Query(uint h, int type, IntPtr data, int size) {
        for (int k = 0; k < size; k++) Marshal.WriteByte(data, k, 0);
        QAI q = new QAI { hAdapter = h, Type = type, pData = data, Size = (uint)size };
        return D3DKMTQueryAdapterInfo(ref q);
    }
    public static bool Ok { get {
        if (tried) return hAdapter != 0;
        tried = true;
        try {
            ENUM2 e = new ENUM2(); D3DKMTEnumAdapters2(ref e);
            if (e.NumAdapters == 0) return false;
            int sz = Marshal.SizeOf(typeof(ADAPTERINFO));
            e.pAdapters = Marshal.AllocHGlobal(sz * (int)e.NumAdapters);
            if (D3DKMTEnumAdapters2(ref e) != 0) return false;
            IntPtr seg = Marshal.AllocHGlobal(64); long best = 0;
            for (int i = 0; i < e.NumAdapters; i++) {
                ADAPTERINFO a = (ADAPTERINFO)Marshal.PtrToStructure(e.pAdapters + i * sz, typeof(ADAPTERINFO));
                if (Query(a.hAdapter, 3, seg, 24) != 0) continue;   // KMTQAITYPE_GETSEGMENTSIZE
                long ded = Marshal.ReadInt64(seg);
                if (ded > best) { best = ded; hAdapter = a.hAdapter; Luid = string.Format("luid_0x{0:X8}_0x{1:X8}", a.Luid.High, a.Luid.Low); }
            }
            Marshal.FreeHGlobal(seg);
        } catch { hAdapter = 0; }
        return hAdapter != 0;
    } }
    // [température °C, puissance % TDP, fréquence mémoire MHz] ; NaN si le pilote ne les fournit pas
    public static double[] Read() {
        double[] r = { double.NaN, double.NaN, double.NaN };
        if (!Ok) return r;
        IntPtr pd = Marshal.AllocHGlobal(64);
        try {
            if (Query(hAdapter, 62, pd, 64) == 0) {   // KMTQAITYPE_ADAPTERPERFDATA
                int t = Marshal.ReadInt32(pd, 56), pw = Marshal.ReadInt32(pd, 52); long mf = Marshal.ReadInt64(pd, 8);
                if (t > 0) r[0] = t / 10.0;
                if (pw > 0) r[1] = pw / 10.0;
                if (mf > 0) r[2] = mf / 1000000.0;
            }
        } catch { } finally { Marshal.FreeHGlobal(pd); }
        return r;
    }
}
// température CPU lue dans la mémoire partagée de MSI Afterburner (s'il tourne et surveille « CPU temperature »)
// Windows ne la donne pas sans droits administrateur.
public static class SCAfterburner {
    public static double CpuTemp() {
        double best = double.NaN;
        try {
            using (var mmf = System.IO.MemoryMappedFiles.MemoryMappedFile.OpenExisting("MAHMSharedMemory", System.IO.MemoryMappedFiles.MemoryMappedFileRights.Read))
            using (var acc = mmf.CreateViewAccessor(0, 0, System.IO.MemoryMappedFiles.MemoryMappedFileAccess.Read)) {
                if (acc.ReadUInt32(0) != 0x4D41484D) return best;   // signature 'MAHM'
                uint hdr = acc.ReadUInt32(8), n = acc.ReadUInt32(12), size = acc.ReadUInt32(16);
                byte[] buf = new byte[260];
                for (uint i = 0; i < n && i < 512; i++) {
                    long off = hdr + (long)i * size;
                    acc.ReadArray(off, buf, 0, 260);
                    int len = Array.IndexOf(buf, (byte)0); if (len < 0) len = 260;
                    string name = System.Text.Encoding.ASCII.GetString(buf, 0, len);
                    if (!System.Text.RegularExpressions.Regex.IsMatch(name, "^CPU\\d* temperature$")) continue;
                    float v = acc.ReadSingle(off + 260 * 5);
                    if (v > 0 && v < 150 && (double.IsNaN(best) || v > best)) best = v;
                }
            }
        } catch { }
        return best;
    }
}
// mémoire par processus via NtQuerySystemInformation(SystemProcessInformation) : sans handle sur le processus
// (fonctionne malgré l'anti-triche de Star Citizen), un seul appel (~3 ms) pour tout le système. Windows 64 bits.
// Un instantané (Snap) sert à tout le relevé : présence du jeu et des logiciels, mémoire, CPU, top des processus —
// remplace Get-Process (bien plus lourd : un objet .NET + PowerShell par processus à chaque relevé).
public static class SCProcInfo {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    static IntPtr buf = IntPtr.Zero; static int size = 1 << 21;   // tampon réutilisé (pas d'allocation à chaque appel)
    public class P { public string Name; public int Pid; public double Priv, WS, PWS, Virt, Faults, Hard, Handles, Threads, Cpu; public long Create; }
    static readonly System.Collections.Generic.List<P> snap = new System.Collections.Generic.List<P>(400);
    // relit la liste des processus ; nombre de processus (0 si indisponible)
    public static int Snap() {
        snap.Clear();
        if (IntPtr.Size != 8) return 0;
        try {
            for (int tries = 0; ; tries++) {
                if (buf == IntPtr.Zero) buf = Marshal.AllocHGlobal(size);
                int ret; int st = NtQuerySystemInformation(5, buf, size, out ret);
                if (st == 0) break;
                if (st != unchecked((int)0xC0000004) || tries >= 5) return 0;   // STATUS_INFO_LENGTH_MISMATCH : tampon agrandi
                Marshal.FreeHGlobal(buf); buf = IntPtr.Zero; size = Math.Max(size * 2, ret + (1 << 18));
            }
            long off = 0;
            while (true) {
                IntPtr p = new IntPtr(buf.ToInt64() + off);
                int nameLen = Marshal.ReadInt16(p, 0x38) & 0xFFFF; IntPtr nameBuf = Marshal.ReadIntPtr(p, 0x40);
                string name = (nameLen > 0 && nameBuf != IntPtr.Zero) ? Marshal.PtrToStringUni(nameBuf, nameLen / 2) : "";
                if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name.Substring(0, name.Length - 4);
                snap.Add(new P { Name = name, Pid = (int)Marshal.ReadInt64(p, 0x50), Priv = Marshal.ReadInt64(p, 0xC8), WS = Marshal.ReadInt64(p, 0x90),
                    PWS = Marshal.ReadInt64(p, 0x08), Virt = Marshal.ReadInt64(p, 0x78), Faults = (uint)Marshal.ReadInt32(p, 0x80), Hard = (uint)Marshal.ReadInt32(p, 0x10),
                    Handles = (uint)Marshal.ReadInt32(p, 0x60), Threads = (uint)Marshal.ReadInt32(p, 0x04),
                    Cpu = (Marshal.ReadInt64(p, 0x28) + Marshal.ReadInt64(p, 0x30)) / 1e7, Create = Marshal.ReadInt64(p, 0x20) });
                int next = Marshal.ReadInt32(p, 0); if (next == 0) break; off += next;
            }
            return snap.Count;
        } catch { snap.Clear(); return 0; }
    }
    // somme des processus du dernier instantané nommés name (sans .exe), ou dont le nom commence par name si prefix :
    // [0] pid du plus gros, [1] Private Bytes (privé engagé), [2] Working Set, [3] Private Working Set, [4] Virtual Bytes,
    // [5] défauts de page (cumul), [6] défauts durs = lus sur disque (cumul), [7] handles, [8] threads,
    // [9] temps CPU (s, cumul), [10] heure de création du plus gros (FILETIME) ; null si aucun
    public static double[] Agg(string name, bool prefix) {
        double[] r = null; double best = -1;
        foreach (P p in snap) {
            if (!(prefix ? p.Name.StartsWith(name, StringComparison.OrdinalIgnoreCase) : string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))) continue;
            if (r == null) r = new double[11];
            if (p.Priv > best) { best = p.Priv; r[0] = p.Pid; r[10] = p.Create; }
            r[1] += p.Priv; r[2] += p.WS; r[3] += p.PWS; r[4] += p.Virt; r[5] += p.Faults; r[6] += p.Hard; r[7] += p.Handles; r[8] += p.Threads; r[9] += p.Cpu;
        }
        return r;
    }
    // nouvel instantané + somme pour un nom d'image (« StarCitizen.exe »)
    public static double[] Query(string image) {
        Snap(); return Agg(image.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? image.Substring(0, image.Length - 4) : image, false);
    }
    // nom d'un processus du dernier instantané
    public static string NameOf(int pid) { foreach (P p in snap) if (p.Pid == pid) return p.Name; return null; }
    // n processus (regroupés par nom) les plus gourmands en mémoire privée, hors noms exclus : « nom=1234Mo | … »
    public static string Top(int n, string excludeRe) {
        var sums = new System.Collections.Generic.Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        var ex = new System.Text.RegularExpressions.Regex(excludeRe, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        foreach (P p in snap) { if (p.Name.Length == 0 || ex.IsMatch(p.Name)) continue; double v; sums.TryGetValue(p.Name, out v); sums[p.Name] = v + p.Priv; }
        var list = new System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<string, double>>(sums);
        list.Sort((a, b) => b.Value.CompareTo(a.Value));
        var parts = new System.Collections.Generic.List<string>();
        for (int i = 0; i < n && i < list.Count; i++) parts.Add(list[i].Key + "=" + ((long)(list[i].Value / 1048576)).ToString() + "Mo");
        return string.Join(" | ", parts);
    }
}
// calculs de points des courbes (en PowerShell : une boucle interprétée par point, bien trop lent pour un dessin)
public static class SCDraw {
    // courbe en direct : vals (la plus récente à la fin) ; âge = nombre de relevés depuis la plus récente
    public static System.Drawing.PointF[] Live(System.Collections.Generic.List<double> vals, float padL, float plotW, double vEnd, double vSpan, float padT, float plotH, double max) {
        int n = vals.Count; var pts = new System.Drawing.PointF[n];
        for (int i = 0; i < n; i++) { double age = n - 1 - i; pts[i] = new System.Drawing.PointF((float)(padL + plotW * (1 - (age - vEnd) / vSpan)), (float)(padT + plotH * (1 - vals[i] / max))); }
        return pts;
    }
    // analyse : segments (coupés là où la valeur manque) de v[i0..i1] avec un pas
    public static System.Collections.Generic.List<System.Drawing.PointF[]> Segs(double[] t, double[] v, int i0, int i1, int stride, double pl, double pw, double v0, double span, double py, double ph, double lo, double hi) {
        var segs = new System.Collections.Generic.List<System.Drawing.PointF[]>(); var cur = new System.Collections.Generic.List<System.Drawing.PointF>();
        for (int i = i0; i <= i1 && i < v.Length; i += Math.Max(1, stride)) {
            double x = v[i];
            if (double.IsNaN(x)) { if (cur.Count > 0) { segs.Add(cur.ToArray()); cur.Clear(); } continue; }
            cur.Add(new System.Drawing.PointF((float)(pl + pw * (t[i] - v0) / span), (float)(py + ph * (1 - (x - lo) / (hi - lo)))));
        }
        if (cur.Count > 0) segs.Add(cur.ToArray());
        return segs;
    }
    // plages consécutives de même mode (0 = menu / inconnu, 1 = Arena Commander, 2 = PU) : {début, fin, mode} ;
    // la fin inclut le 1er point de la plage suivante (courbe continue)
    public static System.Collections.Generic.List<int[]> Runs(System.Collections.Generic.List<int> f, int n) {
        var r = new System.Collections.Generic.List<int[]>(); int s = 0;
        for (int i = 1; i <= n; i++) {
            int a = s < f.Count ? f[s] : 0, b = (i < n && i < f.Count) ? f[i] : 0;
            if (i == n || a != b) { r.Add(new int[] { s, Math.Min(i, n - 1), a }); s = i; }
        }
        return r;
    }
    // analyse : comme Segs, mais coupe aussi aux changements de mode (m[i]) ; chaque segment = (mode, points)
    public static System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<int, System.Drawing.PointF[]>> SegsMode(double[] t, double[] v, int[] m, int i0, int i1, int stride, double pl, double pw, double v0, double span, double py, double ph, double lo, double hi) {
        var segs = new System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<int, System.Drawing.PointF[]>>();
        var cur = new System.Collections.Generic.List<System.Drawing.PointF>(); int cm = -1;
        for (int i = i0; i <= i1 && i < v.Length; i += Math.Max(1, stride)) {
            double x = v[i];
            if (double.IsNaN(x)) { if (cur.Count > 0) { segs.Add(new System.Collections.Generic.KeyValuePair<int, System.Drawing.PointF[]>(cm, cur.ToArray())); cur.Clear(); } continue; }
            var p = new System.Drawing.PointF((float)(pl + pw * (t[i] - v0) / span), (float)(py + ph * (1 - (x - lo) / (hi - lo))));
            int mi = (m != null && i < m.Length) ? m[i] : 0;
            if (cur.Count > 0 && mi != cm) { cur.Add(p); segs.Add(new System.Collections.Generic.KeyValuePair<int, System.Drawing.PointF[]>(cm, cur.ToArray())); cur.Clear(); }
            cm = mi; cur.Add(p);
        }
        if (cur.Count > 0) segs.Add(new System.Collections.Generic.KeyValuePair<int, System.Drawing.PointF[]>(cm, cur.ToArray()));
        return segs;
    }
    // zone sous une courbe : la courbe fermée par deux points sur la ligne de base
    public static System.Drawing.PointF[] Area(System.Drawing.PointF[] seg, float baseY) {
        var a = new System.Drawing.PointF[seg.Length + 2]; a[0] = new System.Drawing.PointF(seg[0].X, baseY);
        Array.Copy(seg, 0, a, 1, seg.Length); a[a.Length - 1] = new System.Drawing.PointF(seg[seg.Length - 1].X, baseY); return a;
    }
    // [min, max] de v[i0..i1] hors valeurs manquantes (min > max si aucune)
    public static double[] MinMax(double[] v, int i0, int i1) {
        double lo = double.MaxValue, hi = double.MinValue;
        for (int i = Math.Max(0, i0); i <= i1 && i < v.Length; i++) { double x = v[i]; if (double.IsNaN(x)) continue; if (x < lo) lo = x; if (x > hi) hi = x; }
        return new double[] { lo, hi };
    }
}
// couleurs sombres pour les menus déroulants
public class SCMenuColors : ProfessionalColorTable {
    static System.Drawing.Color Bg = System.Drawing.Color.FromArgb(13, 20, 38), Sel = System.Drawing.Color.FromArgb(12, 40, 56),
        Border = System.Drawing.Color.FromArgb(22, 110, 130), Sep = System.Drawing.Color.FromArgb(30, 42, 70);
    public override System.Drawing.Color MenuItemSelected { get { return Sel; } }
    public override System.Drawing.Color MenuItemSelectedGradientBegin { get { return Sel; } }
    public override System.Drawing.Color MenuItemSelectedGradientEnd { get { return Sel; } }
    public override System.Drawing.Color MenuItemBorder { get { return Border; } }
    public override System.Drawing.Color MenuBorder { get { return Border; } }
    public override System.Drawing.Color ToolStripDropDownBackground { get { return Bg; } }
    public override System.Drawing.Color ImageMarginGradientBegin { get { return Bg; } }
    public override System.Drawing.Color ImageMarginGradientMiddle { get { return Bg; } }
    public override System.Drawing.Color ImageMarginGradientEnd { get { return Bg; } }
    public override System.Drawing.Color SeparatorDark { get { return Sep; } }
    public override System.Drawing.Color SeparatorLight { get { return Sep; } }
}
public class SCGraph : Panel {
    // sélectionnable : nécessaire pour recevoir la molette (zoom de l'analyse)
    public SCGraph() { DoubleBuffered = true; ResizeRedraw = true; SetStyle(ControlStyles.Selectable, true); TabStop = false; }
}
'@
} catch { Log-Error "Initialisation : $_"; throw }

try { [void][SCMem]::SetCurrentProcessExplicitAppUserModelID('SuiviMemoireSC.App') } catch { }
# l'appli utilise une quarantaine d'expressions régulières : avec le cache par défaut (15), .NET les recompilait sans cesse
[System.Text.RegularExpressions.Regex]::CacheSize = 64
[System.Windows.Forms.Application]::EnableVisualStyles()
# rendu du texte GDI (TextRenderer) : en GDI+ (« compatible », défaut sous PowerShell), Bahnschrift perdait les accents
# des majuscules (« TEMPERATURES », « ECHANGE »…)
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

# ---------------------------------------------------------------- état partagé
$S = @{
    Seuil = 70.0; Avert = 60.0; FuiteSeuil = 100.0; FuiteDuree = 15; CapInterval = 5; FinCalme = 60; Son = $true; TopMost = $false; Interval = 15; AutoTrack = $true; X = $null; Y = $null; XC = $null; YC = $null; Compact = $false; FullH = 0
    ShowGraph = $true; ShowSet = $true; ShowEv = $true   # sections repliables du mode complet (courbe, réglages, événements)
    Tracking = $false; Csv = $null; Stamp = $null; T0 = $null; LastLog = [datetime]::MinValue; Rows = 0
    PrevCpu = $null; PrevTime = $null; ScSeen = $false; ScGoneAt = $null; NoAutoPid = 0
    Markers = (New-Object System.Collections.Generic.List[string]); MarkerCount = 0; AlertLevel = 0
    History = (New-Object System.Collections.Generic.List[double]); TickN = 0
    HistMode = (New-Object System.Collections.Generic.List[int]); Mode = 0   # mode de jeu à chaque relevé : 0 menu (blanc), 1 AC (rouge), 2 PU (bleu)
    Events = (New-Object System.Collections.Generic.List[object]); LastEvent = ''
    LogPos = 0L; LogCtime = $null; LogRest = ''; LastLabelAt = @{}; HotSeen = 0; HotSeenD = 0
    Gb = 0.0; Lim = 0.0; Avail = 0.0; Flash = 0; Blink = $false
    TotalRam = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory; Cores = [Environment]::ProcessorCount
}
if (Test-Path $SettingsFile) {
    try {
        $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        foreach ($k in 'Seuil','Avert','FuiteSeuil','FuiteDuree','CapInterval','FinCalme','Son','TopMost','Interval','AutoTrack','X','Y','XC','YC','GameDir','Compact','W','H','ShowGraph','ShowSet','ShowEv') { if ($j.PSObject.Properties[$k] -and $j.$k -ne $null) { $S[$k] = $j.$k } }
    } catch { Log-Error "Réglages illisibles : $_" }
} else {
    # premier lancement : seuils proportionnés à la limite de mémoire validée de ce PC (RAM + fichier d'échange)
    try { $lim = [SCMem]::Commit()[1] / 1GB; if ($lim -gt 8) { $S.Seuil = [Math]::Round($lim * 0.73); $S.Avert = [Math]::Round($lim * 0.63) } } catch { }
}
if ($S.GameDir -and (Test-Path (Join-Path $S.GameDir 'Bin64'))) { Set-GameDir $S.GameDir }
function Save-Settings {
    if ($TestSeconds) { return }
    try { Remember-Pos } catch { }
    try { Remember-Size } catch { }
    try {
        [pscustomobject]@{ Seuil = $S.Seuil; Avert = $S.Avert; FuiteSeuil = $S.FuiteSeuil; FuiteDuree = $S.FuiteDuree; CapInterval = $S.CapInterval; FinCalme = $S.FinCalme; Son = $S.Son; TopMost = $S.TopMost; Interval = $S.Interval; AutoTrack = $S.AutoTrack; X = $S.X; Y = $S.Y; XC = $S.XC; YC = $S.YC; GameDir = $S.GameDir; Compact = [bool]$S.Compact; W = $S.W; H = $S.H
                          ShowGraph = [bool]$S.ShowGraph; ShowSet = [bool]$S.ShowSet; ShowEv = [bool]$S.ShowEv } |
            ConvertTo-Json | Out-File -FilePath $SettingsFile -Encoding utf8
    } catch { Log-Error "Sauvegarde réglages : $_" }
}

# ---------------------------------------------------------------- sons discrets (générés en mémoire)
function New-Sound($notes, [double]$amp) {
    $rate = 22050; $ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($ms)
    $data = New-Object System.Collections.Generic.List[int16]
    foreach ($n in $notes) {
        $len = [int]($rate * $n.d)
        for ($i = 0; $i -lt $len; $i++) {
            $env = [Math]::Min(1, $i / ($rate * 0.006)) * [Math]::Pow(1 - $i / $len, 2)
            $data.Add([int16]($amp * 32767 * $env * [Math]::Sin(2 * [Math]::PI * $n.f * $i / $rate)))
        }
    }
    $len = $data.Count * 2
    $bw.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $bw.Write([int](36 + $len)); $bw.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1); $bw.Write([int]$rate); $bw.Write([int]($rate * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write([Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([int]$len); foreach ($smp in $data) { $bw.Write($smp) }
    $bw.Flush(); $ms.Position = 0
    $p = New-Object System.Media.SoundPlayer($ms); $p.Load(); return $p
}
$chime = New-Sound @(@{ f = 660; d = 0.12 }, @{ f = 880; d = 0.18 }) 0.22   # alerte
$tick = New-Sound @(@{ f = 1320; d = 0.06 }, @{ f = 1760; d = 0.07 }) 0.13  # repère enregistré
$leakSnd = New-Sound @(@{ f = 988; d = 0.09 }, @{ f = 740; d = 0.09 }, @{ f = 988; d = 0.09 }, @{ f = 740; d = 0.16 }) 0.22   # fuite suspectée (deux tons alternés)

# ---------------------------------------------------------------- thème
function RGB($r, $g, $b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }
$Pal = @{
    Bg = RGB 9 13 26; Panel = RGB 13 20 38; Field = RGB 16 25 46; Line = RGB 30 42 70
    White = RGB 236 240 248; Text = RGB 200 211 230;Muted = RGB 104 120 152; Dim = RGB 62 74 102
    Cyan = RGB 34 211 238; CyanDim = RGB 22 110 130; CyanHover = RGB 12 40 56; CyanDown = RGB 16 62 82
    Ok = RGB 52 211 153; Warn = RGB 251 176 36; Crit = RGB 244 63 94; Leak = RGB 232 121 249; LeakDim = RGB 112 58 122   # fuite : fuchsia
    Soft = RGB 147 197 253   # lancement / fermeture d'un logiciel de head-tracking
    Kill = RGB 88 130 104; KillP = RGB 64 230 120; Death = RGB 152 92 100; DeathP = RGB 255 70 70; Focus = RGB 212 192 112   # repères : PNJ ternes, joueurs vifs
}
$fontUI = 'Segoe UI'
$fontTech = if ((New-Object System.Drawing.Text.InstalledFontCollection).Families | Where-Object { $_.Name -eq 'Bahnschrift' }) { 'Bahnschrift' } else { 'Segoe UI' }
# objets de dessin mis en cache : créés une fois, réutilisés à chaque dessin (sans cache : des centaines d'objets GDI+
# recréés à chaque mouvement de souris, libérés seulement par le ramasse-miettes)
$GdiCache = @{}
function Fnt($size, $bold = $false, $fam = $fontUI, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular) {
    if ($bold) { $style = [System.Drawing.FontStyle]::Bold }
    $k = "f|$fam|$size|$style"; $f = $GdiCache[$k]
    if (-not $f) { $f = New-Object System.Drawing.Font($fam, [single]$size, $style); $GdiCache[$k] = $f }
    return $f
}
function Pen-Of($c, [single]$w = 1, [bool]$dash = $false) {
    $k = "p|$($c.ToArgb())|$w|$dash"; $p = $GdiCache[$k]
    if (-not $p) { $p = New-Object System.Drawing.Pen($c, $w); if ($dash) { $p.DashStyle = 'Dash' }; $GdiCache[$k] = $p }
    return $p
}
function Brush-Of($c) { $k = "b|$($c.ToArgb())"; $b = $GdiCache[$k]; if (-not $b) { $b = New-Object System.Drawing.SolidBrush($c); $GdiCache[$k] = $b }; return $b }
# hachures des 2 minutes avant une fuite ($brPre) et alignement à droite : objets uniques partagés par tous les dessins
$BrPre = New-Object System.Drawing.Drawing2D.HatchBrush([System.Drawing.Drawing2D.HatchStyle]::BackwardDiagonal, [System.Drawing.Color]::FromArgb(58, $Pal.Leak), [System.Drawing.Color]::FromArgb(0, $Pal.Leak))
$FmtFar = New-Object System.Drawing.StringFormat; $FmtFar.Alignment = 'Far'
function Mode-Color([int]$mode) { switch ($mode) { 1 { $Pal.Crit } 2 { $Pal.Cyan } default { $Pal.White } } }   # courbe : menu / AC / PU
function Mark-Color([string]$k) { switch ($k) { 'manual' { $Pal.Cyan } 'alert' { $Pal.Crit } 'kill' { $Pal.Kill } 'killp' { $Pal.KillP } 'death' { $Pal.Death } 'deathp' { $Pal.DeathP } 'focus' { $Pal.Focus } 'leak' { $Pal.Leak } 'soft' { $Pal.Soft } default { $Pal.Muted } } }
function ToRef($col) { ([int]$col.B -shl 16) -bor ([int]$col.G -shl 8) -bor [int]$col.R }   # [int] : -shl sur un octet déborde (le titre sortait en rouge)

# ---------------------------------------------------------------- fenêtre
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Suivi mémoire · Star Citizen'
$form.ClientSize = New-Object System.Drawing.Size(480, 654)
$form.FormBorderStyle = 'Sizable'; $form.MaximizeBox = $false   # redimensionnable (mode complet) : voir Layout-Full
$form.Font = Fnt 9; $form.BackColor = $Pal.Bg; $form.ForeColor = $Pal.Text
$form.AutoScaleMode = 'Dpi'
try { $form.Icon = New-Object System.Drawing.Icon((Join-Path $AppDir 'icone.ico')) } catch { Log-Error "Icone : $_" }
if ($S.X -ne $null -and $S.Y -ne $null) {
    $pt = New-Object System.Drawing.Point([int]$S.X, [int]$S.Y)
    if ([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($pt) }) { $form.StartPosition = 'Manual'; $form.Location = $pt }
}
$form.Add_HandleCreated({ try { [SCMem]::DarkTitle($form.Handle, (ToRef $Pal.Bg), (ToRef $Pal.CyanDim), (ToRef $Pal.Cyan)) } catch { } })
$tips = New-Object System.Windows.Forms.ToolTip

# change le texte seulement s'il a changé (évite une mise en page + un redessin inutiles à chaque relevé)
function Set-Text($c, [string]$t) { if ($c.Text -cne $t) { $c.Text = $t } }
function New-Label($text, $x, $yy, $w, $h, $font, $color, $align = 'TopLeft', $parent = $form) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.SetBounds($x, $yy, $w, $h)
    $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent; $l.TextAlign = $align; $l.UseMnemonic = $false
    $parent.Controls.Add($l); return $l
}

# en-tête
$head = New-Object System.Windows.Forms.Panel; $head.SetBounds(0, 0, 480, 150); $head.BackColor = $Pal.Panel; $form.Controls.Add($head)
$lblCap = New-Label 'MÉMOIRE ENGAGÉE (VALIDÉE) · SYSTÈME' 18 8 240 16 (Fnt 8 $true) $Pal.Muted 'TopLeft' $head
$lblBig = New-Label '' 15 26 240 40 (Fnt 22 $false $fontTech) $Pal.Ok 'TopLeft' $head; $lblBig.BringToFront()
$lblBigSub = New-Label '' 18 65 254 17 (Fnt 8.5) $Pal.Muted 'TopLeft' $head
$lblState = New-Label '' 262 10 200 18 (Fnt 8 $true $fontTech) $Pal.Ok 'TopRight' $head
$lblProc = New-Label '' 274 28 188 54 (Fnt 8 $false $fontTech) $Pal.Text 'TopRight' $head
$tipEng = "Mémoire engagée (« validée » dans le Gestionnaire des tâches) : ce que les programmes se sont fait garantir,`nen RAM ou dans le fichier d'échange, dans la limite d'engagement (RAM + fichier d'échange).`nCe n'est ni la RAM physique utilisée, ni la mémoire virtuelle réservée.`n(%) = part de la limite d'engagement utilisée · RAM libre = RAM physique (mémoire vive) réellement disponible."
foreach ($l in $lblCap, $lblBig, $lblBigSub) { $tips.SetToolTip($l, $tipEng) }
$tips.SetToolTip($lblProc, "Star Citizen : Private Bytes = mémoire privée engagée (c'est elle qui fuit).")
# capteurs en direct (CPU / GPU), dans l'en-tête sous un filet
$hwLine = New-Object System.Windows.Forms.Panel; $hwLine.SetBounds(16, 84, 448, 1); $hwLine.BackColor = $Pal.Line; $head.Controls.Add($hwLine)
# CPU | GPU puis K/D | JOUEURS, ferrés à gauche (étiquettes à largeur auto, recalées par Place-Row)
$lblHwCpu = New-Label 'CPU  —' 16 90 10 18 (Fnt 8.5 $false $fontTech) $Pal.Muted 'TopLeft' $head
$lblHwSep = New-Label '|' 0 90 10 18 (Fnt 8.5 $false $fontTech) $Pal.Line 'TopLeft' $head
$lblHwGpu = New-Label 'GPU  —' 0 90 10 18 (Fnt 8.5 $false $fontTech) $Pal.Muted 'TopLeft' $head
# ratio kills / morts de la session en cours (tous / contre joueurs)
$lblKd = New-Label 'K/D  —' 16 108 10 18 (Fnt 8.5 $false $fontTech) $Pal.Dim 'TopLeft' $head
$lblKdSep = New-Label '|' 0 108 10 18 (Fnt 8.5 $false $fontTech) $Pal.Line 'TopLeft' $head
$lblKdP = New-Label 'JOUEURS  —' 0 108 10 18 (Fnt 8.5 $false $fontTech) $Pal.Dim 'TopLeft' $head
foreach ($l in $lblHwCpu, $lblHwSep, $lblHwGpu, $lblKd, $lblKdSep, $lblKdP) { $l.AutoSize = $true }
# $stack : fenêtre étroite, les deux étiquettes sont l'une au-dessus de l'autre (placées par Layout-Full, rien à recaler)
function Place-Row($a, $sep, $b, [bool]$stack = $false) { if ($stack) { return }; $sep.Left = $a.Right + 4; $b.Left = $sep.Right + 4 }
Place-Row $lblHwCpu $lblHwSep $lblHwGpu; Place-Row $lblKd $lblKdSep $lblKdP
$tips.SetToolTip($lblKd, 'Kills / morts de la session en cours (joueurs + PNJ ; collisions comprises)')
$tips.SetToolTip($lblKdP, 'Joueurs abattus / morts tué par un joueur')
# vitesse de la mémoire validée de Star Citizen + état de la détection de fuite (indépendant des seuils en Go)
$lblLeak = New-Label 'VITESSE SC  —' 16 126 10 18 (Fnt 8.5 $false $fontTech) $Pal.Dim 'TopLeft' $head; $lblLeak.AutoSize = $true
$lblLeakSt = New-Label '' 136 126 268 18 (Fnt 8 $true $fontTech) $Pal.Dim 'TopRight' $head
$tips.SetToolTip($lblLeak, "Vitesse d'augmentation de la mémoire validée de Star Citizen (Mo/s) :`npente sur 15 s / pente sur 30 s (régression linéaire sur les relevés toutes les 2 s).")
$tipLeakSt = "FUITE SUSPECTÉE : la pente 15 s reste au-dessus du seuil « FUITE » pendant la durée choisie.`nAprès un chargement (Game.log), 30 s de plus sont exigées ; rien pendant les 3 premières minutes du jeu.`nL'heure affichée est le début estimé de la hausse. Fin : pente 30 s < seuil / 3 pendant la durée « FIN APRÈS »."
$tips.SetToolTip($lblLeakSt, $tipLeakSt)
# capture des incidents (tampon circulaire / fichier incident en cours), à droite de la ligne K/D
$lblCapSt = New-Label '' 262 108 200 18 (Fnt 8 $false $fontTech) $Pal.Dim 'TopRight' $head
$lblCapSt.Cursor = 'Hand'; $lblCapSt.Add_Click({ try { Show-Incidents } catch { Log-Error "Incidents : $_" } })   # accès rapide aux incidents
$tips.SetToolTip($lblCapSt, "Tampon circulaire des dernières minutes (une mesure toutes les « CAPTURE » secondes, 1 par seconde dès qu'une hausse est suspectée).`nÀ la confirmation d'une fuite : fichier tracking\incident_*.csv avec les 2 minutes d'avant puis la suite, écrit à chaque mesure.`nOuvrir avec ANALYSE.")
$accent = New-Object System.Windows.Forms.Panel; $accent.SetBounds(0, 148, 480, 2); $accent.BackColor = $Pal.Ok; $form.Controls.Add($accent)
$accent.BringToFront()

# flèche afficher / masquer la courbe et les options (mode compact) : dans l'en-tête, à droite
$tgl = New-Label '' 436 122 26 26 (Fnt 9) $Pal.Muted 'MiddleCenter' $head
$tgl.Add_Paint({ param($sender, $e)
    $gr = $e.Graphics; $gr.SmoothingMode = 'AntiAlias'
    $cx = $sender.Width / 2.0; $cy = $sender.Height / 2.0; $a = 4.5 * $sender.DeviceDpi / 96.0   # (pas « $s » : écraserait $S)
    $dy = if ($S.Compact) { $a / 2 } else { -$a / 2 }   # ▴ : masquer · ▾ : afficher
    $pen = New-Object System.Drawing.Pen($sender.ForeColor, [single](1.6 * $sender.DeviceDpi / 96.0)); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $gr.DrawLines($pen, [System.Drawing.PointF[]]@([System.Drawing.PointF]::new($cx - $a, $cy - $dy), [System.Drawing.PointF]::new($cx, $cy + $dy), [System.Drawing.PointF]::new($cx + $a, $cy - $dy))) })   # flèche afficher / masquer, à droite des capteurs
$tgl.Cursor = 'Hand'
$tgl.Add_MouseEnter({ $tgl.ForeColor = $Pal.Cyan }); $tgl.Add_MouseLeave({ $tgl.ForeColor = $Pal.Muted })

# punaise (mode compact) : premier plan + fenêtre sans barre de titre ; épinglée = droite et cyan, sinon penchée et terne
$pin = New-Label '' 408 122 26 26 (Fnt 9) $Pal.Muted 'MiddleCenter' $head; $pin.Cursor = 'Hand'; $pin.Tag = @{ Hot = $false }
$pin.Add_Paint({ param($sender, $e)
    $gr = $e.Graphics; $gr.SmoothingMode = 'AntiAlias'; $k = $sender.DeviceDpi / 96.0
    $col = if ($S.TopMost) { $Pal.Cyan } elseif ($sender.Tag.Hot) { $Pal.Text } else { $Pal.Muted }
    $gr.TranslateTransform([single]($sender.Width / 2.0), [single]($sender.Height / 2.0))
    if (-not $S.TopMost) { $gr.RotateTransform(40) }
    $gr.ScaleTransform([single]$k, [single]$k)
    $pen = New-Object System.Drawing.Pen($col, [single]1.5); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $hd = New-Object System.Drawing.RectangleF(-2.5, -7, 5, 5.5)
    if ($S.TopMost) { $gr.FillRectangle((Brush-Of $col), $hd) } else { $gr.DrawRectangle($pen, $hd.X, $hd.Y, $hd.Width, $hd.Height) }
    $gr.DrawLine($pen, [single]-5, [single]-1.5, [single]5, [single]-1.5)   # collerette
    $gr.DrawLine($pen, [single]0, [single]-1.5, [single]0, [single]7)       # pointe
    $pen.Dispose() })
$pin.Add_MouseEnter({ $pin.Tag.Hot = $true; $pin.Invalidate() }); $pin.Add_MouseLeave({ $pin.Tag.Hot = $false; $pin.Invalidate() })

# variation de la mémoire engagée sur les 30 dernières secondes, à droite du gros chiffre :
# blanc = stable ; vert = baisse, rouge = hausse, de plus en plus vif selon l'ampleur (échelle log : 10 Mo -> 500 Mo)
$DeltaWin = 30
$lblDelta = New-Label '' 0 0 10 18 (Fnt 10 $false $fontTech) $Pal.Text 'TopLeft' $head; $lblDelta.AutoSize = $true; $lblDelta.BringToFront()
$tips.SetToolTip($lblDelta, "Variation de la mémoire engagée du système sur les $DeltaWin dernières secondes.`nBlanc : stable (moins de 10 Mo) · vert : baisse · rouge : hausse (plus c'est vif, plus ça bouge).")
$S.DeltaBuf = New-Object System.Collections.Generic.List[double[]]
function Place-Delta {
    $w = [System.Windows.Forms.TextRenderer]::MeasureText($lblBig.Text, $lblBig.Font).Width
    $lblDelta.Left = $lblBig.Left + $w
    $lblDelta.Top = $lblBig.Top + [int](($lblBig.Height - $lblDelta.Height) * 0.62)
}
function Mix-Color($a, $b, [double]$t) { RGB ([int]($a.R + ($b.R - $a.R) * $t)) ([int]($a.G + ($b.G - $a.G) * $t)) ([int]($a.B + ($b.B - $a.B) * $t)) }
$DeltaUpLo = RGB 250 175 175; $DeltaUpHi = RGB 255 45 70; $DeltaDnLo = RGB 175 235 195; $DeltaDnHi = RGB 40 215 110
function Update-Delta {
    $now = [Diagnostics.Stopwatch]::GetTimestamp() / [Diagnostics.Stopwatch]::Frequency
    $S.DeltaBuf.Add([double[]]@($now, $S.Gb))
    while ($S.DeltaBuf.Count -gt 2 -and $now - $S.DeltaBuf[1][0] -ge $DeltaWin) { $S.DeltaBuf.RemoveAt(0) }
    $mb = ($S.Gb - $S.DeltaBuf[0][1]) * 1024
    $a = [Math]::Abs($mb)
    if ($a -lt 10) { $col = $Pal.Text; $txt = '±0 Mo' }
    else {
        $t = [Math]::Min(1.0, [Math]::Log($a / 10) / [Math]::Log(50))
        $col = if ($mb -gt 0) { Mix-Color $DeltaUpLo $DeltaUpHi $t } else { Mix-Color $DeltaDnLo $DeltaDnHi $t }
        $sg = if ($mb -gt 0) { '+' } else { '−' }
        $txt = if ($a -ge 1024) { '{0}{1:0.0} Go' -f $sg, ($a / 1024) } else { '{0}{1:0} Mo' -f $sg, $a } }
    Set-Text $lblDelta $txt; $lblDelta.ForeColor = $col
    Place-Delta
}

# clic-glisser sur l'en-tête (hors flèche / punaise) : déplace la fenêtre, indispensable sans barre de titre
foreach ($c in @($head, $lblBig, $lblDelta, $lblState, $lblProc, $lblLeak, $lblLeakSt)) {
    $c.Add_MouseDown({ param($sender, $e) if ($e.Button -eq 'Left') { [SCMem]::DragWindow($form.Handle) } }) }
# fenêtre sans bordure : filet discret autour de l'en-tête
$head.Add_Paint({ param($sender, $e)
    if ($form.FormBorderStyle -eq 'None') { $e.Graphics.DrawRectangle((Pen-Of $Pal.Line), 0, 0, $sender.Width - 1, $sender.Height - 1) } })

# courbe
$graph = New-Object SCGraph; $graph.SetBounds(16, 164, 448, 132); $graph.BackColor = $Pal.Panel
$form.Controls.Add($graph)

# détail mémoire de Star Citizen + système, sous la courbe (chaque valeur a son infobulle)
$lblMemSc = New-Label 'STAR CITIZEN  —' 16 300 448 16 (Fnt 8 $false $fontTech) $Pal.Muted 'TopLeft'; $lblMemSc.AutoEllipsis = $true
$lblMemPf = New-Label '' 16 318 448 16 (Fnt 8 $false $fontTech) $Pal.Muted 'TopLeft'; $lblMemPf.AutoEllipsis = $true
$tips.SetToolTip($lblMemSc, ("ENGAGÉE = Private Bytes : mémoire privée engagée de SC (en RAM ou dans le fichier d'échange). C'est elle qui fuit.`n" +
    "RAM = Working Set : pages de SC présentes en RAM physique (privées + partagées) ; « privée » = Private Working Set.`n" +
    "VIRTUELLE = Virtual Bytes : espace d'adresses réservé + engagé (dont fichiers mappés). Une simple réservation`nne consomme ni RAM ni engagement : plusieurs To sont normaux en 64 bits."))
$tips.SetToolTip($lblMemPf, ("DÉFAUTS DE PAGE : accès à une page absente du Working Set. La plupart sont « doux » (page déjà en RAM,`n" +
    "page neuve remise à zéro…) et ne touchent pas le disque ; seuls les défauts durs lisent le disque (« dont disque »).`n" +
    "ENGAGEMENT : mémoire engagée du système en % de la limite d'engagement (RAM + fichier d'échange).`n" +
    "ÉCHANGE : fichier d'échange utilisé / taille actuelle (Windows l'agrandit si besoin, ce qui relève la limite)."))

# réglages
$y = 344
# champ numérique à la charte : cadre sombre + bordure cyan, flèches ▲▼ dessinées par nous.
# Le NumericUpDown ne sert qu'à garder la valeur (bornes, ValueChanged) : il n'est pas affiché — ses boutons
# gris système ne se recolorent pas et, masqués, laissaient une zone non peinte. L'affichage est un simple TextBox.
function New-Num($x, $yy, $min, $max, $val) {
    $n = New-Object System.Windows.Forms.NumericUpDown; $n.Minimum = $min; $n.Maximum = $max
    $n.Value = [decimal][Math]::Min($max, [Math]::Max($min, [double]$val))
    $box = New-Object System.Windows.Forms.Panel; $box.SetBounds($x, $yy, 58, 24); $box.BackColor = $Pal.Field
    $tb = New-Object System.Windows.Forms.TextBox; $tb.BorderStyle = 'None'; $tb.BackColor = $Pal.Field; $tb.ForeColor = $Pal.Cyan
    $tb.Font = Fnt 9.5 $false $fontTech; $tb.TextAlign = 'Center'; $tb.MaxLength = 4; $tb.Text = [string][int]$n.Value
    $box.Controls.Add($tb); $tb.SetBounds(3, [int]((24 - $tb.PreferredHeight) / 2) + 1, 36, $tb.PreferredHeight)
    $st = @{ Num = $n; Tb = $tb; Box = $box; Hot = $false }; $box.Tag = $st; $tb.Tag = $st; $n.Tag = $st
    $n.Add_ValueChanged({ param($sender) $sender.Tag.Tb.Text = [string][int]$sender.Value })
    $commit = { param($st) $v = 0; if ([int]::TryParse($st.Tb.Text.Trim(), [ref]$v)) { $st.Num.Value = [decimal][Math]::Min([double]$st.Num.Maximum, [Math]::Max([double]$st.Num.Minimum, $v)) }
        $st.Tb.Text = [string][int]$st.Num.Value }
    $tb.Add_KeyPress({ param($sender, $e) if (-not [char]::IsDigit($e.KeyChar) -and -not [char]::IsControl($e.KeyChar)) { $e.Handled = $true } })
    $tb.Add_KeyDown({ param($sender, $e)
        $st = $sender.Tag; $k = $e.KeyCode
        if ($k -eq [System.Windows.Forms.Keys]::Up) { $e.SuppressKeyPress = $true; $st.Num.UpButton() }
        elseif ($k -eq [System.Windows.Forms.Keys]::Down) { $e.SuppressKeyPress = $true; $st.Num.DownButton() }
        elseif ($k -eq [System.Windows.Forms.Keys]::Return) { $e.SuppressKeyPress = $true; & $commit $st; $sender.SelectAll() } }.GetNewClosure())
    $tb.Add_Leave({ param($sender) & $commit $sender.Tag; $sender.Tag.Box.Invalidate() }.GetNewClosure())
    $tb.Add_Enter({ param($sender) $sender.Tag.Box.Invalidate() })
    $tb.Add_MouseWheel({ param($sender, $e) if ($e.Delta -gt 0) { $sender.Tag.Num.UpButton() } else { $sender.Tag.Num.DownButton() } })
    $box.Add_Paint({ param($sender, $e)
        $st = $sender.Tag; $c = if ($st.Tb.Focused -or $st.Hot) { $Pal.Cyan } else { $Pal.CyanDim }
        $e.Graphics.DrawRectangle((Pen-Of ($c)), 0, 0, $sender.Width - 1, $sender.Height - 1)
        $e.Graphics.DrawLine((Pen-Of ($Pal.Line)), 40, 4, 40, $sender.Height - 5) })
    foreach ($dir in 'up', 'down') {
        $ar = New-Object System.Windows.Forms.Label; $ar.Text = $(if ($dir -eq 'up') { '▲' } else { '▼' }); $ar.Font = Fnt 5.5; $ar.TextAlign = 'MiddleCenter'
        $ar.SetBounds(42, $(if ($dir -eq 'up') { 2 } else { 12 }), 14, 10); $ar.ForeColor = $Pal.CyanDim; $ar.BackColor = $Pal.Field; $ar.Cursor = 'Hand'
        $ar.Tag = @{ Num = $n; Dir = $dir }
        $ar.Add_MouseEnter({ param($sender) $sender.ForeColor = $Pal.Cyan; $sender.BackColor = $Pal.CyanHover })
        $ar.Add_MouseLeave({ param($sender) $sender.ForeColor = $Pal.CyanDim; $sender.BackColor = $Pal.Field })
        $ar.Add_MouseDown({ param($sender) $sender.BackColor = $Pal.CyanDown
            if ($sender.Tag.Dir -eq 'up') { $sender.Tag.Num.UpButton() } else { $sender.Tag.Num.DownButton() } })
        $ar.Add_MouseUp({ param($sender) $sender.BackColor = $Pal.CyanHover })
        $box.Controls.Add($ar) }
    $box.Add_MouseEnter({ param($sender) $sender.Tag.Hot = $true; $sender.Invalidate() })
    $box.Add_MouseLeave({ param($sender) $sender.Tag.Hot = $false; $sender.Invalidate() })
    $box.Add_Click({ param($sender) [void]$sender.Tag.Tb.Focus() })
    $form.Controls.Add($box); return $n
}
# case à cocher dessinée à la main : fond = fond de l'appli, contour terne si décochée,
# contour + carré plein cyan si cochée (survol : contour cyan atténué)
function Set-CheckLook($c) {
    $c.FlatStyle = 'Flat'; $c.Cursor = 'Hand'
    $c.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)   # taille auto : place pour le texte, décalé par la case dessinée
    $c.Add_MouseEnter({ param($sender) $sender.Invalidate() })
    $c.Add_MouseLeave({ param($sender) $sender.Invalidate() })
    $c.Add_Paint({ param($sender, $e)
        $gr = $e.Graphics; $gr.SmoothingMode = 'None'
        $bg = $sender.BackColor; if ($bg.A -lt 255 -and $sender.Parent) { $bg = $sender.Parent.BackColor }
        $gr.Clear($bg)
        $s = [Math]::Max(12, [int][Math]::Round($sender.Font.Height * 0.75))
        $bx = 1; $by = [int][Math]::Floor(($sender.Height - $s) / 2)
        $hot = $sender.ClientRectangle.Contains($sender.PointToClient([System.Windows.Forms.Cursor]::Position))
        $edge = if (-not $sender.Enabled) { $Pal.Line } elseif ($sender.Checked) { $Pal.Cyan } elseif ($hot) { $Pal.CyanDim } else { $Pal.Dim }
        $gr.DrawRectangle((Pen-Of $edge 1), $bx, $by, $s - 1, $s - 1)
        if ($sender.Checked) {
            $in = [Math]::Max(3, [int][Math]::Round($s / 4))
            $gr.FillRectangle((Brush-Of $(if ($sender.Enabled) { $Pal.Cyan } else { $Pal.Dim })), $bx + $in, $by + $in, $s - 2 * $in, $s - 2 * $in) }
        $fg = if ($sender.Enabled) { $sender.ForeColor } else { $Pal.Dim }
        $r = New-Object System.Drawing.Rectangle(($bx + $s + 3), 0, ($sender.Width - $bx - $s - 3), $sender.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($gr, $sender.Text, $sender.Font, $r, $fg, [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, SingleLine, NoPadding')
    })
}
function New-Check($text, $x, $yy, $w, $checked) {
    $c2 = New-Object System.Windows.Forms.CheckBox; $c2.Text = $text; $c2.SetBounds($x, $yy, $w, 22); $c2.Checked = [bool]$checked
    $c2.ForeColor = $Pal.Text; $c2.Font = Fnt 9; Set-CheckLook $c2
    $form.Controls.Add($c2); return $c2
}
# chaque réglage = une « cellule » étiquette + champ + unité, placée par Layout-Full (deux par ligne, ou une seule si étroit)
function New-Cell($text, $lw, $color, $num, $unit, $uw) {
    @{ L = (New-Label $text 0 0 $lw 18 (Fnt 8 $true $fontTech) $color); LW = $lw; N = $num.Tag.Box
       U = (New-Label $unit 0 0 $uw 18 (Fnt 9) $Pal.Muted); UW = $uw }
}
$numSeuil = New-Num 0 0 5 400 $S.Seuil;        $cAlert = New-Cell 'ALERTE' 60 $Pal.Crit $numSeuil 'Go' 24
$numAvert = New-Num 0 0 5 400 $S.Avert;        $cAvert = New-Cell 'ATTENTION' 80 $Pal.Warn $numAvert 'Go' 24
$numFuite = New-Num 0 0 10 2000 $S.FuiteSeuil; $cFuite = New-Cell 'FUITE' 60 $Pal.Leak $numFuite 'Mo/s' 40
$numFuiteDur = New-Num 0 0 4 300 $S.FuiteDuree; $cFuiteDur = New-Cell 'PENDANT' 80 $Pal.Muted $numFuiteDur 's' 24
$numCap = New-Num 0 0 1 60 $S.CapInterval;     $cCap = New-Cell 'CAPTURE' 60 $Pal.Muted $numCap 's' 24
$numFin = New-Num 0 0 10 600 $S.FinCalme;      $cFin = New-Cell 'FIN APRÈS' 80 $Pal.Muted $numFin 's de calme' 90
$numInt = New-Num 0 0 2 300 $S.Interval;       $cInt = New-Cell 'MESURE TOUTES LES' 140 $Pal.Muted $numInt 's' 20
$lblFuite = $cFuite.L; $lblCapS = $cCap.L; $lblFin = $cFin.L
$tips.SetToolTip($lblFuite, "Fuite suspectée quand la mémoire de Star Citizen augmente plus vite que ce seuil (pente sur 15 s)`nsans interruption pendant la durée indiquée. Exemple : 100 Mo/s pendant 15 s.")
$tips.SetToolTip($cFuiteDur.L, "Durée pendant laquelle la hausse doit rester au-dessus du seuil « FUITE » pour déclencher l'alerte.")
$tips.SetToolTip($lblCapS, "Intervalle des mesures du tampon de capture en temps normal (1 mesure par seconde dès qu'une hausse est suspectée).")
$tips.SetToolTip($lblFin, "Retour à la normale : la fuite / l'incident n'est terminé qu'après cette durée de calme (pente 30 s < seuil / 3).`nUne nouvelle hausse pendant ce délai prolonge le même incident.")
$chkAuto = New-Check 'Tracking auto' 0 0 130 $S.AutoTrack
$tips.SetToolTip($chkAuto, "Démarre l'enregistrement au lancement de Star Citizen et l'arrête à sa fermeture.")
$chkSon = New-Check 'Son' 0 0 60 $S.Son
$chkTop = New-Check 'Premier plan' 0 0 120 $S.TopMost
$lblKey = New-Label 'Ctrl+Alt+R repère · D masquer' 0 0 200 18 (Fnt 8.5 $false $fontTech) $Pal.Muted
$form.TopMost = [bool]$S.TopMost

# boutons (placés par Layout-Full : une ligne, deux lignes de deux, ou un par ligne)
$y = 0
function New-Btn($text, $x, $w) {
    $b = New-Object System.Windows.Forms.Button; $b.Text = $text; $b.SetBounds($x, $y, $w, 34)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $Pal.Cyan
    $b.FlatAppearance.MouseOverBackColor = $Pal.CyanHover; $b.FlatAppearance.MouseDownBackColor = $Pal.CyanDown
    $b.BackColor = $Pal.Bg; $b.ForeColor = $Pal.Cyan; $b.Font = Fnt 8.5 $false $fontTech; $b.Cursor = 'Hand'
    $b.Add_EnabledChanged({ param($sender, $e) $sender.FlatAppearance.BorderColor = $(if ($sender.Enabled) { $Pal.Cyan } else { $Pal.Line }) })
    $form.Controls.Add($b); return $b
}
$btnTrack = New-Btn 'LANCER LE TRACKING' 16 148
$btnTest = New-Btn "TESTER L'ALERTE" 170 122
$btnMark = New-Btn 'REPÈRE' 298 80; $btnMark.Enabled = $false
$btnAna = New-Btn 'ANALYSE ▾' 384 80
$tips.SetToolTip($btnAna, 'Revoir une session enregistrée : courbes complètes + repères')
$tips.SetToolTip($btnMark, "Poser un repère (aussi : Ctrl+Alt+R, même en jeu)`nCtrl+Alt+D : masquer / réafficher cette fenêtre")
# en-têtes de section repliables : flèche ▾ / ▸ + titre + filet ; un clic masque / réaffiche la section
function New-SecHdr([string]$title, [string]$key) {
    $h = New-Label '' 0 0 10 18 (Fnt 7.5 $true $fontTech) $Pal.Dim 'TopLeft'; $h.Cursor = 'Hand'
    $h.Tag = @{ Title = $title; Key = $key; Hot = $false }
    $h.Add_Paint({ param($sender, $e)
        $gr = $e.Graphics; $gr.SmoothingMode = 'AntiAlias'; $k = $sender.DeviceDpi / 96.0; $t = $sender.Tag
        $col = if ($t.Hot) { $Pal.Cyan } else { $Pal.Dim }
        $a = 3.5 * $k; $cx = 6.0 * $k; $cy = [Math]::Floor($sender.Height / 2.0) + 0.5   # (pas « $s » : PowerShell confondrait avec $S)
        $pts = if ($S[$t.Key]) { @(($cx - $a), ($cy - $a / 2), $cx, ($cy + $a / 2), ($cx + $a), ($cy - $a / 2)) }   # ▾ : section affichée
               else { @(($cx - $a / 2), ($cy - $a), ($cx + $a / 2), $cy, ($cx - $a / 2), ($cy + $a)) }             # ▸ : section masquée
        $pen = New-Object System.Drawing.Pen($col, [single](1.5 * $k)); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        $gr.DrawLines($pen, [System.Drawing.PointF[]]@([System.Drawing.PointF]::new($pts[0], $pts[1]), [System.Drawing.PointF]::new($pts[2], $pts[3]), [System.Drawing.PointF]::new($pts[4], $pts[5])))
        $pen.Dispose()
        $tx = [int](14 * $k); $sz = [System.Windows.Forms.TextRenderer]::MeasureText($t.Title, $sender.Font)
        [System.Windows.Forms.TextRenderer]::DrawText($gr, $t.Title, $sender.Font, (New-Object System.Drawing.Point($tx, [int](($sender.Height - $sz.Height) / 2))), $col)
        $gr.SmoothingMode = 'None'; $lx = $tx + $sz.Width + [int](4 * $k)
        if ($lx -lt $sender.Width) { $gr.DrawLine((Pen-Of $Pal.Line), $lx, [int]$cy, $sender.Width - 1, [int]$cy) } })
    $h.Add_MouseEnter({ param($sender) $sender.Tag.Hot = $true; $sender.Invalidate() })
    $h.Add_MouseLeave({ param($sender) $sender.Tag.Hot = $false; $sender.Invalidate() })
    $h.Add_Click({ param($sender) try { Toggle-Section $sender.Tag.Key } catch { Log-Error "Section : $_" } })
    return $h
}
$hdrGraph = New-SecHdr 'COURBE' 'ShowGraph'
$hdrSet = New-SecHdr 'RÉGLAGES' 'ShowSet'
$hdrEv = New-SecHdr 'ÉVÉNEMENTS' 'ShowEv'
$lblStatus = New-Label 'Tracking arrêté · les CSV vont dans le dossier « tracking ».' 16 0 448 36 (Fnt 8.5) $Pal.Muted
$lblEvent = New-Label 'Dernier événement du jeu : —' 16 0 448 18 (Fnt 8.5) $Pal.Dim
$lblStatus.AutoEllipsis = $true; $lblEvent.AutoEllipsis = $true

# mode compact : tout ce qui est sous l'en-tête se masque, la fenêtre se réduit à l'en-tête + la flèche
$S.Body = @($form.Controls | Where-Object { $_ -ne $head -and $_ -ne $accent -and $_ -ne $tgl })
# contenu de chaque section repliable (mode complet) ; les boutons restent toujours visibles
$SecCtl = @{
    ShowGraph = @($graph, $lblMemSc, $lblMemPf)
    ShowSet   = @(@($cAlert, $cAvert, $cFuite, $cFuiteDur, $cCap, $cFin, $cInt | ForEach-Object { $_.L; $_.N; $_.U }) + @($chkAuto, $chkSon, $chkTop, $lblKey))
    ShowEv    = @($lblStatus, $lblEvent)
}
foreach ($h in $hdrGraph, $hdrSet, $hdrEv) { $tips.SetToolTip($h, 'Clic : masquer / afficher cette section') }
function Apply-Sections {
    foreach ($key in $SecCtl.Keys) { $on = [bool]$S[$key]; foreach ($c in $SecCtl[$key]) { if ($c.Visible -ne $on) { $c.Visible = $on } } }
    $kv = [bool]$S.ShowSet -and [bool]$S.Wide; if ($lblKey.Visible -ne $kv) { $lblKey.Visible = $kv }   # raccourcis : fenêtre large seulement
}
function Toggle-Section([string]$key) {
    if ($S.Compact) { return }
    if ($S.ShowGraph -and $S.K) { $S.GraphH = [int]($graph.Height / $S.K) }   # hauteur de courbe gardée : les autres sections n'y touchent pas
    if ($key -eq 'ShowGraph' -and $S.ShowGraph) { try { Close-Editor $S.Ed $true } catch { } }
    $S[$key] = -not [bool]$S[$key]
    Layout-Full $(if ($S.GraphH) { $S.GraphH } else { $GraphDef })   # la fenêtre grandit / rétrécit de la hauteur de la section
    foreach ($h in $hdrGraph, $hdrSet, $hdrEv) { $h.Invalidate() }
    Save-Settings
}
# en mode compact, l'en-tête lui-même se resserre : valeur + état, mémoire SC, CPU / GPU, vitesse / fuite (K/D, capture masqués)
$S.HeadHide = @($lblCap, $lblBigSub, $hwLine, $lblKd, $lblKdSep, $lblKdP, $lblCapSt)
$S.HeadMove = @($head, $accent, $lblBig, $lblState, $lblProc, $lblHwCpu, $lblHwSep, $lblHwGpu, $lblLeak, $lblLeakSt, $pin, $tgl)
# ---------------------------------------------------------------- mise en page adaptative (mode complet)
# Coordonnées « de conception » (96 ppp) multipliées par $S.K (facteur DPI). Fenêtre large : disposition d'origine ;
# étroite : état sous le gros chiffre, CPU / GPU et K/D l'un sous l'autre, un réglage par ligne, boutons sur 2 lignes
# (ou 1 par ligne). La courbe prend la hauteur restante ; la hauteur minimale suit la largeur.
$S.K = 0; $S.InLayout = $false; $S.HwStack = $false; $S.KdStack = $false; $S.Wide = $true
$WideMin = 440; $NarrowMin = 240; $GraphMin = 70; $GraphDef = 132
foreach ($l in $lblCap, $lblBigSub, $lblLeakSt, $lblCapSt, $lblKey) { $l.AutoEllipsis = $true }
function D([double]$v) { [int][Math]::Round($v * $S.K) }
function Text-W([string]$text, $font) { [System.Windows.Forms.TextRenderer]::MeasureText($text, $font).Width }
# $S.Dry : passe de mesure (Layout-Below calcule la hauteur sans rien déplacer). Déplacer les contrôles pour les remettre
# en place juste après faisait clignoter la fenêtre : Windows recopie leurs pixels à l'écran à chaque déplacement.
function Put($c, $x, $yy, $w, $h) { if (-not $S.Dry) { $c.SetBounds((D $x), (D $yy), (D $w), (D $h)) } }
function Place-Cell($c, $x, $yy, $lw = $c.LW) {
    Put $c.L $x ($yy + 4) $lw 18; Put $c.N ($x + $lw) $yy 58 24; Put $c.U ($x + $lw + 62) ($yy + 4) $c.UW 18 }
# CPU | GPU à partir de ($x, $y) : côte à côte si la version la plus longue tient dans $avail (pixels), sinon l'un
# sous l'autre ; renvoie le $y suivant (conception)
function Place-Hw($x, $y, $avail) {
    $wc = [Math]::Max((Text-W 'CPU  100 %  ·  5.5 GHz  ·  100 °C' $lblHwCpu.Font), $lblHwCpu.Width)
    $wg = [Math]::Max((Text-W 'GPU  100 %  ·  100 °C  ·  450 W' $lblHwGpu.Font), $lblHwGpu.Width)
    $S.HwStack = $wc + $wg + $lblHwSep.Width + (D 8) -gt $avail
    $lblHwCpu.Location = New-Object System.Drawing.Point((D $x), (D $y))
    if ($S.HwStack) { $lblHwSep.Visible = $false; $lblHwGpu.Location = New-Object System.Drawing.Point((D $x), (D ($y + 18))); return $y + 36 }
    $lblHwSep.Visible = $true; $lblHwSep.Top = $lblHwCpu.Top; $lblHwGpu.Top = $lblHwCpu.Top; Place-Row $lblHwCpu $lblHwSep $lblHwGpu
    return $y + 18
}
# tout ce qui est sous la courbe, à partir de $y0 (conception) ; renvoie le bas du contenu
function Layout-Below([double]$y0, [double]$W, [bool]$wide) {
    $y = $y0
    if ($S.ShowGraph) {   # détail mémoire, sous la courbe (fait partie de la section COURBE)
        $y += 4
        $ml = if ($wide) { 1 } else { 2 }   # étroit : détail mémoire sur 2 lignes
        Put $lblMemSc 16 $y ($W - 32) (16 * $ml); $y += 16 * $ml + 2
        Put $lblMemPf 16 $y ($W - 32) (16 * $ml); $y += 16 * $ml + 4
    }
    Put $hdrSet 16 $y ($W - 32) 18; $y += 24
    if (-not $S.ShowSet) { }
    elseif ($wide) {
        Place-Cell $cAlert 18 $y; Place-Cell $cAvert 186 $y; $y += 30
        Place-Cell $cFuite 18 $y; Place-Cell $cFuiteDur 186 $y; $y += 30
        Place-Cell $cCap 18 $y; Place-Cell $cFin 186 $y; $y += 34
        Place-Cell $cInt 18 $y; Put $chkAuto 262 ($y + 2) 130 22; $y += 30
        Put $chkSon 18 $y 60 22; Put $chkTop 86 $y 120 22; Put $lblKey 262 ($y + 3) ($W - 16 - 262) 18; $y += 38
    } else {   # un réglage par ligne (lignes un peu plus serrées) ; raccourcis clavier : dans l'infobulle de REPÈRE
        foreach ($c in $cAlert, $cAvert, $cFuite, $cFuiteDur, $cCap, $cFin) { Place-Cell $c 18 $y 80; $y += 28 }
        $y += 4; Place-Cell $cInt 18 $y; $y += 30
        Put $chkAuto 18 ($y + 2) 130 22; $y += 26
        Put $chkSon 18 $y 60 22; Put $chkTop 86 $y 120 22; $y += 34
    }
    # boutons : la première disposition qui tient (1 ligne, 2 x 2, puis de plus en plus de lignes) ;
    # chaque ligne remplit la largeur, le surplus réparti au prorata des largeurs d'origine
    $bs = @($btnTrack, $btnTest, $btnMark, $btnAna); $wt = @(148, 122, 80, 80)
    $pref = @($bs | ForEach-Object { (Text-W $_.Text $_.Font) + (D 14) })
    $pref[0] = [Math]::Max($pref[0], (Text-W 'ARRÊTER LE TRACKING' $btnTrack.Font) + (D 14))
    $inner = D ($W - 32); $gap = D 6
    $layouts = @(@(, [int[]](0, 1, 2, 3)), @([int[]](0, 1), [int[]](2, 3)), @([int[]]@(0), [int[]](1, 2, 3)), @([int[]]@(0), [int[]]@(1), [int[]](2, 3)))
    $rows = @([int[]]@(0), [int[]]@(1), [int[]]@(2), [int[]]@(3))
    foreach ($lay in $layouts) {
        $ok = $true; foreach ($r in $lay) { $sw = $gap * ($r.Count - 1); foreach ($i in $r) { $sw += $pref[$i] }; if ($sw -gt $inner) { $ok = $false } }
        if ($ok) { $rows = $lay; break } }
    $bh = if ($wide) { 34 } else { 30 }
    foreach ($r in $rows) {
        $tw = 0; $sw = 0; foreach ($i in $r) { $tw += $wt[$i]; $sw += $pref[$i] }
        $extra = [Math]::Max(0, $inner - $gap * ($r.Count - 1) - $sw); $x = D 16; $n = 0
        foreach ($i in $r) {
            $n++; $bw = if ($n -eq $r.Count) { (D 16) + $inner - $x } else { $pref[$i] + [int]($extra * $wt[$i] / $tw) }
            if (-not $S.Dry) { $bs[$i].SetBounds($x, (D $y), $bw, (D $bh)) }; $x += $bw + $gap }
        $y += $bh + 6 }
    $y += 4
    Put $hdrEv 16 $y ($W - 32) 18; $y += 20
    if ($S.ShowEv) {
        $sl = if ($wide) { 2 } else { 3 }; $el = if ($wide) { 1 } else { 2 }
        Put $lblStatus 16 $y ($W - 32) (18 * $sl)
        Put $lblEvent 16 ($y + 2 + 18 * $sl) ($W - 32) (18 * $el)
        $y += 2 + 18 * $sl + 18 * $el }
    return $y
}
function Layout-Full([int]$graphH = 0) {
    if (-not $S.K -or $S.Compact -or $S.InLayout -or $form.WindowState -ne 'Normal') { return }
    $S.InLayout = $true
    $form.SuspendLayout(); $head.SuspendLayout()
    try {
        $cw = $form.ClientSize.Width; $W = $cw / $S.K; $wide = $W -ge $WideMin; $S.Wide = $wide
        $inner = $cw - (D 32)
        # --- en-tête
        Put $lblCap 18 8 $(if ($wide) { 240 } else { $W - 36 }) 16
        Put $lblBig 15 26 240 40
        Put $lblBigSub 18 65 $(if ($wide) { [Math]::Min(254, $W - 226) } else { $W - 36 }) 17
        if ($wide) {
            $lblState.TextAlign = 'TopRight'; Put $lblState ($W - 216) 10 200 18
            $lblProc.TextAlign = 'TopRight'; Put $lblProc ($W - 204) 28 188 54
            $y = 84
        } else {   # état + punaise / flèche sur une ligne, puis Star Citizen (+ head-tracking) sur autant de lignes que nécessaire
            $lblState.TextAlign = 'TopLeft'; Put $lblState 16 84 ($W - 92) 18
            Put $pin ($W - 72) 80 26 26; Put $tgl ($W - 44) 80 26 26
            $nl = [Math]::Max(1, $lblProc.Text.Split("`n").Count)
            $lblProc.TextAlign = 'TopLeft'; Put $lblProc 16 104 ($W - 32) (15 * $nl + 2)
            $y = 104 + 15 * $nl + 6
        }
        Put $hwLine 16 $y ($W - 32) 1; $y += 6
        $y = Place-Hw 16 $y $inner
        # K/D | JOUEURS (textes actuels : Update-KD relance la mise en page), puis l'état de la capture
        # (à droite si la place le permet, sinon dessous, et seulement s'il y a quelque chose à dire)
        $wk = $lblKd.Width; $wp = $lblKdP.Width
        $S.KdStack = $wk + $wp + $lblKdSep.Width + (D 8) -gt $inner
        $lblKd.Location = New-Object System.Drawing.Point((D 16), (D $y))
        if ($S.KdStack) { $lblKdSep.Visible = $false; $lblKdP.Location = New-Object System.Drawing.Point((D 16), (D ($y + 18))); $kdW = $wp; $kdY = $y + 18; $y += 36 }
        else { $lblKdSep.Visible = $true; $lblKdSep.Top = $lblKd.Top; $lblKdP.Top = $lblKd.Top; Place-Row $lblKd $lblKdSep $lblKdP; $kdW = $wk + $wp + $lblKdSep.Width + (D 8); $kdY = $y; $y += 18 }
        $capW = [Math]::Max((D 200), (Text-W '◉  INCIDENT · 1 MESURE/S · 999' $lblCapSt.Font))
        if ($kdW + $capW + (D 8) -le $inner) { $lblCapSt.Visible = $true; $lblCapSt.TextAlign = 'TopRight'; $lblCapSt.SetBounds(($cw - (D 16) - $capW), (D $kdY), $capW, (D 18)) }
        else { $lblCapSt.TextAlign = 'TopLeft'; Put $lblCapSt 16 $y ($W - 32) 18; $lblCapSt.Visible = [bool]$lblCapSt.Text; if ($lblCapSt.Text) { $y += 18 } }
        $S.CapLine = [bool]$lblCapSt.Text
        # vitesse SC + état de la fuite
        $lblLeak.Location = New-Object System.Drawing.Point((D 16), (D $y))
        if ($wide) {
            $lblLeakSt.TextAlign = 'TopRight'; Put $lblLeakSt ($W - 344) $y 268 18
            Put $pin ($W - 72) ($y - 4) 26 26; Put $tgl ($W - 44) ($y - 4) 26 26
            $y += 18
        } else { $lblLeakSt.TextAlign = 'TopLeft'; Put $lblLeakSt 16 ($y + 18) ($W - 32) 18; $y += 36 }
        $y += 6
        Put $head 0 0 $W $y; Put $accent 0 ($y - 2) $W 2
        # --- section COURBE (hauteur restante) puis le reste
        Put $hdrGraph 16 ($y + 6) ($W - 32) 18
        $gy = $y + 28
        $S.Dry = $true; try { $bl = Layout-Below 0 $W $wide } finally { $S.Dry = $false }   # mesure seulement
        $below = (D $bl) + (D 12)   # hauteur sous la courbe (marge basse comprise)
        $gTop = if ($S.ShowGraph) { D $gy } else { D ($y + 26) }
        $need = $gTop + $below
        $bw = $form.Width - $form.ClientSize.Width; $bh = $form.Height - $form.ClientSize.Height   # bordures + barre de titre
        if ($S.ShowGraph) {   # hauteur libre, la courbe prend le reste
            $min = New-Object System.Drawing.Size(((D $NarrowMin) + $bw), ($need + (D $GraphMin) + $bh))
            if (-not $form.MaximumSize.IsEmpty) { $form.MaximumSize = [System.Drawing.Size]::Empty }
            if ($form.MinimumSize -ne $min) { $form.MinimumSize = $min }   # agrandit la fenêtre si besoin
            if ($graphH -gt 0) { $form.ClientSize = New-Object System.Drawing.Size($cw, ($need + (D $graphH))) }
        } else {   # pas de courbe : hauteur fixée au contenu (seule la largeur se règle)
            $min = New-Object System.Drawing.Size(((D $NarrowMin) + $bw), ($need + $bh))
            $max = New-Object System.Drawing.Size(32000, ($need + $bh))
            if ($form.MinimumSize -ne $min) { $form.MinimumSize = $min }
            if ($form.MaximumSize -ne $max) { $form.MaximumSize = $max }
            if ($form.ClientSize.Height -ne $need) { $form.ClientSize = New-Object System.Drawing.Size($cw, $need) }
        }
        Apply-Sections
        if ($S.ShowGraph) {
            $gh = [Math]::Max((D $GraphMin), $form.ClientSize.Height - $need)
            $graph.SetBounds((D 16), $gTop, (D ($W - 32)), $gh)
            [void](Layout-Below ($graph.Bottom / $S.K) $W $wide)
        } else { [void](Layout-Below ($gTop / $S.K) $W $wide) }
        Place-Delta
    } finally { $head.ResumeLayout(); $form.ResumeLayout(); $S.InLayout = $false }
}
$form.Add_Resize({ try { Layout-Full } catch { Log-Error "Mise en page : $_" } })
$lblCapSt.Add_TextChanged({ if ([bool]$this.Text -ne $S.CapLine) { try { Layout-Full } catch { Log-Error "Mise en page : $_" } } })   # sa ligne propre (étroit) : affichée / retirée
$lblProc.Add_TextChanged({ if (-not $S.Wide) { try { Layout-Full } catch { Log-Error "Mise en page : $_" } } })   # étroit : sa hauteur suit le nombre de lignes
$graph.Add_Resize({ if ($S.Ed -and $S.Ed.Active) { try { Layout-Editor $S.Ed } catch { } } })

function Set-Compact([bool]$on) {
    if ($on) { try { Close-Editor $S.Ed $true } catch { } }
    if ($on -ne [bool]$S.Compact) { Remember-Pos }   # position du mode qu'on quitte
    if ($on -and -not $S.Compact) {   # mémorise la taille du mode complet
        $S.FullH = $form.ClientSize.Height; $S.FullW = $form.ClientSize.Width }
    $form.SuspendLayout()
    $S.InLayout = $true; try {   # les redimensionnements ci-dessous ne doivent pas relancer la mise en page du mode complet
    foreach ($c in $S.Body) { $c.Visible = -not $on }
    if (-not $on) { Apply-Sections }   # sections repliées : restent masquées
    foreach ($c in $S.HeadHide) { $c.Visible = -not $on }
    if ($on) {
        $form.MaximumSize = [System.Drawing.Size]::Empty; $form.MinimumSize = [System.Drawing.Size]::Empty
        # largeur : celle du mode complet, plafonnée à 380 (fenêtre étroite = bandeau étroit)
        $W = 380; if ($S.FullW -and $S.K) { $W = [Math]::Max($NarrowMin, [Math]::Min(380, [Math]::Floor($S.FullW / $S.K))) }
        Put $lblBig 10 2 170 40
        $ph = [Math]::Ceiling($lblProc.Font.GetHeight() / $S.K) + 1   # une ligne exactement : Star Citizen seulement
        if ($W -ge 380) {
            $lblState.TextAlign = 'TopRight'; Put $lblState ($W - 14 - 170) 8 170 18
            $lblProc.TextAlign = 'TopRight'; Put $lblProc ($W - 14 - 190) 26 190 $ph
            $y = Place-Hw 14 44 (D ($W - 28))
        } else {   # étroit : état + punaise / flèche sous le chiffre, puis Star Citizen, CPU / GPU
            $lblState.TextAlign = 'TopLeft'; Put $lblState 14 44 ($W - 28 - 60) 18
            Put $pin ($W - 64) 40 26 26; Put $tgl ($W - 36) 40 26 26
            $lblProc.TextAlign = 'TopLeft'; Put $lblProc 14 62 ($W - 28) $ph
            $y = Place-Hw 14 80 (D ($W - 28))
        }
        # VITESSE SC à gauche ... état de fuite, punaise, flèche à droite (étroit : état de fuite dessous)
        $lblLeak.Location = New-Object System.Drawing.Point((D 14), (D $y))
        if ($W -ge 380) {
            $lblLeakSt.TextAlign = 'TopRight'; Put $lblLeakSt ($W - 66 - 220) $y 220 18
            Put $pin ($W - 64) ($y - 4) 26 26; Put $tgl ($W - 36) ($y - 4) 26 26
            $y += 18
        } else { $lblLeakSt.TextAlign = 'TopLeft'; Put $lblLeakSt 14 ($y + 18) ($W - 28) 18; $y += 36 }
        Put $head 0 0 $W ($y + 4); Put $accent 0 ($y + 2) $W 2
        $form.ClientSize = New-Object System.Drawing.Size((D $W), $accent.Bottom) }
    else {
        $ww = if ($S.FullW) { $S.FullW } else { $form.ClientSize.Width }
        $hh = if ($S.FullH) { $S.FullH } else { $form.ClientSize.Height }
        $form.ClientSize = New-Object System.Drawing.Size($ww, $hh)
        try { Update-Pagefile; Update-MemLabels $(if ($S.ScPid) { Get-ScMem 'ui' -Shared } else { $null }) } catch { } }   # détail masqué en compact : remis à jour tout de suite
    $tips.SetToolTip($tgl, $(if ($on) { 'Afficher la courbe et les options' } else { 'Masquer la courbe et les options (mode compact)' }))
    } finally { $form.ResumeLayout(); $S.InLayout = $false }
    $S.Compact = $on; $tgl.Invalidate(); Layout-Full; Place-Delta; Update-Chrome
    # position mémorisée du mode où l'on arrive (sinon : le contenu reste où il est)
    if ($on -and $S.XC -ne $null -and $S.YC -ne $null) { Move-ClientTo ([int]$S.XC) ([int]$S.YC) }
    elseif (-not $on -and $S.X -ne $null -and $S.Y -ne $null) { $pt = New-Object System.Drawing.Point([int]$S.X, [int]$S.Y); if (Test-OnScreen $pt) { $form.Location = $pt } }
}
# une position par mode : ouvert = coin de la fenêtre (X, Y) ; réduit = coin du contenu (XC, YC), indépendant de la barre de titre
function Test-OnScreen($pt) { [bool]([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($pt) }) }
function Move-ClientTo([int]$x, [int]$yy) {
    if (-not (Test-OnScreen (New-Object System.Drawing.Point(($x + 20), ($yy + 20))))) { return }   # écran débranché : on ne bouge pas
    $o = $form.PointToScreen([System.Drawing.Point]::Empty)
    $form.Location = New-Object System.Drawing.Point(($form.Left + $x - $o.X), ($form.Top + $yy - $o.Y))
}
# taille du mode complet, en coordonnÃ©es de conception (indÃ©pendante du DPI)
function Remember-Size {
    if (-not $S.K -or -not $form.IsHandleCreated -or $form.WindowState -ne 'Normal') { return }
    $cs = if ($S.Compact) { New-Object System.Drawing.Size([int]$S.FullW, [int]$S.FullH) } else { $form.ClientSize }
    if ($cs.Width -gt 0 -and $cs.Height -gt 0) { $S.W = [int]($cs.Width / $S.K); $S.H = [int]($cs.Height / $S.K) }
}
function Remember-Pos {
    if (-not $form.IsHandleCreated -or $form.WindowState -ne 'Normal') { return }   # réduite dans la barre des tâches : position bidon
    if ($S.Compact) { $o = $form.PointToScreen([System.Drawing.Point]::Empty); $S.XC = $o.X; $S.YC = $o.Y }
    else { $S.X = $form.Left; $S.Y = $form.Top }
}
# compact + épinglé : pas de barre de titre (la fenêtre se déplace par clic-glisser) ; sinon fenêtre normale.
# Le contenu reste à la même place à l'écran.
function Update-Chrome {
    $want = if (-not $S.Compact) { [System.Windows.Forms.FormBorderStyle]::Sizable } elseif ($S.TopMost) { [System.Windows.Forms.FormBorderStyle]::None } else { [System.Windows.Forms.FormBorderStyle]::FixedSingle }
    if ($form.FormBorderStyle -eq $want) { return }
    $cs = $form.ClientSize
    $o = if ($form.IsHandleCreated) { $form.PointToScreen([System.Drawing.Point]::Empty) } else { $null }
    $form.FormBorderStyle = $want; $form.ClientSize = $cs
    if ($o) { $n = $form.PointToScreen([System.Drawing.Point]::Empty); $form.Location = New-Object System.Drawing.Point(($form.Left + $o.X - $n.X), ($form.Top + $o.Y - $n.Y)) }
    $head.Invalidate()
    Layout-Full   # la bordure redimensionnable change la taille minimale de la fenÃªtre
}
function Set-Pin([bool]$on) {
    $S.TopMost = $on; $form.TopMost = $on
    if ($chkTop.Checked -ne $on) { $chkTop.Checked = $on }
    $tips.SetToolTip($pin, $(if ($on) { 'Désépingler (retirer du premier plan)' } else { 'Épingler au premier plan (sans barre de titre, déplaçable en cliquant dessus)' }))
    $pin.Invalidate(); Update-Chrome
}
$tgl.Add_Click({ try { Set-Compact (-not $S.Compact); Save-Settings } catch { Log-Error "Mode compact : $_" } })
$pin.Add_Click({ try { Set-Pin (-not $S.TopMost); Save-Settings } catch { Log-Error "Épingler : $_" } })

# ---------------------------------------------------------------- repères
function Add-Event([string]$label, [string]$kind, [datetime]$when) {
    $txt = '{0} ({1})' -f $label, $when.ToString('HH:mm:ss')
    if ($S.Tracking) { $S.Markers.Add($txt) }
    $Cap.Markers.Add($txt)   # aussi dans le tampon de capture (contexte d'un éventuel incident)
    # Orig + Clock identifient le repère dans le CSV ; Label = nom affiché (renommable), Note = précision perso
    $ev = @{ N = $S.TickN; Kind = $kind; Orig = $label; Label = $label; When = $when; Clock = $when.ToString('HH:mm:ss'); Note = ''
             Csv = $(if ($S.Tracking) { $S.Csv } else { $null }) }
    $S.Events.Add($ev); if ($S.Events.Count -gt 400) { $S.Events.RemoveAt(0) }
    $ck = @{ kill = 'k'; killp = 'kp'; death = 'd'; deathp = 'dp' }[$kind]; if ($ck) { $S.KD[$ck]++; Update-KD }
    $S.LastAdded = $ev
    if ($kind -match '^(auto|kill|killp|death|deathp|leak|soft)$') { $S.LastEvent = $txt; $lblEvent.Text = "Dernier événement du jeu : $txt"; $lblEvent.ForeColor = $Pal.Muted }
    $graph.Invalidate()
}
# renommage / note d'un repère -> colonne Repere du CSV :
#   « nom <libellé d'origine> (hh:mm:ss) : <nouveau nom> »  et  « note <libellé d'origine> (hh:mm:ss) : <texte> »
function Write-MarkerLine([string]$csv, [string]$line) {
    if (-not $csv) { return $false }
    if ($S.Tracking -and $csv -eq $S.Csv) { $S.Markers.Add($line); return $true }   # session en cours : ligne suivante
    if (-not (Test-Path -LiteralPath $csv)) { return $false }
    # session terminée : ligne seule ajoutée à la fin de son CSV
    $f = @((Get-Date -Format 'HH:mm:ss'), '', ($line -replace ';', ','))   # colonnes suivantes vides (le nombre varie selon la version du CSV)
    try { ($f -join ';') | Out-File -LiteralPath $csv -Append -Encoding utf8; return $true } catch { Log-Error "Repère : $_"; return $false }
}
function Save-MarkerEdit($ev, [string]$name, [string]$note) {
    $name = ($name -replace '[|;]', '/').Trim(); if (-not $name) { $name = $ev.Orig }   # nom vide = nom d'origine
    $note = ($note -replace '[|;]', '/').Trim()
    $done = @(); $saved = $true
    if ($name -cne $ev.Label) { $ev.Label = $name; $done += 'nom'
        $saved = (Write-MarkerLine $ev.Csv ('nom {0} ({1}) : {2}' -f $ev.Orig, $ev.Clock, $name)) -and $saved }
    if ($note -cne $ev.Note) { $ev.Note = $note; $done += 'note'
        $saved = (Write-MarkerLine $ev.Csv ('note {0} ({1}) : {2}' -f $ev.Orig, $ev.Clock, $(if ($note) { $note } else { '(effacée)' }))) -and $saved }
    if (-not $done.Count) { return }
    # même repère affiché ailleurs (fenêtre principale / autres analyses de la même session)
    if ($ev.Csv) {
        foreach ($o in $S.Events) { if ($o -ne $ev -and $o.Csv -eq $ev.Csv -and $o.Orig -ceq $ev.Orig -and $o.Clock -eq $ev.Clock) { $o.Label = $ev.Label; $o.Note = $ev.Note } }
        foreach ($an in $S.Analyses) { if ($an.Path -ne $ev.Csv) { continue }
            foreach ($o in $an.Marks) { if ($o -ne $ev -and $o.Orig -ceq $ev.Orig -and $o.Clock -eq $ev.Clock) { $o.Label = $ev.Label; $o.Note = $ev.Note } }
            $an.Graph.Invalidate() }
    }
    $graph.Invalidate()
    $lblStatus.ForeColor = $(if ($saved) { $Pal.Cyan } else { $Pal.Warn })
    $lblStatus.Text = "« $($ev.Label) » ($($ev.Clock)) : $($done -join ' + ') " + $(if ($saved) { 'enregistré dans le CSV.' } else { "modifié à l'écran seulement (pas de session enregistrée)." })
}
function Add-ManualMarker {
    if (-not $S.Tracking) {
        $lblStatus.ForeColor = $Pal.Warn; $lblStatus.Text = "Repère ignoré : le tracking n'est pas lancé."; return }
    $S.MarkerCount++
    Add-Event ("repère {0}" -f $S.MarkerCount) 'manual' (Get-Date)
    if ($chkSon.Checked) { $tick.Play() }
    $lblStatus.ForeColor = $Pal.Cyan; $lblStatus.Text = "Repère $($S.MarkerCount) posé à $(Get-Date -Format 'HH:mm:ss') · clic sur un repère de la courbe pour le renommer / annoter."
}

# ---------------------------------------------------------------- survol / notes sur la courbe
$S.HoverX = -1; $S.LastAdded = $null
# vue de la courbe : VSpan mesures affichées (zoom molette), VEnd = âge du bord droit (0 = en direct ; glisser pour défiler)
$S.VSpan = 899.0; $S.VEnd = 0.0; $S.Pan = $null; $S.Panned = $false
function Clamp-Live {
    $S.VSpan = [Math]::Min(899.0, [Math]::Max(30.0, $S.VSpan))   # de 1 min à 30 min
    $S.VEnd = [Math]::Min(899.0 - $S.VSpan, [Math]::Max(0.0, $S.VEnd)); if ($S.VEnd -lt 0.5) { $S.VEnd = 0.0 }
}
function Age-X([double]$age) { 30 + ($graph.ClientSize.Width - 38) * (1 - ($age - $S.VEnd) / $S.VSpan) }   # padL 30, padR 8
function X-Age([double]$x) { $S.VEnd + $S.VSpan * (1 - ($x - 30) / ($graph.ClientSize.Width - 38)) }
function Event-X($ev) {
    $age = $S.TickN - $ev.N; if ($age -ge 900 -or $age -lt $S.VEnd - 0.5 -or $age -gt $S.VEnd + $S.VSpan + 0.5) { return $null }
    return Age-X $age
}
function Find-Events([double]$mx) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($ev in $S.Events) { $x = Event-X $ev; if ($x -ne $null -and [Math]::Abs($x - $mx) -le 5) { $out.Add($ev) } }
    return , $out
}
# éditeur de repère (nom + note), posé en bas d'une courbe ; partagé par la fenêtre principale et l'analyse.
# NB : variable $ed (et non $E) — PowerShell ne distingue pas $E de $e (arguments d'événement).
function New-MarkerEditor($g, [int]$padL, [int]$padR, [int]$padB) {
    $ed = @{ Graph = $g; PadL = $padL; PadR = $padR; PadB = $padB; List = $null; Idx = 0; Active = $null }
    $p = New-Object System.Windows.Forms.Panel; $p.BackColor = $Pal.Bg; $p.Visible = $false; $g.Controls.Add($p)
    $hdr = New-Label '' 4 2 300 16 (Fnt 7.5 $false $fontTech) $Pal.Cyan 'TopLeft' $p; $hdr.AutoEllipsis = $true
    $mk = { param($max) $t = New-Object System.Windows.Forms.TextBox; $t.BorderStyle = 'FixedSingle'; $t.BackColor = $Pal.Field; $t.ForeColor = $Pal.Text
        $t.Font = Fnt 9; $t.MaxLength = $max; $t.Tag = $ed; $p.Controls.Add($t); $t }
    $ed.Panel = $p; $ed.Hdr = $hdr; $ed.Name = & $mk 80; $ed.Note = & $mk 200; $p.Tag = $ed
    $kd = { param($sender, $e)
        $ed = $sender.Tag
        $k = $e.KeyCode
        if ($k -eq [System.Windows.Forms.Keys]::Return) { $e.SuppressKeyPress = $true; Close-Editor $ed $true }
        elseif ($k -eq [System.Windows.Forms.Keys]::Escape) { $e.SuppressKeyPress = $true; Close-Editor $ed $false }
        elseif ($k -eq [System.Windows.Forms.Keys]::Up -or $k -eq [System.Windows.Forms.Keys]::Down) {
            $e.SuppressKeyPress = $true
            if ($ed.List.Count -gt 1) {   # plusieurs repères au même endroit : passer de l'un à l'autre
                Save-MarkerEdit $ed.Active $ed.Name.Text $ed.Note.Text
                $ed.Idx = ($ed.Idx + $(if ($k -eq [System.Windows.Forms.Keys]::Down) { 1 } else { -1 }) + $ed.List.Count) % $ed.List.Count
                Load-EditorItem $ed; $sender.SelectAll() } } }
    $ed.Name.Add_KeyDown($kd); $ed.Note.Add_KeyDown($kd)
    $p.Add_Leave({ param($sender) Close-Editor $sender.Tag $true })   # le focus quitte l'éditeur = on enregistre
    return $ed
}
function Layout-Editor($ed) {
    $w = $ed.Graph.ClientSize.Width; $hh = $ed.Graph.ClientSize.Height
    $bh = $ed.Name.PreferredHeight; $ph = 18 + $bh + 4; $pw = $w - $ed.PadL - $ed.PadR
    $ed.Panel.SetBounds($ed.PadL, $hh - $ed.PadB - $ph - 2, $pw, $ph)
    $ed.Hdr.SetBounds(4, 2, $pw - 8, 16)
    $nw = [int](($pw - 12) * 0.38)
    $ed.Name.SetBounds(4, 18, $nw, $bh); $ed.Note.SetBounds(8 + $nw, 18, $pw - 12 - $nw, $bh)
}
function Load-EditorItem($ed) {
    $ev = $ed.List[$ed.Idx]; $ed.Active = $ev
    $ed.Name.Text = $ev.Label; $ed.Note.Text = $ev.Note
    try { [SCMem]::Cue($ed.Name.Handle, $ev.Orig); [SCMem]::Cue($ed.Note.Handle, 'note / précision (optionnel)') } catch { }
    $multi = if ($ed.List.Count -gt 1) { "   ({0}/{1} · ↑↓)" -f ($ed.Idx + 1), $ed.List.Count } else { '' }
    $ed.Hdr.Text = '{0} · {1}{2}   —   Entrée : valider · Échap : annuler' -f $ev.Clock, $ev.Orig.ToUpper(), $multi
    $ed.Hdr.ForeColor = $(if ($ev.Kind -eq 'auto') { $Pal.Text } else { Mark-Color $ev.Kind })
    $ed.Graph.Invalidate()
}
function Open-Editor($ed, $list, [switch]$Note) {
    if ($ed.Active) { Close-Editor $ed $true }
    if (-not $list -or $list.Count -eq 0) { return }
    $ed.List = @($list); $ed.Idx = 0
    Layout-Editor $ed; Load-EditorItem $ed
    $ed.Panel.Visible = $true; $ed.Panel.BringToFront()
    $box = if ($Note) { $ed.Note } else { $ed.Name }
    [void]$box.Focus(); $box.SelectAll()
}
function Close-Editor($ed, [bool]$save) {
    $ev = $ed.Active; if (-not $ev) { return }
    $ed.Active = $null   # avant de masquer : évite la ré-entrée via Leave
    if ($save) { Save-MarkerEdit $ev $ed.Name.Text $ed.Note.Text }
    $ed.Panel.Visible = $false
    $ed.Graph.Invalidate()
}
# repères sous la souris, les tiens d'abord puis du plus proche au plus loin
function Sort-Hits($hits, [scriptblock]$xOf, [double]$mx) {
    , @($hits | Sort-Object @{ Expression = { if ($_.Kind -eq 'manual') { 0 } else { 1 } } }, @{ Expression = { [Math]::Abs((& $xOf $_) - $mx) } })
}

$S.Analyses = New-Object System.Collections.Generic.List[object]
$S.Ed = New-MarkerEditor $graph 30 8 18
$graph.Add_MouseMove({ param($sender, $e)
    $S.HoverX = $e.X
    if ($S.Pan) {   # clic maintenu + glisser : défiler dans le temps
        $dx = $e.X - $S.Pan.X0; if ([Math]::Abs($dx) -gt 3) { $S.Pan.Moved = $true }
        if ($S.Pan.Moved) { $S.VEnd = $S.Pan.V0 + $dx / ($graph.ClientSize.Width - 38) * $S.VSpan; Clamp-Live } }
    $graph.Cursor = $(if ($S.Pan -and $S.Pan.Moved) { 'SizeWE' } elseif ((Find-Events $e.X).Count) { 'Hand' } else { 'Default' })
    $graph.Invalidate() })
$graph.Add_MouseLeave({ $S.HoverX = -1; $graph.Invalidate() })
$graph.Add_MouseEnter({   # prendre le focus pour recevoir la molette (sans voler celui de l'éditeur ni d'une autre fenêtre)
    if (-not $S.Ed.Active -and [System.Windows.Forms.Form]::ActiveForm -eq $form) { [void]$graph.Focus() } })
$graph.Add_MouseDown({ param($sender, $e) if ($e.Button -eq 'Left') { $S.Pan = @{ X0 = $e.X; V0 = $S.VEnd; Moved = $false } } })
$graph.Add_MouseUp({ $S.Panned = [bool]($S.Pan -and $S.Pan.Moved); $S.Pan = $null; $graph.Invalidate() })
$graph.Add_MouseWheel({ param($sender, $e)
    $am = X-Age $e.X; $fr = ($am - $S.VEnd) / $S.VSpan   # zoom centré sur la souris
    $S.VSpan = $S.VSpan * $(if ($e.Delta -gt 0) { 0.8 } else { 1.25 }); Clamp-Live
    $S.VEnd = $am - $fr * $S.VSpan; Clamp-Live
    $graph.Invalidate() })
$graph.Add_MouseDoubleClick({ param($sender, $e) if (-not (Find-Events $e.X).Count) { $S.VSpan = 899.0; $S.VEnd = 0.0; $graph.Invalidate() } })   # double-clic : vue complète, en direct
$graph.Add_MouseClick({ param($sender, $e)
    if ($S.Panned) { $S.Panned = $false; return }   # fin d'un glisser : pas un clic
    $hits = Find-Events $e.X
    if ($hits.Count) { Open-Editor $S.Ed (Sort-Hits $hits { param($ev) Event-X $ev } $e.X) } else { Close-Editor $S.Ed $true } })

# lecture en direct du Game.log : événements utiles -> repères automatiques
$LogRules = @(
    @{ re = '<Join PU>.*?shard\[([^\]]+)\]'; label = { param($m) "Connexion serveur ($($m.Groups[1].Value))" } }
    @{ re = '<Change Server Start>'; label = { 'Changement de serveur' } }
    @{ re = '<Player Selected Quantum Target'; label = { 'Saut quantique : départ' } }
    @{ re = '<Quantum Drive Arrived'; label = { 'Saut quantique : arrivée' } }
    @{ re = '<Update Inventory Location>'; label = { 'Changement de lieu' } }
    @{ re = 'Added notification "Entering Armistice Zone'; label = { "Zone : entrée en zone d'armistice" } }
    @{ re = 'Added notification "Leaving Armistice Zone'; label = { "Zone : sortie de zone d'armistice" } }
    @{ re = 'Added notification "Entered ([^"]+?) Jurisdiction'; label = { param($m) "Zone : juridiction $($m.Groups[1].Value)" } }
    @{ re = 'Loading screen for .*? closed after ([\d.]+) seconds'; label = { param($m) ('Chargement terminé ({0:0} s)' -f [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)) } }
    @{ re = '<SystemQuit>'; label = { 'Fermeture du jeu' } }
)
function Get-LogTime([string]$line) {
    $ts = [regex]::Match($line, '^<(\d{4}-\d\d-\d\dT[\d:.]+Z)>')
    if ($ts.Success) { try { return [datetime]::Parse($ts.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime() } catch { } }
    return Get-Date
}
# ---- combat : morts, kills, vaisseaux détruits
#   repères : vert doux = PNJ abattu, vert vif = joueur abattu ; rouge doux = mort (PNJ, collision…), rouge vif = tué par un joueur
#   <Vehicle Destroyed> Vehicle '<nom>' [id] class '<classe>' (owner player [0], driver [<id pilote>]) ... reason [Combat] ... killer '<pseudo>' [<id>]
#   <[ActorState] Dead> Actor '<acteur>' [id] ejected from zone '<vaisseau>' [id] ... (vaisseau explosé avec l'acteur dedans : moi OU un PNJ)
#   <Actor Death> CActor::Kill: '<victime>' [id] ... killed by '<tueur>' [id] ...         (mort à pied, selon les versions du jeu)
#   PNJ ou joueur : classe de vaisseau en _AI_, nom PU_… ; sinon l'identifiant : entité du jeu (2000000xxxxx) = PNJ, compte joueur (20xxxxxxxxxx, bien plus grand) = joueur
$S.KD = @{ k = 0; kp = 0; d = 0; dp = 0 }; $S.Me = ''; $S.Rules = ''; $S.VehDead = @{}; $S.PendKills = New-Object System.Collections.Generic.List[object]; $S.LastDeath = [datetime]::MinValue
function Format-KD([int]$k, [int]$d) { if ($k + $d -eq 0) { return '—' }; '{0:0.00}  ({1} / {2})' -f ($k / [Math]::Max(1, $d)), $k, $d }   # K/D sans mort = nombre de kills
function Update-KD {
    $kd = $S.KD
    $lblKd.Text = 'K/D  ' + (Format-KD ($kd.k + $kd.kp) ($kd.d + $kd.dp))
    $lblKdP.Text = 'JOUEURS  ' + (Format-KD $kd.kp $kd.dp)
    $lblKd.ForeColor = $(if ($kd.k + $kd.kp + $kd.d + $kd.dp) { $Pal.Muted } else { $Pal.Dim })
    $lblKdP.ForeColor = $(if ($kd.kp + $kd.dp) { $Pal.Muted } else { $Pal.Dim })
    Place-Row $lblKd $lblKdSep $lblKdP $S.KdStack
    if ($S.K) { try { Layout-Full } catch { Log-Error "Mise en page : $_" } }   # côte à côte ou l'un sous l'autre selon la nouvelle largeur
}
function Ship-Name([string]$cls) { ($cls -replace '_\d{6,}$', '' -replace '(_EA)?_AI(_[A-Za-z]+)?$', '' -replace '_', ' ').Trim() }   # DRAK_Buccaneer_EA_AI_PIR -> DRAK Buccaneer
function Reason-Fr([string]$r) { switch ($r) { 'Combat' { 'combat' } 'Collision' { 'collision' } 'SelfDestruct' { 'autodestruction' } default { $r.ToLower() } } }
function Get-Who([string]$name, [string]$id) {
    # 'npc', 'player' ou '' (inconnu)
    if ($name -match '^(PU_|NPC|AI_)|_AI_|Pilot|Pirate|Vanduul') { return 'npc' }
    $n = 0L
    if ([int64]::TryParse($id, [ref]$n) -and $n -gt 0) { if ($n -lt 201000000000) { return 'npc' } else { return 'player' } }
    return ''
}
function Add-Death([string]$label, [string]$kind, [datetime]$when) {
    if ([Math]::Abs(($when - $S.LastDeath).TotalSeconds) -lt 5) { return }   # une même mort peut apparaître sur plusieurs lignes
    $S.LastDeath = $when; Add-Event $label $kind $when
}
# mode de jeu d'après le Game.log : « Requesting game mode <carte>/<règles> », « gamerules="<règles>" », « <Join PU> », « <SystemQuit> »
#   EA_… = Arena Commander (1) ; SC_Default (ou autre SC_… hors menu) / Join PU = univers persistant (2) ; menu, fermeture, inconnu = 0
$ModeRxSrc = 'gamerules="([^"]+)"|Requesting game mode [^/\s"]*/(\w+)|(<Join PU>)|(<SystemQuit>)'
$ModeRx = New-Object System.Text.RegularExpressions.Regex($ModeRxSrc, [System.Text.RegularExpressions.RegexOptions]::Compiled)
$ModeRxLast = New-Object System.Text.RegularExpressions.Regex($ModeRxSrc, [System.Text.RegularExpressions.RegexOptions]::RightToLeft)
$ModeRxTimed = New-Object System.Text.RegularExpressions.Regex(('(?m)^<(\d{4}-\d\d-\d\dT[\d:.]+Z)>[^\r\n]*?(?:' + $ModeRxSrc + ')'), [System.Text.RegularExpressions.RegexOptions]::Compiled)
function Mode-Of($m) {
    $o = $m.Groups.Count - 5   # $ModeRxTimed : groupes décalés d'un cran (horodatage en 1)
    if ($m.Groups[3 + $o].Success) { return 2 }
    if ($m.Groups[4 + $o].Success) { return 0 }
    $v = if ($m.Groups[1 + $o].Success) { $m.Groups[1 + $o].Value } else { $m.Groups[2 + $o].Value }
    if ($v -like 'EA_*') { return 1 }
    if ($v -like 'SC_*' -and $v -ne 'SC_Frontend') { return 2 }
    return 0
}
function Find-Me {
    # pseudo du joueur (écrit à la connexion, au début du Game.log) : sert à reconnaître ses propres kills
    try {
        $fs = [System.IO.File]::Open($GameLog, 'Open', 'Read', 'ReadWrite, Delete')
        try { $buf = New-Object byte[] ([Math]::Min(6MB, $fs.Length)); $n = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Close() }
        $m = [regex]::Match([System.Text.Encoding]::UTF8.GetString($buf, 0, $n), 'User Login Success - Handle\[([^\]]+)\]')
        if ($m.Success) { $S.Me = $m.Groups[1].Value }
        # mode en cours si le suivi démarre en pleine partie : dernière ligne de mode de la fin du journal
        $fs = [System.IO.File]::Open($GameLog, 'Open', 'Read', 'ReadWrite, Delete')
        try { $len = [int][Math]::Min(4MB, $fs.Length); [void]$fs.Seek(-$len, 'End'); $buf = New-Object byte[] $len; $n = $fs.Read($buf, 0, $len) } finally { $fs.Close() }
        $m = $ModeRxLast.Match([System.Text.Encoding]::UTF8.GetString($buf, 0, $n))
        if ($m.Success) { $S.Mode = Mode-Of $m }
    } catch { }
}
function Flush-Kills([switch]$All) {
    # un vaisseau détruit « par moi » n'est un kill que si ce n'était pas le mien (sinon une ligne Dead suit aussitôt)
    foreach ($k in $S.PendKills.ToArray()) {
        if ($All -or ((Get-Date) - $k.Seen).TotalSeconds -ge 3) { [void]$S.PendKills.Remove($k); Add-Event $k.Label $k.Kind $k.When }
    }
}
function Read-CombatLine([string]$line) {
    $mm = $ModeRx.Match($line); if ($mm.Success) { $S.Mode = Mode-Of $mm }   # couleur de la courbe (ne consomme pas la ligne)
    if ($line.IndexOf('Handle[') -ge 0) {
        $m = [regex]::Match($line, 'User Login Success - Handle\[([^\]]+)\]'); if ($m.Success) { $S.Me = $m.Groups[1].Value }
        return $false }
    if ($line.IndexOf('gamerules="') -ge 0) {   # mode de jeu (EA_FreeFlight, EA_PirateSwarm… pour Arena Commander)
        $m = [regex]::Match($line, 'gamerules="([^"]+)"'); if ($m.Success -and $m.Groups[1].Value -ne 'SC_Frontend') { $S.Rules = $m.Groups[1].Value }
        return $false }
    if ($line.IndexOf('<Vehicle Destroyed>') -ge 0) {
        $m = [regex]::Match($line, "Vehicle '[^']*' \[(\d+)\] class '([^']+)'.*?driver \[(\d+)\].*?reason \[(\w+)\].*?killer '([^']*)' \[(\d+)\]")
        if (-not $m.Success) { return $true }
        $id = $m.Groups[1].Value; $cls = $m.Groups[2].Value
        if ($S.VehDead.ContainsKey($id)) { return $true }   # déjà détruit (épave -> destruction totale)
        if ($S.VehDead.Count -gt 500) { $S.VehDead.Clear() }
        $v = @{ Ship = (Ship-Name $cls); Reason = $m.Groups[4].Value; Killer = $m.Groups[5].Value; KillerWho = (Get-Who $m.Groups[5].Value $m.Groups[6].Value) }
        $S.VehDead[$id] = $v
        if ($S.Me -and $v.Killer -eq $S.Me) {
            # pilote du vaisseau abattu : PNJ / joueur ; pilote [0] (Arena Commander multijoueur) = joueur, sauf modes contre l'IA
            $who = if ($cls -match '_AI_') { 'npc' } else { Get-Who '' $m.Groups[3].Value }
            if (-not $who -and $S.Rules -like 'EA_*' -and $S.Rules -notmatch 'Swarm|Vanduul|Wave|Horde') { $who = 'player' }
            $rs = if ($v.Reason -eq 'Combat') { '' } else { " ($(Reason-Fr $v.Reason))" }
            $lab = switch ($who) { 'player' { "Kill joueur : $($v.Ship)$rs" } 'npc' { "Vaisseau détruit : $($v.Ship) (PNJ)$rs" } default { "Vaisseau détruit : $($v.Ship)$rs" } }
            $S.PendKills.Add(@{ Id = $id; Label = $lab; Kind = $(if ($who -eq 'player') { 'killp' } else { 'kill' }); When = (Get-LogTime $line); Seen = Get-Date }) }
        return $true }
    if ($line.IndexOf('<[ActorState] Dead>') -ge 0) {
        $when = Get-LogTime $line
        # attention : cette ligne existe aussi pour les PNJ (pilote d'un vaisseau qu'on abat) -> uniquement si c'est moi
        $a = [regex]::Match($line, "Actor '([^']+)'")
        if (-not $S.Me -or -not $a.Success -or $a.Groups[1].Value -ne $S.Me) { return $true }
        $m = [regex]::Match($line, "ejected from zone '[^']*' \[(\d+)\]")
        if (-not $m.Success) { Add-Death 'Mort' 'death' $when; return $true }
        $id = $m.Groups[1].Value
        foreach ($k in $S.PendKills.ToArray()) { if ($k.Id -eq $id) { [void]$S.PendKills.Remove($k) } }   # c'était mon vaisseau
        $v = $S.VehDead[$id]
        if (-not $v) { Add-Death 'Mort' 'death' $when; return $true }
        $byOther = $v.Killer -and $v.Killer -ne $S.Me -and $v.Killer -ne 'unknown'
        if ($byOther -and $v.KillerWho -ne 'npc') {
            $verb = if ($v.Reason -eq 'Collision') { 'percuté' } else { 'abattu' }
            Add-Death "Mort : $verb par $($v.Killer) ($($v.Ship))" 'deathp' $when }
        elseif ($byOther) { Add-Death "Mort : abattu par PNJ ($($v.Ship))" 'death' $when }
        else { Add-Death "Mort : $($v.Ship) détruit ($(Reason-Fr $v.Reason))" 'death' $when }
        return $true }
    if ($line.IndexOf('<Actor Death>') -ge 0) {
        $when = Get-LogTime $line
        $m = [regex]::Match($line, "CActor::Kill: '([^']+)' \[(\d+)\].*?killed by '([^']+)' \[(\d+)\]")
        if (-not $m.Success) { return $true }
        $victim = $m.Groups[1].Value; $killer = $m.Groups[3].Value
        if ($S.Me -and $victim -eq $S.Me) {
            if ($killer -eq $S.Me) { Add-Death 'Mort (suicide)' 'death' $when }
            elseif ((Get-Who $killer $m.Groups[4].Value) -eq 'npc') { Add-Death 'Mort : tué par PNJ' 'death' $when }
            else { Add-Death "Mort : tué par $killer" 'deathp' $when } }
        elseif ($S.Me -and $killer -eq $S.Me) {
            if ((Get-Who $victim $m.Groups[2].Value) -eq 'npc') { Add-Event 'Kill : PNJ' 'kill' $when } else { Add-Event "Kill joueur : $victim" 'killp' $when } }
        return $true }
    return $false
}
function Init-GameLog {
    if (Test-Path $GameLog) { $fi = Get-Item $GameLog; $S.LogPos = $fi.Length; $S.LogCtime = $fi.CreationTimeUtc; Find-Me } else { $S.LogPos = 0L; $S.LogCtime = $null }
    $S.LogRest = ''
}
# préfiltre : une seule recherche (compilée) sur tout le bloc lu repère les lignes utiles ; les autres (l'immense
# majorité du Game.log) ne passent plus dans la boucle PowerShell ni dans les ~15 expressions de LogRules / combat
$LogQuick = New-Object System.Text.RegularExpressions.Regex(('<Join PU>|<Change Server Start>|<Player Selected Quantum Target|<Quantum Drive Arrived|<Update Inventory Location>|' +
    'Added notification "(?:Entering|Leaving) Armistice|Added notification "Entered |Loading screen for |<SystemQuit>|User Login Success|gamerules="|Requesting game mode |' +
    '<Vehicle Destroyed>|<\[ActorState\] Dead>|<Actor Death>'), [System.Text.RegularExpressions.RegexOptions]::Compiled)
function Read-GameLog {
    Flush-Kills
    $fi = New-Object System.IO.FileInfo($GameLog)
    if (-not $fi.Exists) { return }
    if ($fi.Length -lt $S.LogPos -or ($S.LogCtime -and $fi.CreationTimeUtc -ne $S.LogCtime)) { $S.LogPos = 0L; $S.LogRest = '' }   # nouveau journal (jeu relancé)
    $S.LogCtime = $fi.CreationTimeUtc
    if ($fi.Length -eq $S.LogPos) { return }
    $fs = [System.IO.File]::Open($GameLog, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        [void]$fs.Seek($S.LogPos, 'Begin')
        $buf = New-Object byte[] ([Math]::Min(8MB, $fs.Length - $S.LogPos))
        $read = $fs.Read($buf, 0, $buf.Length); $S.LogPos += $read
    } finally { $fs.Close() }
    $text = $S.LogRest + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    $cut = $text.LastIndexOf("`n")
    if ($cut -lt 0) { $S.LogRest = $text; return }   # pas encore de ligne complète
    $S.LogRest = $text.Substring($cut + 1); $body = $text.Substring(0, $cut)
    $lastStart = -1
    foreach ($qm in $LogQuick.Matches($body)) {
        $st = $body.LastIndexOf("`n", $qm.Index) + 1; if ($st -eq $lastStart) { continue }   # une ligne une seule fois
        $lastStart = $st
        $en = $body.IndexOf("`n", $qm.Index); if ($en -lt 0) { $en = $body.Length }
        $line = $body.Substring($st, $en - $st)
        if (Read-CombatLine $line) { continue }
        foreach ($rule in $LogRules) {
            $m = [regex]::Match($line, $rule.re)
            if (-not $m.Success) { continue }
            $label = & $rule.label $m
            $when = Get-LogTime $line
            # anti-doublon : même événement à moins de 10 s
            if ($S.LastLabelAt.ContainsKey($label) -and [Math]::Abs(($when - $S.LastLabelAt[$label]).TotalSeconds) -lt 10) { break }
            $S.LastLabelAt[$label] = $when
            Add-Event $label 'auto' $when
            # chargement récent : la détection de fuite exige une hausse plus longue (voir Update-Leak)
            if ($label -match $LeakLoadRe -and ((Get-Date) - $when).TotalSeconds -lt 120) {
                $S.LoadCtxUntil = (Get-Date).AddSeconds(45); if ($S.Leak) { $S.Leak.Load = $true } }
            break
        }
    }
}

# ---------------------------------------------------------------- mesures
function F([double]$v, [string]$fmt = '0.00') { $v.ToString($fmt) }
function Go([double]$b) { F ($b / 1GB) }
function Mo([double]$b) { F ($b / 1MB) '0' }
# nom du processus du jeu (sans .exe)
$ScName = 'StarCitizen'
# instantané des processus (SCProcInfo) : pris une fois par relevé (Tick) et partagé ; repris s'il a plus de 1,5 s
function Get-Snap { if (((Get-Date) - $S.SnapAt).TotalSeconds -ge 1.5) { [void][SCProcInfo]::Snap(); $S.SnapAt = Get-Date } }
$S.SnapAt = [datetime]::MinValue
# logiciels de head-tracking : lancement / fermeture -> repère (liste modifiable : nom affiché + début du nom de processus)
$SoftList = @(@{ N = 'AITrack'; Pre = 'AITrack' }, @{ N = 'opentrack'; Pre = 'opentrack' }, @{ N = 'TrackIR'; Pre = 'TrackIR' })
$S.SoftOn = @{}
function Watch-Software {
    Get-Snap
    foreach ($sw in $SoftList) {
        $on = $null -ne [SCProcInfo]::Agg($sw.Pre, $true)
        if ($S.SoftOn.ContainsKey($sw.N) -and $S.SoftOn[$sw.N] -ne $on) {   # 1er relevé : état initial, pas un événement
            Add-Event ('Logiciel : {0} {1}' -f $sw.N, $(if ($on) { 'lancé' } else { 'fermé' })) 'soft' (Get-Date) }
        $S.SoftOn[$sw.N] = $on }
}

# ---- chronologie des événements avant une fuite (corrélation dans le temps, pas une preuve de cause)
$ChronoWin = 120; $ChronoAfter = 30
$ChronoNote = "Corrélation dans le temps seulement : un événement qui précède une fuite n'en est pas forcément la cause."
function Format-Rel([double]$s) {
    $sign = if ($s -lt -0.5) { '−' } elseif ($s -gt 0.5) { '+' } else { ' ' }; $a = [Math]::Abs($s)
    if ($a -ge 60) { '{0}{1} min {2:00} s' -f $sign, [int][Math]::Floor($a / 60), [int][Math]::Floor($a % 60) } else { '{0}{1:0} s' -f $sign, $a }
}
# événements (When, Label, Kind, Note) de -120 s à +30 s autour du début estimé ; ni alertes ni repères de fuite
function Get-ChronoEvents($onset, $evs) {
    @($evs | Where-Object { $_.Kind -ne 'leak' -and $_.Kind -ne 'alert' -and $_.Orig -notmatch '^(tracking démarré|Fin du tracking)' -and $_.When -ge $onset.AddSeconds(-$ChronoWin) -and $_.When -le $onset.AddSeconds($ChronoAfter) } | Sort-Object { $_.When })
}
function Chrono-Text($onset, $evs, [string]$title) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($title)
    $list = Get-ChronoEvents $onset $evs; $after = $false
    if (-not @($list | Where-Object { $_.When -le $onset }).Count) { [void]$sb.AppendLine("  aucun événement relevé dans les $ChronoWin s précédentes") }
    foreach ($ev in $list) {
        if (-not $after -and $ev.When -gt $onset) { $after = $true; [void]$sb.AppendLine('  ── début de la hausse ──') }
        [void]$sb.AppendLine(('  {0,-12} {1}  {2}{3}' -f (Format-Rel ($ev.When - $onset).TotalSeconds), $ev.When.ToString('HH:mm:ss'), $ev.Label, $(if ($ev.Note) { "  « $($ev.Note) »" } else { '' }))) }
    if (-not $after) { [void]$sb.AppendLine('  ── début de la hausse ──') }
    [void]$sb.AppendLine("  ($ChronoNote)")
    return $sb.ToString()
}
# type d'événement comparable d'une session à l'autre (sans les détails entre parenthèses) ; $null = non retenu
function Norm-Event([string]$label, [string]$kind) {
    switch ($kind) { 'kill' { return 'Kill (PNJ)' } 'killp' { return 'Kill (joueur)' } 'death' { return 'Mort' } 'deathp' { return 'Mort (tué par un joueur)' }
                     'manual' { return $null } 'alert' { return $null } 'leak' { return $null } }
    if ($label -match '^(tracking démarré|Star Citizen fermé|Fin du tracking)') { return $null }
    $n = $label; do { $prev = $n; $n = $n -replace '\s*\([^()]*\)\s*$', '' } while ($n -ne $prev)
    return $n.Trim()
}

function Get-ProcSum([string]$prefix) {   # processus dont le nom commence par $prefix (instantané du relevé)
    Get-Snap
    $q = [SCProcInfo]::Agg($prefix.TrimStart('^'), $true); if (-not $q) { return $null }
    @{ Priv = $q[1]; Handles = $q[7] }
}

# capteurs matériels : relevés toutes les 2 s, moyennés sur l'intervalle de chaque ligne du CSV
# GPU : NVIDIA -> nvml.dll (le plus complet) ; toutes marques -> Windows (charge, température, puissance en % du TDP)
$HwKeys = 'CPU_pct', 'CPU_GHz', 'CPU_Temp_C', 'GPU_pct', 'GPU_Temp_C', 'GPU_W', 'GPU_Puissance_pct', 'GPU_MHz', 'GPU_Vent_pct', 'Disque_Lecture_Mo_s', 'Disque_Ecriture_Mo_s', 'Pagination_Mo_s', 'Defauts_Page_s'
$Pdh = $null
try { $Pdh = [SCPdh]::new([string[]]@(
        '\Processor Information(_Total)\% Processor Utility',       # charge CPU (comme le Gestionnaire des tâches)
        '\Processor Information(_Total)\% Processor Performance',   # fréquence réelle / fréquence nominale
        '\Processor Information(_Total)\Processor Frequency',       # fréquence nominale (MHz)
        '\PhysicalDisk(_Total)\Disk Read Bytes/sec',
        '\PhysicalDisk(_Total)\Disk Write Bytes/sec',
        '\Memory\Pages Input/sec',
        '\GPU Engine(*)\Utilization Percentage',                     # charge GPU toutes marques (index 6)
        '\Memory\Page Faults/sec',                                   # défauts de page système (doux + durs)
        '\Paging File(_Total)\% Usage')) } catch { Log-Error "Compteurs Windows : $_" }   # fichier d'échange utilisé (% de sa taille)
try { [void][SCGpuWin]::Ok } catch { Log-Error "GPU Windows : $_" }
$S.Hw = @{}; $S.HwAcc = New-Object System.Collections.Generic.List[object]
function Get-HwSample {
    $h = @{}; foreach ($k in $HwKeys) { $h[$k] = [double]::NaN }
    if ($Pdh) {
        $p = $Pdh.Read()
        $h.CPU_pct = [Math]::Min(100.0, $p[0])   # 100.0 : avec 100 (entier), un NaN faisait échouer la conversion (erreurs.log)
        $h.CPU_GHz = $p[2] * $p[1] / 100 / 1000
        $h.Disque_Lecture_Mo_s = $p[3] / 1MB; $h.Disque_Ecriture_Mo_s = $p[4] / 1MB
        $h.Pagination_Mo_s = $p[5] * 4KB / 1MB   # pages lues depuis le disque (fichier d'échange / fichiers mappés)
        $h.Defauts_Page_s = $p[7]
        $h.PfPct = $p[8]                         # hors HwKeys : affichage seulement
    }
    $n = [SCNvml]::Read(); $h.GPU_pct = $n[0]; $h.GPU_Temp_C = $n[1]; $h.GPU_W = $n[2]; $h.GPU_MHz = $n[3]; $h.GPU_Vent_pct = $n[4]
    $gw = [SCGpuWin]::Read(); $h.GPU_Puissance_pct = $gw[1]
    if ([double]::IsNaN($h.GPU_Temp_C)) { $h.GPU_Temp_C = $gw[0] }
    if ([double]::IsNaN($h.GPU_pct) -and $Pdh) { $h.GPU_pct = $Pdh.GpuEngineMax(6, [SCGpuWin]::Luid) }
    $h.CPU_Temp_C = [SCAfterburner]::CpuTemp()
    return $h
}
# mémoire détaillée de Star Citizen (SCProcInfo) ; débits de défauts de page calculés depuis le relevé précédent
# du même consommateur ($who : 'ui', 'csv', 'cap' — chacun son intervalle)
$ScMemPrev = @{}
function Get-ScMem([string]$who, [switch]$Shared) {   # -Shared : instantané du relevé en cours (pas de nouvel appel système)
    $q = $null; try { if ($Shared) { Get-Snap; $q = [SCProcInfo]::Agg($ScName, $false) } else { $q = [SCProcInfo]::Query($ScName) } } catch { }
    if (-not $q) { $ScMemPrev.Remove($who); return $null }
    $now = [Diagnostics.Stopwatch]::GetTimestamp() / [Diagnostics.Stopwatch]::Frequency
    $m = @{ Pid = [int]$q[0]; Priv = $q[1]; WS = $q[2]; PWS = $q[3]; Virt = $q[4]; Faults = $q[5]; Hard = $q[6]; Handles = $q[7]; Threads = $q[8]
            FaultsS = [double]::NaN; HardS = [double]::NaN }
    $pv = $ScMemPrev[$who]
    if ($pv -and $pv.Pid -eq $m.Pid -and $now - $pv.T -gt 0.2) {
        $dt = $now - $pv.T; $df = $m.Faults - $pv.Faults; $dh = $m.Hard - $pv.Hard
        if ($df -ge 0) { $m.FaultsS = $df / $dt }; if ($dh -ge 0) { $m.HardS = $dh / $dt } }   # < 0 : compteur remis à zéro / processus disparu
    $ScMemPrev[$who] = @{ T = $now; Pid = $m.Pid; Faults = $m.Faults; Hard = $m.Hard }
    return $m
}
# taille / utilisation du fichier d'échange (WMI, rafraîchi toutes les 2 min ; l'utilisation en direct vient du compteur % Usage)
$S.PfSize = [double]::NaN; $S.PfUsed = [double]::NaN; $S.PfAt = [datetime]::MinValue
function Update-Pagefile {
    if (((Get-Date) - $S.PfAt).TotalSeconds -lt 120) { return }   # WMI : rarement (la taille bouge peu ; chaque ligne du CSV force un relevé)
    $S.PfAt = Get-Date
    try { $pf = @(Get-CimInstance Win32_PageFileUsage)
          if ($pf.Count) { $S.PfSize = ($pf | Measure-Object AllocatedBaseSize -Sum).Sum / 1024; $S.PfUsed = ($pf | Measure-Object CurrentUsage -Sum).Sum / 1024 }
          else { $S.PfSize = 0.0; $S.PfUsed = 0.0 } } catch { }   # Go ; 0 = pas de fichier d'échange
}
function Pagefile-Used {   # Go utilisés : compteur en direct si possible, sinon dernier relevé WMI
    $pct = if ($S.Hw -and $S.Hw.ContainsKey('PfPct')) { $S.Hw.PfPct } else { [double]::NaN }
    if (-not [double]::IsNaN($pct) -and -not [double]::IsNaN($S.PfSize)) { return $S.PfSize * $pct / 100 }
    return $S.PfUsed
}
function Fmt-N([double]$v, [string]$fmt) { if ([double]::IsNaN($v)) { '—' } else { $v.ToString($fmt) } }
function Update-MemLabels($m) {
    $pfU = Pagefile-Used
    $pct = if ($S.Lim -gt 0) { 100 * $S.Gb / $S.Lim } else { [double]::NaN }
    if ($m) {
        $lblMemSc.Text = 'SC  ENGAGÉE {0} Go  ·  RAM {1} Go (privée {2})  ·  VIRTUELLE {3} Go' -f (Fmt-N ($m.Priv / 1GB) '0.0'), (Fmt-N ($m.WS / 1GB) '0.0'), (Fmt-N ($m.PWS / 1GB) '0.0'), (Fmt-N ($m.Virt / 1GB) '#,0')
        $lblMemSc.ForeColor = $Pal.Muted
        $pfTxt = 'DÉFAUTS DE PAGE SC  {0}/s, dont disque {1}/s' -f (Fmt-N $m.FaultsS '#,0'), (Fmt-N $m.HardS '#,0')
    } else {
        $lblMemSc.Text = 'STAR CITIZEN  —'; $lblMemSc.ForeColor = $Pal.Dim
        $sys = if ($S.Hw -and $S.Hw.ContainsKey('Defauts_Page_s')) { $S.Hw.Defauts_Page_s } else { [double]::NaN }
        $pfTxt = 'DÉFAUTS DE PAGE SYSTÈME  {0}/s' -f (Fmt-N $sys '#,0') }
    $sw = if ([double]::IsNaN($S.PfSize)) { 'ÉCHANGE —' } elseif ($S.PfSize -le 0) { 'PAS DE FICHIER D''ÉCHANGE' } else { 'ÉCHANGE {0} / {1} Go' -f (Fmt-N $pfU '0.0'), (Fmt-N $S.PfSize '0') }
    $lblMemPf.Text = '{0}  ·  ENGAGEMENT {1} %  ·  {2}' -f $pfTxt, (Fmt-N $pct '0'), $sw
}
function Update-HwLabels($h) {
    $na = { param($v, $fmt) if ([double]::IsNaN($v)) { '—' } else { $v.ToString($fmt) } }
    $lblHwCpu.Text = 'CPU  {0} %  ·  {1} GHz  ·  {2}' -f (& $na $h.CPU_pct '0'), (& $na $h.CPU_GHz '0.0'), $(if ([double]::IsNaN($h.CPU_Temp_C)) { '— °C' } else { '{0:0} °C' -f $h.CPU_Temp_C })
    $pow = if (-not [double]::IsNaN($h.GPU_W)) { '{0:0} W' -f $h.GPU_W } elseif (-not [double]::IsNaN($h.GPU_Puissance_pct)) { '{0:0} % TDP' -f $h.GPU_Puissance_pct } else { '— W' }
    $lblHwGpu.Text = 'GPU  {0} %  ·  {1} °C  ·  {2}' -f (& $na $h.GPU_pct '0'), (& $na $h.GPU_Temp_C '0'), $pow
    $lblHwCpu.ForeColor = $(if ($h.CPU_Temp_C -ge 90) { $Pal.Crit } elseif ($h.CPU_Temp_C -ge 80) { $Pal.Warn } else { $Pal.Muted })
    Place-Row $lblHwCpu $lblHwSep $lblHwGpu $S.HwStack
    $lblHwGpu.ForeColor = $(if ($h.GPU_Temp_C -ge 85) { $Pal.Crit } elseif ($h.GPU_Temp_C -ge 78) { $Pal.Warn } else { $Pal.Muted })
}
function Get-HwMean {
    $m = @{}
    foreach ($k in $HwKeys) {
        $sum = 0.0; $cnt = 0
        foreach ($h in $S.HwAcc) { $v = $h[$k]; if ($v -ne $null -and -not [double]::IsNaN($v)) { $sum += $v; $cnt++ } }
        $m[$k] = $(if ($cnt) { $sum / $cnt } else { [double]::NaN }) }
    $S.HwAcc.Clear()
    return $m
}

# ---------------------------------------------------------------- détection de fuite mémoire (Star Citizen)
# Vitesse = pente de la mémoire validée (privée) de SC en Mo/s, par régression linéaire (moindres carrés) sur les
# relevés des 15 et 30 dernières secondes (un toutes les 2 s, horodatés) : lissage sans retard excessif, un relevé
# isolé ne fait pas basculer la pente.
# « Fuite suspectée » = pente 15 s >= seuil, sans interruption, pendant la durée choisie. Les chargements font monter
# SC de 150 à 300 Mo/s pendant 15 à 45 s : pendant 45 s après un événement de chargement du Game.log, la durée exigée
# est allongée de 30 s ; rien pendant les 3 premières minutes du jeu (chargement initial). Le début est estimé après
# coup (creux de mémoire juste avant la montée) : il reste exact même quand la confirmation est retardée.
# Fin d'épisode : pente 30 s < seuil / 3 pendant la durée « FIN APRÈS » (retour à la normale ; une nouvelle hausse
# pendant ce délai prolonge le même épisode), ou jeu fermé. Montée courte avec chargement = « écartée ».
$LeakLoadRe = '^(Connexion serveur|Changement de serveur|Changement de lieu|Chargement terminé|Saut quantique)'
$LeakClock = [System.Diagnostics.Stopwatch]::StartNew()
$S.LeakBuf = New-Object System.Collections.Generic.List[object]; $S.LeakPid = 0; $S.ScStart = Get-Date
$S.Slope15 = [double]::NaN; $S.Slope30 = [double]::NaN; $S.HotSince = $null; $S.Leak = $null; $S.LeakPhase = ''; $S.LeakNeed = 15.0
$S.LoadCtxUntil = [datetime]::MinValue; $S.LeakEps = New-Object System.Collections.Generic.List[object]
function Get-Slope([double]$win) {
    $b = $S.LeakBuf; $n = $b.Count; if ($n -lt 3) { return [double]::NaN }
    $tEnd = $b[$n - 1].T; $tFirst = $tEnd; $k = 0; $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0
    $y0 = $b[$n - 1].Mb   # valeurs centrées : précision
    for ($i = $n - 1; $i -ge 0; $i--) {
        $p = $b[$i]; $x = $p.T - $tEnd; if (-$x -gt $win + 0.5) { break }
        $yv = $p.Mb - $y0; $sx += $x; $sy += $yv; $sxx += $x * $x; $sxy += $x * $yv; $k++; $tFirst = $p.T }
    if ($k -lt 3 -or ($tEnd - $tFirst) -lt $win * 0.6) { return [double]::NaN }   # fenêtre trop peu remplie
    $den = $k * $sxx - $sx * $sx; if ($den -le 1e-9) { return [double]::NaN }
    return ($k * $sxy - $sx * $sy) / $den
}
function Format-Dur([double]$sec) { if ($sec -ge 60) { '{0} min {1:00} s' -f [int][Math]::Floor($sec / 60), [int][Math]::Floor($sec % 60) } else { '{0:0} s' -f $sec } }
function Start-Leak([double]$s15, [bool]$loading) {
    # début estimé : en remontant depuis le franchissement du seuil, dernier relevé « calme »
    # (vitesse sur 2 relevés < seuil / 3) juste avant la montée — le coude de la courbe
    $b = $S.LeakBuf; $j = $b.Count - 1
    while ($j -gt 0 -and $b[$j].T -gt $S.HotSince) { $j-- }
    $best = $null
    for (; $j -ge 2 -and $b[$j].T -ge $S.HotSince - 60; $j--) {
        $dt = $b[$j].T - $b[$j - 2].T
        if ($dt -gt 0 -and ($b[$j].Mb - $b[$j - 2].Mb) / $dt -lt $S.FuiteSeuil / 3) { $best = $b[$j]; break } }
    if (-not $best) { $best = $b[[Math]::Max(0, $j)] }
    $ep = @{ StartN = $best.N; EndN = $null }
    $S.LeakEps.Add($ep); if ($S.LeakEps.Count -gt 20) { $S.LeakEps.RemoveAt(0) }
    $S.Leak = @{ OnsetAt = $best.When; OnsetT = $best.T; OnsetMb = $best.Mb; LastMb = $S.LeakBuf[$S.LeakBuf.Count - 1].Mb; Peak = $s15; Load = $loading; CalmSince = $null; Ep = $ep }
    Add-Event ('Début de fuite suspectée ({0:0} Mo/s)' -f $s15) 'leak' $best.When
    $S.LastAdded.N = $best.N   # repère placé au début estimé, pas à la confirmation
    if ($chkSon.Checked) { $leakSnd.Play() }
    try { Start-Incident $best.T } catch { Log-Error "Capture incident : $_" }
    # chronologie des 120 s précédentes : infobulle de l'état de fuite + fichier texte à côté de l'incident
    try {
        $txt = Chrono-Text $best.When $S.Events ('Fuite suspectée · début estimé {0} ({1:0} Mo/s) — événements des {2} s précédentes :' -f $best.When.ToString('HH:mm:ss'), $s15, $ChronoWin)
        $S.LastChrono = $txt
        $tips.SetToolTip($lblLeakSt, $tipLeakSt + "`n`n" + $txt)
        if ($Cap.File) { [System.IO.File]::AppendAllText(($Cap.File -replace '\.csv$', '_chronologie.txt'), $txt + "`r`n", $Utf8Bom) }
    } catch { Log-Error "Chronologie : $_" }
}
function End-Leak([string]$why) {
    $L = $S.Leak; if (-not $L) { return }
    $S.Leak = $null; $L.Ep.EndN = $S.TickN
    # durée de la montée : du début estimé au début du calme (sans la période de retour à la normale)
    $riseEnd = if ($L.CalmSince -ne $null) { $L.CalmSince } else { $LeakClock.Elapsed.TotalSeconds }
    $dur = $riseEnd - $L.OnsetT
    $info = '+{0:0.0} Go en {1}, pic {2:0} Mo/s' -f (($L.LastMb - $L.OnsetMb) / 1024), (Format-Dur $dur), $L.Peak
    $lab = if ($why) { "Fuite : $why ($info)" } elseif ($L.Load -and $dur -lt 90) { "Fuite écartée : chargement probable ($info)" } else { "Fuite : fin de hausse ($info)" }
    Add-Event $lab 'leak' (Get-Date)
    try { Close-Incident } catch { Log-Error "Capture incident : $_" }
}
# $q : somme SCProcInfo des processus du jeu ([0] pid, [1] Private Bytes, [10] heure de création) ou $null si fermé
function Update-Leak($q) {
    if (-not $q) {
        if ($S.Leak) { End-Leak 'jeu fermé' }
        $S.LeakBuf.Clear(); $S.LeakPid = 0; $S.HotSince = $null; $S.Slope15 = [double]::NaN; $S.Slope30 = [double]::NaN; $S.LeakPhase = ''; return }
    if ([int]$q[0] -ne $S.LeakPid) {   # nouveau processus du jeu
        if ($S.Leak) { End-Leak 'jeu relancé' }
        $S.LeakBuf.Clear(); $S.LeakPid = [int]$q[0]; $S.HotSince = $null
        $S.ScStart = $(if ($q[10] -gt 0) { [datetime]::FromFileTime([long]$q[10]) } else { Get-Date }) }
    $now = $LeakClock.Elapsed.TotalSeconds
    $mb = $q[1] / 1MB
    $S.LeakBuf.Add(@{ T = $now; Mb = $mb; N = $S.TickN; When = Get-Date })
    while ($S.LeakBuf.Count -and $now - $S.LeakBuf[0].T -gt 120) { $S.LeakBuf.RemoveAt(0) }
    $s15 = Get-Slope 15; $s30 = Get-Slope 30; $S.Slope15 = $s15; $S.Slope30 = $s30
    $seuil = [double]$S.FuiteSeuil
    $startup = ((Get-Date) - $S.ScStart).TotalSeconds -lt 180
    $loading = (Get-Date) -lt $S.LoadCtxUntil
    $hot = -not [double]::IsNaN($s15) -and $s15 -ge $seuil
    if ($hot -and -not $startup) { if ($S.HotSince -eq $null) { $S.HotSince = $now } } else { $S.HotSince = $null }
    $S.LeakNeed = [double]$S.FuiteDuree + $(if ($loading) { 30 } else { 0 })
    $L = $S.Leak
    if ($L) {
        $L.LastMb = $mb; if ($s15 -gt $L.Peak) { $L.Peak = $s15 }; if ($loading) { $L.Load = $true }
        $calm = -not [double]::IsNaN($s30) -and $s30 -lt $seuil / 3
        if (-not $calm) { $L.CalmSince = $null } elseif ($L.CalmSince -eq $null) { $L.CalmSince = $now } elseif ($now - $L.CalmSince -ge [double]$S.FinCalme) { End-Leak '' }
    } elseif ($S.HotSince -ne $null -and $now - $S.HotSince -ge $S.LeakNeed) { Start-Leak $s15 $loading }
    $S.LeakPhase = if ($S.Leak) { 'FUITE' } elseif ($startup) { 'demarrage' } elseif ($S.HotSince -ne $null) { 'hausse' } elseif ($loading) { 'chargement' } else { 'stable' }
}
function Update-LeakLabels {
    $fmt = { param($v) if ([double]::IsNaN($v)) { '—' } else { '{0:+0;-0;0}' -f $v } }
    if (-not $S.LeakPhase) { $lblLeak.Text = 'VITESSE SC  —'; $lblLeak.ForeColor = $Pal.Dim; $lblLeakSt.Text = ''; return }
    $lblLeak.Text = 'VITESSE SC  {0} / {1} Mo/s' -f (& $fmt $S.Slope15), (& $fmt $S.Slope30)
    switch ($S.LeakPhase) {
        'FUITE' {
            $L = $S.Leak
            if ($L.CalmSince -ne $null) {   # montée arrêtée : période de retour à la normale avant de clore l'incident
                $lblLeakSt.Text = '●  RETOUR À LA NORMALE  {0:0} / {1:0} s' -f ($LeakClock.Elapsed.TotalSeconds - $L.CalmSince), $S.FinCalme
                $lblLeakSt.ForeColor = $Pal.Leak; $lblLeak.ForeColor = $Pal.Muted }
            else {
                $lblLeakSt.Text = '●  FUITE SUSPECTÉE  {0}  +{1:0.0} Go' -f $L.OnsetAt.ToString('HH:mm:ss'), (($L.LastMb - $L.OnsetMb) / 1024)
                $lblLeakSt.ForeColor = $(if ($S.TickN % 2) { $Pal.Leak } else { $Pal.LeakDim }); $lblLeak.ForeColor = $Pal.Leak } }
        'hausse' {
            $lblLeakSt.Text = '▲  HAUSSE RAPIDE  {0:0} / {1:0} s' -f ($LeakClock.Elapsed.TotalSeconds - $S.HotSince), $S.LeakNeed
            $lblLeakSt.ForeColor = $Pal.Warn; $lblLeak.ForeColor = $Pal.Warn }
        'demarrage' { $lblLeakSt.Text = 'DÉMARRAGE DU JEU · DÉTECTION EN PAUSE'; $lblLeakSt.ForeColor = $Pal.Dim; $lblLeak.ForeColor = $Pal.Muted }
        'chargement' { $lblLeakSt.Text = 'CHARGEMENT · TOLÉRANCE +30 S'; $lblLeakSt.ForeColor = $Pal.Muted; $lblLeak.ForeColor = $Pal.Muted }
        default { $lblLeakSt.Text = '●  STABLE'; $lblLeakSt.ForeColor = $Pal.Dim; $lblLeak.ForeColor = $Pal.Muted }
    }
}

# ---------------------------------------------------------------- capture automatique autour des anomalies
# Tampon circulaire en mémoire : une mesure légère (sans WMI) toutes les « CAPTURE » secondes, conservée 3 min
# (2 min avant le début estimé + 1 min de marge : le début peut précéder la confirmation de 15 à 60 s).
# Dès qu'une hausse rapide est suspectée : 1 mesure par seconde, et le tampon ne jette plus rien d'antérieur à
# 2 min avant la hausse. À la confirmation : tracking\incident_<heure de la 1re mesure>.csv avec les 2 min qui précèdent
# le début estimé, puis chaque mesure ajoutée aussitôt sur disque (rien de perdu si le jeu ou le PC plante).
# Fin : quand la fuite se termine (après la période de retour à la normale) ou à la fermeture du jeu / de l'appli.
# Même format que les sessions (Heure;Minutes;Repere;… mêmes noms de colonnes) : s'ouvre dans ANALYSE.
$Cap = @{ Buf = (New-Object System.Collections.Generic.List[object]); Markers = (New-Object System.Collections.Generic.List[string])
          LastT = -1e9; Fast = $false; Anchor = $null; File = $null; T0 = $null; Rows = 0; Count = 0; LastFile = $null }
$CapPre = 120; $CapKeep = 180
$PdhCap = $null
try { $PdhCap = [SCPdh]::new([string[]]@(
        '\Memory\Pages Input/sec',
        '\Processor Information(_Total)\% Processor Utility',
        '\GPU Process Memory(*)\Dedicated Usage',
        '\GPU Process Memory(*)\Shared Usage',
        '\Memory\Page Faults/sec',
        '\Paging File(_Total)\% Usage',
        '\GPU Adapter Memory(*)\Dedicated Usage')) } catch { Log-Error "Compteurs capture : $_" }   # index 6 : VRAM utilisée (toutes cartes)
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
# colonnes des fichiers incident (mêmes noms que les sessions quand la mesure est la même)
$CapCols = @('Heure','Minutes','Repere','Horodatage','Sys_Validee_Go','Sys_Limite_Validee_Go','Sys_Validee_pct','Sys_RAM_Utilisee_Go','Sys_RAM_Dispo_Go',
    'SC_Lance','SC_Validee_Go','SC_WorkingSet_Go','SC_PrivateWS_Go','SC_Virtuelle_Go','SC_Defauts_s','SC_Defauts_Durs_s','SC_Handles','SC_Threads',
    'SC_GPU_Dediee_Go','SC_GPU_Partagee_Go','SC_Pente15_Mo_s','SC_Pente30_Mo_s','Fuite_Etat',
    'CPU_pct','GPU_pct','CPU_Temp_C','GPU_Temp_C','GPU_W','Pagination_Mo_s','Defauts_Page_s','Pagefile_Go','Pagefile_Taille_Go','Pagefile_pct')
function Get-CapSample {
    $now = Get-Date; $cm = [SCMem]::Commit()
    $p = if ($PdhCap) { $PdhCap.Read() } else { @([double]::NaN) * 7 }
    $r = [ordered]@{}; foreach ($k in $CapCols) { $r[$k] = '' }
    $r.Heure = $now.ToString('HH:mm:ss')
    $r.Repere = ($Cap.Markers -join ' | '); $Cap.Markers.Clear()
    $r.Horodatage = $now.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $r.Sys_Validee_Go = Go $cm[0]; $r.Sys_Limite_Validee_Go = Go $cm[1]; if ($cm[1] -gt 0) { $r.Sys_Validee_pct = F (100.0 * $cm[0] / $cm[1]) '0.0' }
    $r.Sys_RAM_Utilisee_Go = Go ($S.TotalRam - $cm[2]); $r.Sys_RAM_Dispo_Go = Go $cm[2]
    $m = Get-ScMem 'cap'   # sans handle ni WMI : ~3 ms
    if ($m) {
        $r.SC_Lance = 'oui'; $r.SC_Validee_Go = Go $m.Priv; $r.SC_WorkingSet_Go = Go $m.WS; $r.SC_PrivateWS_Go = Go $m.PWS; $r.SC_Virtuelle_Go = Go $m.Virt
        $r.SC_Defauts_s = Fmt-Csv $m.FaultsS '0'; $r.SC_Defauts_Durs_s = Fmt-Csv $m.HardS '0.0'
        $r.SC_Handles = [int]$m.Handles; $r.SC_Threads = [int]$m.Threads
        if ($PdhCap) { $r.SC_GPU_Dediee_Go = Fmt-Csv ($PdhCap.ArraySum(2, "pid_$($m.Pid)_") / 1GB) '0.00'; $r.SC_GPU_Partagee_Go = Fmt-Csv ($PdhCap.ArraySum(3, "pid_$($m.Pid)_") / 1GB) '0.00' }
        $r.SC_Pente15_Mo_s = Fmt-Csv $S.Slope15 '0'; $r.SC_Pente30_Mo_s = Fmt-Csv $S.Slope30 '0'
        $r.Fuite_Etat = $(switch ($S.LeakPhase) { 'FUITE' { 'FUITE' } 'hausse' { 'hausse' } default { '' } })
    } else {
        $sc = @(Get-Process -Name 'StarCitizen' -ErrorAction SilentlyContinue)   # repli (Windows 32 bits…)
        if ($sc.Count) { $r.SC_Lance = 'oui'; $r.SC_Validee_Go = Go (($sc | Measure-Object PrivateMemorySize64 -Sum).Sum); $r.SC_WorkingSet_Go = Go (($sc | Measure-Object WorkingSet64 -Sum).Sum)
                         $r.SC_Virtuelle_Go = Go (($sc | Measure-Object VirtualMemorySize64 -Sum).Sum) } else { $r.SC_Lance = 'non' } }
    $n = [SCNvml]::Read(); $hw = $S.Hw
    $pick = { param($a, $k) if (-not [double]::IsNaN($a)) { $a } elseif ($hw -and $hw.ContainsKey($k)) { $hw[$k] } else { [double]::NaN } }
    $r.CPU_pct = Fmt-Csv ([Math]::Min(100.0, $p[1])) '0.0'
    $r.GPU_pct = Fmt-Csv (& $pick $n[0] 'GPU_pct') '0.0'
    $r.CPU_Temp_C = Fmt-Csv $(if ($hw -and $hw.ContainsKey('CPU_Temp_C')) { $hw.CPU_Temp_C } else { [double]::NaN }) '0.0'
    $r.GPU_Temp_C = Fmt-Csv (& $pick $n[1] 'GPU_Temp_C') '0.0'
    $r.GPU_W = Fmt-Csv $n[2] '0.0'
    $r.Pagination_Mo_s = Fmt-Csv ($p[0] * 4KB / 1MB) '0.0'
    $r.Defauts_Page_s = Fmt-Csv $p[4] '0'
    $r.Pagefile_Taille_Go = Fmt-Csv $S.PfSize '0.00'; $r.Pagefile_pct = Fmt-Csv $p[5] '0.0'
    if (-not [double]::IsNaN($p[5]) -and -not [double]::IsNaN($S.PfSize)) { $r.Pagefile_Go = F ($S.PfSize * $p[5] / 100) '0.00' }
    return @{ T = $LeakClock.Elapsed.TotalSeconds; When = $now; Row = $r }
}
function Write-CapRows($smps, [string]$file = $Cap.File, $t0 = $Cap.T0) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($s in $smps) {
        $s.Row.Minutes = F (($s.When - $t0).TotalMinutes) '0.000'
        [void]$sb.AppendLine((($s.Row.Values | ForEach-Object { "$_" -replace ';', ',' }) -join ';')); if ($file -eq $Cap.File) { $Cap.Rows++ } }
    [System.IO.File]::AppendAllText($file, $sb.ToString(), $Utf8Bom)   # ajout immédiat : survit à un plantage
}
function Start-Incident([double]$onsetT) {
    if ($Cap.File) { return }   # déjà ouvert
    $rows = @($Cap.Buf | Where-Object { $_.T -ge $onsetT - $CapPre })
    if (-not $rows.Count) { $rows = @($Cap.Buf) }
    if (-not $rows.Count) { $rows = @(Get-CapSample); $Cap.Buf.Add($rows[0]) }
    $Cap.T0 = $rows[0].When; $Cap.Rows = 0
    $Cap.File = Join-Path $TrackDir ('incident_{0}.csv' -f $Cap.T0.ToString('yyyy-MM-dd_HH-mm-ss'))
    [System.IO.File]::WriteAllText($Cap.File, (($rows[0].Row.Keys) -join ';') + "`r`n", $Utf8Bom)
    Write-CapRows $rows
    $Cap.Anchor = $null   # ce qui précède est sur disque : le tampon reprend sa taille normale
    $Cap.Count++; $Cap.LastFile = $Cap.File
    Update-CapLabel
}
function Close-Incident([string]$why = '') {
    if (-not $Cap.File) { return }
    if ($why) { $Cap.Markers.Add(('Fin de capture : {0} ({1})' -f $why, (Get-Date -Format 'HH:mm:ss'))) }
    try { $smp = Get-CapSample; $Cap.Buf.Add($smp); Write-CapRows @($smp) } catch { Log-Error "Capture incident : $_" }   # dernière mesure (repère de fin)
    $Cap.File = $null
    Update-CapLabel
}
function Update-CapLabel {
    if ($Cap.File) {
        $lblCapSt.Text = '◉  INCIDENT · 1 MESURE/S · {0}' -f $Cap.Rows
        $lblCapSt.ForeColor = $(if ($Cap.Rows % 2) { $Pal.Leak } else { $Pal.LeakDim }) }
    elseif ($Cap.Fast) { $lblCapSt.Text = '◉  CAPTURE 1 MESURE/S'; $lblCapSt.ForeColor = $Pal.Warn }
    else {
        $lblCapSt.Text = $(if ($Cap.Count) { '{0} INCIDENT(S)' -f $Cap.Count } else { '' })   # au repos : rien (le tampon tourne en silence)
        $lblCapSt.ForeColor = $(if ($Cap.Count) { $Pal.Muted } else { $Pal.Dim }) }
    if ($Cap.LastFile -and $Cap.TipFile -ne $Cap.LastFile) {   # infobulle mise à jour seulement quand l'incident change
        $Cap.TipFile = $Cap.LastFile
        $tips.SetToolTip($lblCapSt, "Dernier incident : $([IO.Path]::GetFileName($Cap.LastFile))`nClic : liste des incidents et accès aux mesures détaillées") }
}
# appelée toutes les secondes : décide s'il faut mesurer (5 s en temps normal, 1 s en cas d'anomalie)
function Cap-Tick {
    $now = $LeakClock.Elapsed.TotalSeconds
    $want = [bool]$Cap.File -or $S.LeakPhase -eq 'hausse' -or $S.LeakPhase -eq 'FUITE'
    if ($want -and -not $Cap.Fast) { $Cap.Fast = $true; if (-not $Cap.File) { $Cap.Anchor = $now - 60 } }   # -60 : le début estimé peut précéder la hausse
    elseif (-not $want -and $Cap.Fast) { $Cap.Fast = $false; $Cap.Anchor = $null }
    $iv = if ($Cap.Fast) { 1.0 } else { [double]$S.CapInterval }
    if ($now - $Cap.LastT -ge $iv - 0.3) {
        $Cap.LastT = $now
        $smp = Get-CapSample; $Cap.Buf.Add($smp)
        $keep = $now - $CapKeep; if ($Cap.Anchor -ne $null) { $keep = [Math]::Min($keep, $Cap.Anchor - $CapPre) }
        while ($Cap.Buf.Count -and $Cap.Buf[0].T -lt $keep) { $Cap.Buf.RemoveAt(0) }
        if ($Cap.File) { Write-CapRows @($smp) }
        # mesures brutes de toute la session (tracking lancé) : chaque mesure du tampon, horodatée, sans moyenne
        if ($S.Tracking -and $S.RawCsv) { try { Write-CapRows @($smp) $S.RawCsv $S.T0 } catch { Log-Error "Mesures brutes : $_" } }
    }
    Update-CapLabel
}

# colonnes du CSV de session (l'en-tête et chaque ligne suivent cette liste : pas de décalage possible)
#   Sys_Validee_* = mémoire engagée du système · Sys_RAM_* = RAM physique
#   SC_Validee_Go = Private Bytes (privé engagé) · SC_WorkingSet_Go / SC_PrivateWS_Go = en RAM · SC_Virtuelle_Go = Virtual Bytes
#   SC_Defauts_s = défauts de page (doux + durs) · SC_Defauts_Durs_s = ceux qui ont lu le disque
$CsvCols = @('Heure','Minutes','Repere','Horodatage','Sys_Validee_Go','Sys_Limite_Validee_Go','Sys_Validee_pct','Sys_RAM_Utilisee_Go','Sys_RAM_Dispo_Go','Sys_GPU_Dediee_Go',
    'SC_Lance','SC_Validee_Go','SC_WorkingSet_Go','SC_PrivateWS_Go','SC_Virtuelle_Go','SC_Defauts_s','SC_Defauts_Durs_s','SC_CPU_pct','SC_Handles','SC_Threads',
    'SC_GPU_Dediee_Go','SC_GPU_Partagee_Go','SC_Pente15_Mo_s','SC_Pente30_Mo_s','Fuite_Etat',
    'AITrack_Mo','AITrack_Handles','opentrack_Mo','opentrack_Handles','Launcher_Mo') + $HwKeys + @('Pagefile_Go','Pagefile_Taille_Go','Pagefile_pct','Top_autres_processus')
function Fmt-Csv([double]$v, [string]$fmt) { if ([double]::IsNaN($v)) { '' } else { F $v $fmt } }
function Write-Row {
    # sans WMI (avant : 4 requêtes, ~300 ms d'interface figée toutes les 15 s et de charge du service WMI) :
    # mémoire système = GetPerformanceInfo, SC = instantané SCProcInfo, VRAM = compteurs PDH déjà ouverts par la capture
    $now = Get-Date
    $cm = [SCMem]::Commit()
    [void][SCProcInfo]::Snap(); $S.SnapAt = $now
    $q = [SCProcInfo]::Agg($ScName, $false)
    $r = [ordered]@{}; foreach ($k in $CsvCols) { $r[$k] = '' }
    $r.Heure = $now.ToString('HH:mm:ss'); $r.Minutes = F (($now - $S.T0).TotalMinutes) '0.0'
    $r.Repere = ($S.Markers -join ' | '); $S.Markers.Clear()
    $r.Horodatage = $now.ToString('yyyy-MM-dd HH:mm:ss.fff')   # date + ms : même format que les fichiers incident / mesures
    $r.Sys_Validee_Go = Go $cm[0]; $r.Sys_Limite_Validee_Go = Go $cm[1]
    if ($cm[1] -gt 0) { $r.Sys_Validee_pct = F (100.0 * $cm[0] / $cm[1]) '0.0' }
    $r.Sys_RAM_Utilisee_Go = Go ($S.TotalRam - $cm[2]); $r.Sys_RAM_Dispo_Go = Go $cm[2]
    if ($PdhCap) { $r.Sys_GPU_Dediee_Go = Fmt-Csv ($PdhCap.ArraySum(6, $null) / 1GB) '0.00' }
    if ($q) {
        $cpu = $q[9]; $cpuPct = ''   # temps CPU cumulé des processus du jeu
        if ($S.PrevCpu -ne $null) { $cpuPct = F ((($cpu - $S.PrevCpu) / (($now - $S.PrevTime).TotalSeconds * $S.Cores)) * 100) '0.0' }
        $S.PrevCpu = $cpu; $S.PrevTime = $now
        $r.SC_Lance = 'oui'; $r.SC_Validee_Go = Go $q[1]; $r.SC_WorkingSet_Go = Go $q[2]; $r.SC_CPU_pct = $cpuPct
        $r.SC_Handles = [int]$q[7]; $r.SC_Threads = [int]$q[8]
        $m = Get-ScMem 'csv' -Shared   # défauts de page : moyenne sur l'intervalle depuis la ligne précédente
        if ($m) { $r.SC_PrivateWS_Go = Go $m.PWS; $r.SC_Virtuelle_Go = Go $m.Virt; $r.SC_Defauts_s = Fmt-Csv $m.FaultsS '0'; $r.SC_Defauts_Durs_s = Fmt-Csv $m.HardS '0.0' }
        if ($PdhCap) { $r.SC_GPU_Dediee_Go = Fmt-Csv ($PdhCap.ArraySum(2, "pid_$([int]$q[0])_") / 1GB) '0.00'; $r.SC_GPU_Partagee_Go = Fmt-Csv ($PdhCap.ArraySum(3, "pid_$([int]$q[0])_") / 1GB) '0.00' }
        $r.SC_Pente15_Mo_s = Fmt-Csv $S.Slope15 '0'; $r.SC_Pente30_Mo_s = Fmt-Csv $S.Slope30 '0'
        $r.Fuite_Etat = $(switch ($S.LeakPhase) { 'FUITE' { 'FUITE' } 'hausse' { 'hausse' } default { '' } })
    } else {
        $r.SC_Lance = 'non'; $S.PrevCpu = $null; $ScMemPrev.Remove('csv')
    }
    $ai = Get-ProcSum '^AITrack'; $ot = Get-ProcSum '^opentrack'; $la = Get-ProcSum '^RSI Launcher'
    $r.AITrack_Mo = $(if ($ai) { Mo $ai.Priv } else { '' }); $r.AITrack_Handles = $(if ($ai) { $ai.Handles } else { '' })
    $r.opentrack_Mo = $(if ($ot) { Mo $ot.Priv } else { '' }); $r.opentrack_Handles = $(if ($ot) { $ot.Handles } else { '' })
    $r.Launcher_Mo = $(if ($la) { Mo $la.Priv } else { '' })
    $hw = Get-HwMean
    foreach ($k in $HwKeys) { $v = $hw[$k]; $r[$k] = $(if ([double]::IsNaN($v)) { '' } elseif ($k -eq 'CPU_GHz') { F $v '0.00' } else { F $v '0.0' }) }
    Update-Pagefile   # taille : WMI au plus toutes les 2 min ; utilisation : compteur % Usage en direct
    $pfU = Pagefile-Used
    $r.Pagefile_Go = Fmt-Csv $pfU '0.00'; $r.Pagefile_Taille_Go = Fmt-Csv $S.PfSize '0.00'
    if ($S.PfSize -gt 0 -and -not [double]::IsNaN($pfU)) { $r.Pagefile_pct = F (100.0 * $pfU / $S.PfSize) '0.0' }
    $r.Top_autres_processus = [SCProcInfo]::Top(4, '^(StarCitizen|AITrack|opentrack|RSI Launcher|Idle|System|Memory Compression|Registry|Secure System)$')
    (($r.Values | ForEach-Object { "$_" -replace ';', ',' }) -join ';') | Out-File -FilePath $S.Csv -Append -Encoding utf8
    $S.Rows++; $S.LastLog = $now
}

function Start-Tracking([string]$why = '') {
    $S.KD = @{ k = 0; kp = 0; d = 0; dp = 0 }; Update-KD   # nouvelle session : ratio remis à zéro
    $S.Stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $S.Csv = Join-Path $TrackDir "session_$($S.Stamp).csv"
    ($CsvCols -join ';') | Out-File -FilePath $S.Csv -Encoding utf8
    # mesures brutes horodatées (5 s, 1 s pendant une anomalie) à côté de la session
    $S.RawCsv = Join-Path $TrackDir "mesures_$($S.Stamp).csv"
    try { [System.IO.File]::WriteAllText($S.RawCsv, ($CapCols -join ';') + "`r`n", $Utf8Bom) } catch { $S.RawCsv = $null; Log-Error "Mesures brutes : $_" }
    $S.Tracking = $true; $S.T0 = Get-Date; $S.Rows = 0; $S.LastLog = [datetime]::MinValue; $S.PrevCpu = $null
    $S.ScSeen = $false; $S.ScGoneAt = $null; $S.MarkerCount = 0; $S.Markers.Clear()
    $S.HwAcc.Clear(); if ($S.Hw.Count) { $S.HwAcc.Add($S.Hw) }   # 1re ligne : dernier relevé des capteurs
    if ($why) { $S.Markers.Add("tracking démarré $why") }
    $btnTrack.Text = 'ARRÊTER LE TRACKING'; $btnTrack.ForeColor = $Pal.Crit; $btnTrack.FlatAppearance.BorderColor = $Pal.Crit
    $btnMark.Enabled = $true
    Write-Row
}
function Stop-Tracking([string]$why = '') {
    if (-not $S.Tracking) { return }
    # repère de fin (sert au rapport : son absence = session interrompue brutalement, appli ou PC planté)
    $end = switch -Wildcard ($why) { '*Star Citizen fermé*' { 'Star Citizen fermé' } '*application fermée*' { 'application fermée' } default { 'arrêt manuel' } }
    try { ((Get-Date -Format 'HH:mm:ss'), '', ('Fin du tracking : {0} ({1})' -f $end, (Get-Date -Format 'HH:mm:ss'))) -join ';' | Out-File -FilePath $S.Csv -Append -Encoding utf8 } catch { }
    $S.Tracking = $false
    $btnTrack.Text = 'LANCER LE TRACKING'; $btnTrack.ForeColor = $Pal.Cyan; $btnTrack.FlatAppearance.BorderColor = $Pal.Cyan
    $btnMark.Enabled = $false
    $copied = ''
    if ($S.ScSeen) {
        # jeu relancé pendant la session : SC a déplacé les journaux précédents dans logbackups -> on les récupère aussi
        $bak = @()
        try { $bak = @(Get-ChildItem (Join-Path (Split-Path -Parent $GameLog) 'logbackups') -Filter '*.log' -ErrorAction Stop |
                Where-Object { $_.LastWriteTime -ge $S.T0 } | Sort-Object LastWriteTime) } catch { }
        $i = 0
        foreach ($b in $bak) { $i++; try { Copy-Item -LiteralPath $b.FullName (Join-Path $TrackDir "Game_$($S.Stamp)_partie$i.log") } catch { Log-Error "Copie logbackups : $_" } }
        if (Test-Path $GameLog) {
            $name = if ($bak.Count) { "Game_$($S.Stamp)_partie$($i + 1).log" } else { "Game_$($S.Stamp).log" }
            try { Copy-Item $GameLog (Join-Path $TrackDir $name); $i++ } catch { Log-Error "Copie Game.log : $_" }
        }
        if ($i -gt 1) { $copied = " + $i Game.log" } elseif ($i -eq 1) { $copied = ' + Game.log' }
    }
    # rapport automatique de la session (même contenu que le panneau RAPPORT de l'analyse)
    $rep = ''
    try { $A = Load-Session $S.Csv
          [System.IO.File]::WriteAllText(($S.Csv -replace '\.csv$', '_rapport.txt'), (Report-Text (Build-SessionReport $A)), $Utf8Bom); $rep = ' + rapport' } catch { Log-Error "Rapport de session : $_" }
    $lblStatus.ForeColor = $Pal.Muted
    $lblStatus.Text = "Tracking arrêté$why · $($S.Rows) mesures enregistrées$copied$rep`nsession_$($S.Stamp).csv"
}

# ---------------------------------------------------------------- boucle (toutes les 2 s)
function Tick {
    $cm = [SCMem]::Commit(); $S.Gb = $cm[0] / 1GB; $S.Lim = $cm[1] / 1GB; $S.Avail = $cm[2] / 1GB
    $S.TickN++
    $S.History.Add($S.Gb); if ($S.History.Count -gt 900) { $S.History.RemoveAt(0) }   # 30 min
    $S.HistMode.Add([int]$S.Mode); while ($S.HistMode.Count -gt $S.History.Count) { $S.HistMode.RemoveAt(0) }
    if ($S.VEnd -gt 0) { $S.VEnd++; Clamp-Live }   # vue déplacée dans le passé : elle reste sur le même moment
    try { $S.Hw = Get-HwSample; $S.HwAcc.Add($S.Hw); if ($S.HwAcc.Count -gt 300) { $S.HwAcc.RemoveAt(0) }; Update-HwLabels $S.Hw } catch { Log-Error "Capteurs : $_" }

    # alerte : au passage du seuil puis tous les 10 Go ; réarmement sous seuil - 5 Go
    if ($S.Gb -ge $S.Seuil) {
        $level = 1 + [Math]::Floor(($S.Gb - $S.Seuil) / 10)
        if ($level -gt $S.AlertLevel) {
            $S.AlertLevel = $level; if ($chkSon.Checked) { $chime.Play() }
            Add-Event ("alerte {0:0} Go" -f ($S.Seuil + 10 * ($level - 1))) 'alert' (Get-Date)
        }
    } elseif ($S.Gb -lt $S.Seuil - 5) { $S.AlertLevel = 0 }

    # affichage
    if ($S.Gb -ge $S.Seuil) { $col = $Pal.Crit; $st = '●  CRITIQUE' }
    elseif ($S.Gb -ge $S.Avert) { $col = $Pal.Warn; $st = '●  ATTENTION' }
    else { $col = $Pal.Ok; $st = '●  NOMINAL' }
    if ($S.Flash -gt 0) { $col = $Pal.Crit; $st = '●  TEST ALERTE' }
    $lblBig.ForeColor = $col; $lblState.ForeColor = $col; $lblState.Text = $st; $accent.BackColor = $col
    $lblBig.Text = ('{0:0.0} Go' -f $S.Gb)
    try { Update-Delta } catch { Log-Error "Variation : $_" }
    $lblBigSub.Text = ('limite {0:0} Go ({1:0} %)  ·  RAM libre {2:0.0} Go' -f $S.Lim, $(if ($S.Lim -gt 0) { 100 * $S.Gb / $S.Lim } else { 0 }), $S.Avail)
    # un seul instantané système des processus par relevé (SCProcInfo, ~3 ms), partagé par tout ce qui suit :
    # jeu, head-tracking, logiciels, détail mémoire, ligne du CSV (avant : Get-Process, bien plus lourd)
    [void][SCProcInfo]::Snap(); $S.SnapAt = Get-Date
    $scQ = [SCProcInfo]::Agg($ScName, $false); $scOn = $null -ne $scQ
    if (-not $scOn) { $S.Mode = 0 }   # jeu fermé (même planté) : courbe blanche
    $scPid = $(if ($scOn) { [int]$scQ[0] } else { 0 })
    $S.ScPid = $scPid   # pour la détection des alt-tab
    $ai = Get-ProcSum 'AITrack'; $ot = Get-ProcSum 'opentrack'
    try { Watch-Software } catch { Log-Error "Logiciels : $_" }
    $lines = @(if ($scOn) { 'STAR CITIZEN  {0:0.0} Go engagés' -f ($scQ[1] / 1GB) } else { 'STAR CITIZEN  —' })
    if ($ai) { $lines += 'AITRACK  {0:0} Mo' -f ($ai.Priv / 1MB) }       # head-tracking : affiché seulement s'il tourne
    if ($ot) { $lines += 'OPENTRACK  {0:0} Mo' -f ($ot.Priv / 1MB) }
    Set-Text $lblProc ($lines -join "`n")
    # détail mémoire (SC + défauts de page + engagement + fichier d'échange)
    # mode compact : lignes masquées, pas calculées (le CSV et la capture d'incident font leurs propres relevés)
    if (-not $S.Compact) { try { Update-Pagefile; Update-MemLabels $(if ($scOn) { Get-ScMem 'ui' -Shared } else { $ScMemPrev.Remove('ui'); $null }) } catch { Log-Error "Détail mémoire : $_" } }

    # dossier du jeu détecté depuis l'exécutable (une fois par lancement du jeu)
    if ($scOn -and $scPid -ne $S.DirPid) {
        $S.DirPid = $scPid
        try {
            $exe = (Get-Process -Id $scPid -ErrorAction Stop).Path   # une seule fois par lancement du jeu
            if ($exe) {
                $dir = Split-Path (Split-Path $exe -Parent) -Parent   # ...\LIVE\Bin64\StarCitizen.exe -> ...\LIVE
                if ($dir -and $dir -ne $GameDir -and -not $TestLog) {
                    Set-GameDir $dir; $S.GameDir = $dir; Save-Settings
                    # jeu lancé après l'appli : son journal est neuf, on le lit depuis le début ; sinon on part de la fin
                    if ([datetime]::FromFileTime([long]$scQ[10]) -gt $AppStart) { $S.LogPos = 0L; $S.LogCtime = $null; $S.LogRest = '' } else { Init-GameLog }
                }
            }
        } catch { Log-Error "Dossier du jeu : $_" }
    }

    # événements du jeu
    try { Read-GameLog } catch { Log-Error "Lecture Game.log : $_" }

    # vitesse de la mémoire de SC + détection de fuite (après le Game.log : chargements de ce relevé pris en compte)
    try { Update-Leak $scQ; Update-LeakLabels } catch { Log-Error "Détection de fuite : $_" }

    # tracking automatique avec le jeu
    if ($chkAuto.Checked -and -not $S.Tracking -and $scOn -and $scPid -ne $S.NoAutoPid) { Start-Tracking '(lancement de Star Citizen)' }

    # enregistrement
    if ($S.Tracking) {
        if ($scOn) { $S.ScSeen = $true; $S.ScGoneAt = $null }
        elseif ($S.ScSeen -and -not $S.ScGoneAt) { $S.ScGoneAt = Get-Date; $S.Markers.Add('Star Citizen fermé') }        if (((Get-Date) - $S.LastLog).TotalSeconds -ge $S.Interval - 0.5) { Write-Row }
        $mins = ((Get-Date) - $S.T0).TotalMinutes
        $S.Blink = -not $S.Blink
        if ($lblStatus.ForeColor -ne $Pal.Cyan -or $S.Blink) {
            $lblStatus.ForeColor = $Pal.Text
            $lblStatus.Text = ("{0}  REC  ·  {1} mesures  ·  {2:0} min  ·  {3} repères{4}`nsession_{5}.csv" -f $(if ($S.Blink) { '●' } else { '○' }), $S.Rows, $mins,
                $S.MarkerCount, $(if ($S.ScGoneAt) { '  ·  jeu fermé, arrêt dans 30 s' } else { '' }), $S.Stamp)
        }
        if ($S.ScGoneAt -and ((Get-Date) - $S.ScGoneAt).TotalSeconds -ge 30) { Write-Row; Stop-Tracking ' (Star Citizen fermé)' }
    }
    if (-not $S.Compact) { $graph.Invalidate() }   # courbe masquée en compact : pas de dessin (l'historique continue, elle se rouvre à jour)
}

# ---------------------------------------------------------------- courbe
$graph.Add_Paint({ param($sender, $e)
    try {
        $gr = $e.Graphics; $gr.SmoothingMode = 'AntiAlias'; $gr.TextRenderingHint = 'ClearTypeGridFit'
        $w = $sender.ClientSize.Width; $hh = $sender.ClientSize.Height; $padL = 30; $padT = 10; $padB = 18; $padR = 8
        $vals = $S.History
        $max = [Math]::Max($S.Seuil + 15, 40); foreach ($v in $vals) { if ($v * 1.1 -gt $max) { $max = $v * 1.1 } }
        $max = [Math]::Ceiling($max / 20) * 20
        $toY = { param($v) $padT + ($hh - $padT - $padB) * (1 - $v / $max) }
        $nMax = 900
        $toX = { param($age) $padL + ($w - $padR - $padL) * (1 - ($age - $S.VEnd) / $S.VSpan) }   # age = nb de mesures depuis la plus récente (vue zoomée / défilée)
        $fnt = Fnt 7.5 $false $fontTech
        $brMuted = Brush-Of ($Pal.Dim)
        $penGrid = Pen-Of ($Pal.Line)
        for ($v = 0; $v -le $max; $v += 20) { $yy = & $toY $v; $gr.DrawLine($penGrid, $padL, $yy, $w - $padR, $yy); $gr.DrawString("$v", $fnt, $brMuted, 4, $yy - 7) }
        foreach ($t in @(@{ v = $S.Avert; col = $Pal.Warn }, @{ v = $S.Seuil; col = $Pal.Crit })) {
            $pen = Pen-Of ([System.Drawing.Color]::FromArgb(170, $t.col)) 1 $true
            $yy = & $toY $t.v; $gr.DrawLine($pen, $padL, $yy, $w - $padR, $yy) }
        $gr.SetClip((New-Object System.Drawing.RectangleF([single]($padL - 4), [single]0, [single]($w - $padL - $padR + 8), [single]$hh)))
        # épisodes de fuite suspectée : bande fuchsia du début estimé à la fin (ou jusqu'à maintenant)
        $brLeak = Brush-Of ([System.Drawing.Color]::FromArgb(34, $Pal.Leak))
        # + hachures sur les 2 minutes qui précèdent le début estimé (fenêtre des événements corrélés)
                foreach ($ep in $S.LeakEps) {
            $p0 = $S.TickN - $ep.StartN + $ChronoWin / 2; $p1 = $S.TickN - $ep.StartN   # 1 relevé = 2 s
            if ($p1 -lt $nMax -and $p0 -ge $S.VEnd -and $p1 -le $S.VEnd + $S.VSpan) {
                $x0 = [single](& $toX ([Math]::Min($p0, $nMax))); $x1 = [single](& $toX $p1)
                $gr.FillRectangle($brPre, $x0, [single]$padT, [single][Math]::Max(1, $x1 - $x0), [single]($hh - $padT - $padB)) }
            $a0 = $S.TickN - $ep.StartN; $a1 = if ($ep.EndN -ne $null) { $S.TickN - $ep.EndN } else { 0 }
            if ($a1 -ge $nMax -or $a0 -lt $S.VEnd -or $a1 -gt $S.VEnd + $S.VSpan) { continue }
            $x0 = [single](& $toX ([Math]::Min($a0, $nMax))); $x1 = [single](& $toX $a1)
            $gr.FillRectangle($brLeak, $x0, [single]$padT, [single][Math]::Max(1, $x1 - $x0), [single]($hh - $padT - $padB)) }
        # repères : gris = jeu, cyan = manuel, rouge = alerte, vert / rouge pastel = kill / mort, jaune = alt-tab (flèche en bas), fuchsia = fuite
        foreach ($ev in $S.Events) {
            $age = $S.TickN - $ev.N; if ($age -ge $nMax -or $age -lt $S.VEnd - 1 -or $age -gt $S.VEnd + $S.VSpan + 1) { continue }
            $x = [single](& $toX $age)
            $col = Mark-Color $ev.Kind
            $a = if ($ev.Kind -eq 'auto') { 90 } else { 200 }
            if ($ev -eq $S.Ed.Active -or ($S.HoverX -ge 0 -and [Math]::Abs($x - $S.HoverX) -le 5)) { $a = 255; if ($ev.Kind -eq 'auto') { $col = $Pal.Text } }
            $low = $ev.Kind -eq 'focus'; $yb = [single]($hh - $padB)
            if ($ev.Note) { $gr.FillEllipse((Brush-Of ($col)), $x - 2.5, $(if ($low) { [single]($padT + 1) } else { $yb - 5 }), 5, 5) }   # point = repère annoté
            $gr.DrawLine((Pen-Of ([System.Drawing.Color]::FromArgb($a, $col)) 1), $x, [single]$padT, $x, $yb)
            $tip = if ($low) { @($yb, ($yb - 5)) } else { @([single]$padT, [single]($padT + 5)) }   # alt-tab : flèche en bas
            $gr.FillPolygon((Brush-Of ([System.Drawing.Color]::FromArgb([Math]::Min(255, $a + 40), $col))),
                [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(($x - 3), [single]$tip[0])), (New-Object System.Drawing.PointF(($x + 3), [single]$tip[0])), (New-Object System.Drawing.PointF($x, [single]$tip[1]))))
        }
        $cap = if ($S.VSpan -ge 899 -and $S.VEnd -eq 0) { '30 DERNIÈRES MINUTES' } else {
            '{0:0} MIN AFFICHÉES  ·  {1}  ·  DOUBLE-CLIC : TOUT' -f ($S.VSpan * 2 / 60), $(if ($S.VEnd -eq 0) { 'EN DIRECT' } else { "JUSQU'À " + (Get-Date).AddSeconds(-2 * $S.VEnd).ToString('HH:mm') }) }
        [System.Windows.Forms.TextRenderer]::DrawText($gr, $cap, $fnt, (New-Object System.Drawing.Point($padL, ($hh - 16))), $Pal.Dim)
        if ($vals.Count -ge 2) {
            $pts = [SCDraw]::Live($vals, $padL, ($w - $padR - $padL), $S.VEnd, $S.VSpan, $padT, ($hh - $padT - $padB), $max)
            $base = [single](& $toY 0)
            # couleur selon le mode au moment du relevé : blanc = menu / jeu fermé, rouge = Arena Commander, bleu = PU
            $mList = if ($S.HistMode.Count -eq $vals.Count) { $S.HistMode } else { New-Object System.Collections.Generic.List[int] }
            foreach ($run in [SCDraw]::Runs($mList, $pts.Count)) {
                $seg = New-Object System.Drawing.PointF[] ($run[1] - $run[0] + 1); [Array]::Copy($pts, $run[0], $seg, 0, $seg.Length)
                if ($seg.Length -lt 2) { continue }
                $col = Mode-Color $run[2]
                $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, [single]$padT)), (New-Object System.Drawing.PointF(0, $base)),
                    [System.Drawing.Color]::FromArgb(70, $col), [System.Drawing.Color]::FromArgb(0, $col))
                $gr.FillPolygon($grad, [SCDraw]::Area($seg, $base)); $grad.Dispose()
                $gr.DrawLines((Pen-Of ($col) 1.6), $seg)
            }
            $last = $pts[$pts.Count - 1]
            $gr.FillEllipse((Brush-Of (Mode-Color $S.Mode)), $last.X - 3, $last.Y - 3, 6, 6)
        }
        $gr.ResetClip()
        if (-not $S.Ed.Active -and $S.HoverX -ge 0) {
            # infobulle des repères sous la souris (pas pendant l'édition : l'éditeur occupe le bas de la courbe)
            $hits = Find-Events $S.HoverX
            if ($hits.Count) {
                $fTip = Fnt 8 $false $fontTech; $fTipB = Fnt 8 $true $fontTech
                $fNote = (Fnt 8.5 $false $fontUI ([System.Drawing.FontStyle]::Italic))
                $rows = New-Object System.Collections.Generic.List[object]
                $age = $S.TickN - $hits[0].N; $idx = $vals.Count - 1 - $age
                if ($idx -ge 0) { $rows.Add(@{ T = ('{0:0.0} Go validés' -f $vals[$idx]); F = $fTipB; C = $Pal.Text }) }
                $shown = 0
                foreach ($ev in $hits) {
                    if ($shown -ge 4) { $rows.Add(@{ T = "+ $($hits.Count - 4) autre(s)"; F = $fTip; C = $Pal.Dim }); break }
                    $shown++
                    $c = Mark-Color $ev.Kind
                    $lab = $ev.Label.Substring(0, 1).ToUpper() + $ev.Label.Substring(1)
                    $rows.Add(@{ T = ('{0}  {1}' -f $ev.Clock, $lab); F = $(if ($ev.Kind -eq 'auto' -and $ev.Label -ceq $ev.Orig) { $fTip } else { $fTipB }); C = $c })
                    if ($ev.Label -cne $ev.Orig) { $rows.Add(@{ T = "à l'origine : $($ev.Orig)"; F = $fTip; C = $Pal.Dim }) }
                    if ($ev.Note) { $rows.Add(@{ T = "« $($ev.Note) »"; F = $fNote; C = $Pal.Text }) }
                }
                $maxW = [single]230; $tw = [single]0; $th = [single]0
                foreach ($r in $rows) { $sz = $gr.MeasureString($r.T, $r.F, [int]$maxW); $r.H = $sz.Height; $th += $sz.Height; if ($sz.Width -gt $tw) { $tw = $sz.Width } }
                $bw = $tw + 14; $bh = $th + 10
                $bx = [single]($S.HoverX + 10); if ($bx + $bw -gt $w - 2) { $bx = [single]($S.HoverX - 10 - $bw) }; if ($bx -lt 2) { $bx = 2 }
                $by = [single]$padT; if ($by + $bh -gt $hh - 2) { $by = [single][Math]::Max(2, $hh - 2 - $bh) }
                $gr.FillRectangle((Brush-Of ([System.Drawing.Color]::FromArgb(240, $Pal.Bg))), $bx, $by, $bw, $bh)
                $gr.DrawRectangle((Pen-Of ($Pal.CyanDim)), $bx, $by, $bw, $bh)
                $yy = $by + 5
                foreach ($r in $rows) {
                    $gr.DrawString($r.T, $r.F, (Brush-Of ($r.C)), (New-Object System.Drawing.RectangleF(($bx + 7), $yy, $maxW, $r.H)))
                    $yy += $r.H }
            }
        }
    } catch { Log-Error "Dessin : $_" }
})

# ---------------------------------------------------------------- analyse d'une session enregistrée
$Inv = [Globalization.CultureInfo]::InvariantCulture
function Num($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return [double]::NaN }
    $v = 0.0; if ([double]::TryParse(($s -replace ',', '.'), [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { return $v } else { return [double]::NaN }
}
function Get-Sessions { @(Get-ChildItem $TrackDir -Filter 'session_*.csv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending) }
function Get-SessionCaption($file) {
    $m = [regex]::Match($file.Name, '(?:session|incident|mesures)_(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)')
    $when = if ($m.Success) { '{0}/{1} {2}:{3}' -f $m.Groups[3].Value, $m.Groups[2].Value, $m.Groups[4].Value, $m.Groups[5].Value } else { $file.BaseName }
    $dur = ''
    if (($S.Tracking -and $file.FullName -eq $S.Csv) -or $file.FullName -eq $Cap.File) { $dur = 'en cours' }
    else { try { $last = (Get-Content -LiteralPath $file.FullName -Tail 3 -Encoding utf8 | ForEach-Object { ($_ -split ';')[1] } | Where-Object { $_ } | Select-Object -Last 1)
                 $mn = Num $last; if (-not [double]::IsNaN($mn)) { $dur = '{0:0} min' -f $mn } } catch { } }
    if ($dur) { "$when  ·  $dur" } else { $when }
}
# zone de texte en lecture seule, au thème sombre, pour les chronologies / récurrences
function New-RichView {
    $rt = New-Object System.Windows.Forms.RichTextBox
    $rt.ReadOnly = $true; $rt.BorderStyle = 'None'; $rt.BackColor = $Pal.Panel; $rt.ForeColor = $Pal.Text; $rt.DetectUrls = $false
    $rt.Font = Fnt 8.5 $false $fontTech; $rt.ScrollBars = 'Vertical'; $rt.WordWrap = $true; $rt.Cursor = 'Hand'
    return $rt
}
function Add-Rich($rt, [string]$text, $color, [bool]$bold = $false) {
    $rt.SelectionStart = $rt.TextLength; $rt.SelectionLength = 0; $rt.SelectionColor = $color
    $rt.SelectionFont = Fnt $rt.Font.Size $false $rt.Font.FontFamily.Name $(if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular })
    $rt.AppendText($text)
}

# ---- événements récurrents avant les fuites, sur toutes les sessions et tous les incidents
# Pour chaque type d'événement : avant combien de fuites il apparaît (dans les 120 s précédant le début estimé),
# comparé à la probabilité qu'il apparaisse dans une fenêtre de 120 s quelconque des sessions (« hasard »).
# Une même fuite présente dans une session et dans son fichier incident n'est comptée qu'une fois.
function Get-LeakCorrelation {
    $files = @(Get-ChildItem $TrackDir -Filter '*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'session_*' -or $_.Name -like 'incident_*' } | Sort-Object Name)
    $eps = [ordered]@{}; $base = @{}; $dur = 0.0; $nSes = 0; $nInc = 0
    foreach ($fi in $files) {
        $A = $null; try { $A = Load-Session $fi.FullName } catch { continue }
        if ($fi.Name -like 'session_*') {   # fréquence « au hasard » : sessions seulement (les incidents en sont des extraits)
            $nSes++; $dur += $A.Dur
            foreach ($mk in $A.Marks) { $n = Norm-Event $mk.Orig $mk.Kind; if ($n) { $base[$n] = 1 + [int]$base[$n] } }
        } else { $nInc++ }
        foreach ($st in @($A.Marks | Where-Object { $_.Kind -eq 'leak' -and ($_.Orig -like 'Début de fuite*' -or $_.Orig -like 'Fuite suspectée*') })) {
            $key = '{0} {1}' -f $st.When.ToString('yyyy-MM-dd'), $st.Clock
            if (-not $eps.Contains($key)) { $eps[$key] = @{ When = $st.When; Label = $st.Orig; Types = [ordered]@{} } }
            $ep = $eps[$key]
            foreach ($mk in $A.Marks) {
                if ($mk.When -lt $st.When.AddSeconds(-$ChronoWin) -or $mk.When -gt $st.When) { continue }
                $n = Norm-Event $mk.Orig $mk.Kind; if ($n) { $ep.Types[$n] = $true } }
        }
    }
    return @{ Eps = @($eps.Values); Base = $base; Dur = $dur; Ses = $nSes; Inc = $nInc }
}
function Show-Recurrence {
    $C = Get-LeakCorrelation
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Événements avant les fuites · toutes sessions'; $f.AutoScaleMode = 'Dpi'; $f.ClientSize = New-Object System.Drawing.Size(860, 640)
    $f.BackColor = $Pal.Bg; $f.ForeColor = $Pal.Text; $f.StartPosition = 'CenterScreen'; $f.Padding = New-Object System.Windows.Forms.Padding(16)
    try { $f.Icon = $form.Icon } catch { }
    $f.Add_HandleCreated({ param($sender) try { [SCMem]::DarkTitle($sender.Handle, (ToRef $Pal.Bg), (ToRef $Pal.CyanDim), (ToRef $Pal.Cyan)) } catch { } })
    $rt = New-RichView; $rt.Dock = 'Fill'; $rt.Cursor = 'Default'; $rt.Font = (Fnt 9.5 $false 'Consolas'); $f.Controls.Add($rt)
    $M = $C.Eps.Count
    Add-Rich $rt "ÉVÉNEMENTS PRÉCÉDANT LES FUITES SUSPECTÉES`n" $Pal.Text $true
    Add-Rich $rt ("{0} fuite(s) suspectée(s) · {1} session(s), {2} incident(s) · {3:0} h {4:00} min de sessions enregistrées`n`n" -f $M, $C.Ses, $C.Inc, [Math]::Floor($C.Dur / 3600), [Math]::Floor(($C.Dur % 3600) / 60)) $Pal.Muted
    Add-Rich $rt "IMPORTANT : $ChronoNote`nCe tableau montre ce qui revient souvent juste avant les fuites. Un événement très fréquent en jeu`n(changement de lieu, chargement…) précède forcément beaucoup de fuites : comparer avec la colonne « hasard ».`nUn écart net, répété sur de nombreuses fuites, désigne une piste à tester (le provoquer volontairement)`n— pas une cause démontrée.`n`n" $Pal.Warn
    if (-not $M) { Add-Rich $rt "Aucune fuite suspectée dans les fichiers du dossier tracking pour l'instant.`n" $Pal.Dim; $f.Show(); return }
    if ($M -lt 3) { Add-Rich $rt "Seulement $M fuite(s) : trop peu pour parler de récurrence, à relire quand il y en aura davantage.`n`n" $Pal.Dim }
    # tableau
    $rows = foreach ($n in @($C.Eps | ForEach-Object { $_.Types.Keys } | Select-Object -Unique)) {
        $k = @($C.Eps | Where-Object { $_.Types.Contains($n) }).Count
        $part = 100.0 * $k / $M
        $hz = if ($C.Dur -gt 0) { 100 * (1 - [Math]::Exp(-[double]$C.Base[$n] / $C.Dur * $ChronoWin)) } else { [double]::NaN }
        [pscustomobject]@{ N = $n; K = $k; Part = $part; Hz = $hz; Ecart = $(if ([double]::IsNaN($hz)) { 0 } else { $part - $hz }) } }
    Add-Rich $rt ("{0,-44}{1,10}{2,8}{3,10}`n" -f "Événement dans les $ChronoWin s avant le début", 'Fuites', 'Part', 'Hasard*') $Pal.Muted $true
    foreach ($r in @($rows | Sort-Object @{ Expression = 'K'; Descending = $true }, @{ Expression = 'Ecart'; Descending = $true })) {
        $nm = if ($r.N.Length -gt 43) { $r.N.Substring(0, 42) + '…' } else { $r.N }
        $hz = if ([double]::IsNaN($r.Hz)) { '—' } else { '{0:0} %' -f $r.Hz }
        # piste à regarder : au moins 3 fuites, présent avant au moins la moitié, et nettement plus souvent qu'au hasard
        $flag = $M -ge 3 -and $r.K -ge 3 -and $r.Part -ge 50 -and $r.Ecart -ge 25
        Add-Rich $rt ("{0,-44}{1,10}{2,8}{3,10}" -f $nm, ('{0} / {1}' -f $r.K, $M), ('{0:0} %' -f $r.Part), $hz) $(if ($flag) { $Pal.Leak } else { $Pal.Text })
        Add-Rich $rt $(if ($flag) { "   ← plus fréquent qu'au hasard`n" } else { "`n" }) $Pal.Leak }
    Add-Rich $rt ("`n* Hasard : probabilité qu'une fenêtre de {0} s prise n'importe où dans les sessions contienne cet événement`n  (calculée sur toutes les sessions enregistrées, fuites ou non).`n" -f $ChronoWin) $Pal.Dim
    # détail
    Add-Rich $rt "`nDÉTAIL PAR FUITE`n" $Pal.Text $true
    foreach ($ep in $C.Eps) {
        Add-Rich $rt ('{0}  ' -f $ep.When.ToString('dd/MM HH:mm:ss')) $Pal.Leak
        Add-Rich $rt $(if ($ep.Types.Count) { (@($ep.Types.Keys) -join ' · ') + "`n" } else { "aucun événement relevé dans les $ChronoWin s précédentes`n" }) $(if ($ep.Types.Count) { $Pal.Text } else { $Pal.Dim }) }
    $rt.SelectionStart = 0
    $f.Show()
}

function Show-AnalysisMenu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object SCMenuColors))
    $menu.ShowImageMargin = $false; $menu.BackColor = $Pal.Panel; $menu.Font = Fnt 9
    $add = { param($text, $tag, $color, $bold)
        $it = New-Object System.Windows.Forms.ToolStripMenuItem($text); $it.ForeColor = $color; $it.Tag = $tag
        if ($bold) { $it.Font = Fnt 9 $true }
        [void]$menu.Items.Add($it); return $it }
    $ses = Get-Sessions
    if ($ses.Count) {
        $it = & $add ('Dernière session  —  ' + (Get-SessionCaption $ses[0])) $ses[0].FullName $Pal.Cyan $true
        $it.Add_Click({ param($sender) Show-Analysis $sender.Tag })
        if ($ses.Count -gt 1) {
            [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            foreach ($f in ($ses | Select-Object -Skip 1 -First 6)) {
                $it = & $add ('      ' + (Get-SessionCaption $f)) $f.FullName $Pal.Text $false
                $it.Add_Click({ param($sender) Show-Analysis $sender.Tag }) }
        }
    } else { $it = & $add 'Aucune session enregistrée' $null $Pal.Dim $false; $it.Enabled = $false }
    # captures automatiques des fuites suspectées
    $inc = @(Get-ChildItem $TrackDir -Filter 'incident_*.csv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($inc.Count) {
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        foreach ($f in ($inc | Select-Object -First 5)) {
            $it = & $add ('Incident de fuite  —  ' + (Get-SessionCaption $f)) $f.FullName $Pal.Leak $false
            $it.Add_Click({ param($sender) Show-Analysis $sender.Tag }) }
    }
    if ($ses.Count -or $inc.Count) {
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $it = & $add 'Incidents détectés…' $null $Pal.Leak $true
        $it.Add_Click({ try { Show-Incidents } catch { Log-Error "Incidents : $_" } })
        $it = & $add 'Comparer les sessions (tendances)…' $null $Pal.Cyan $true
        $it.Add_Click({ try { Show-Compare } catch { Log-Error "Comparaison : $_" } })
        $it = & $add 'Événements récurrents avant les fuites…' $null $Pal.Leak $false
        $it.Add_Click({ try { Show-Recurrence } catch { Log-Error "Récurrences : $_" } }) }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $it = & $add 'Ouvrir un fichier…' $null $Pal.Text $false
    $it.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.InitialDirectory = $TrackDir; $dlg.Filter = 'Sessions de tracking (session_*.csv)|session_*.csv|Incidents de fuite (incident_*.csv)|incident_*.csv|Tous les CSV (*.csv)|*.csv'; $dlg.Title = 'Analyser une session'
        if ($dlg.ShowDialog($form) -eq 'OK') { Show-Analysis $dlg.FileName } })
    $it = & $add 'Ouvrir le dossier tracking' $null $Pal.Muted $false
    $it.Add_Click({ Start-Process explorer.exe $TrackDir })
    $menu.Show($btnAna, 0, $btnAna.Height)
}

# mode de jeu (0 menu / inconnu, 1 AC, 2 PU) à chaque mesure d'une session, d'après ses Game.log copiés
# (Game_<horodatage>[_partieN].log) et le Game.log en cours si c'est la session enregistrée maintenant ; sans journal : 0
function Get-SessionModes([string]$path, [datetime]$start, [double]$h0, [double[]]$t) {
    $modes = New-Object int[] $t.Length
    $m = [regex]::Match([IO.Path]::GetFileName($path), '^(?:session|mesures)_(\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d)')
    if (-not $m.Success) { return $modes }
    $logs = @(Get-ChildItem $TrackDir -Filter "Game_$($m.Groups[1].Value)*.log" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($S.Tracking -and $S.Csv -and ([IO.Path]::GetFileName($S.Csv) -like "*$($m.Groups[1].Value)*") -and (Test-Path $GameLog)) { $logs += $GameLog }
    # instant de la 1re mesure (colonne Heure = heure locale, date = celle du nom du fichier, passage de minuit compris)
    $t0 = $start.Date.AddSeconds($h0); if (($t0 - $start).TotalHours -lt -12) { $t0 = $t0.AddDays(1) } elseif (($t0 - $start).TotalHours -gt 12) { $t0 = $t0.AddDays(-1) }
    $chg = New-Object System.Collections.Generic.List[object]
    foreach ($l in $logs) {
        try { $fs = [System.IO.File]::Open($l, 'Open', 'Read', 'ReadWrite, Delete'); try { $txt = (New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Close() } } catch { continue }
        $lastT = $null
        foreach ($x in $ModeRxTimed.Matches($txt)) {
            try { $w = [datetime]::Parse($x.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime() } catch { continue }
            $lastT = ($w - $t0).TotalSeconds; $chg.Add(@{ T = $lastT; M = (Mode-Of $x) }) }
        # fin du journal sans fermeture propre (plantage) : retour au blanc après la dernière ligne datée du fichier
        if ($l -eq $GameLog) { continue }   # journal du jeu en cours : pas fini
        $tail = [regex]::Match($txt, '(?m)^<(\d{4}-\d\d-\d\dT[\d:.]+Z)>', 'RightToLeft')
        if ($tail.Success) { try { $chg.Add(@{ T = ([datetime]::Parse($tail.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime() - $t0).TotalSeconds + 0.001; M = 0 }) } catch { } }
    }
    if (-not $chg.Count) { return $modes }
    $chg = @($chg | Sort-Object { $_.T })
    $k = -1; $cur = 0
    for ($i = 0; $i -lt $t.Length; $i++) {
        while ($k + 1 -lt $chg.Count -and $chg[$k + 1].T -le $t[$i]) { $k++; $cur = $chg[$k].M }
        $modes[$i] = $cur }
    return $modes
}
function Load-Session([string]$path) {
    $rows = @(Import-Csv -LiteralPath $path -Delimiter ';' -Encoding UTF8)
    if ($rows.Count -eq 0) { throw 'session vide' }
    $A = @{ Path = $path; HoverX = -1; Marks = (New-Object System.Collections.Generic.List[object]); Cols = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) }
    $m = [regex]::Match([IO.Path]::GetFileName($path), '(?:session|incident|mesures)_(\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d)')
    $A.Start = if ($m.Success) { [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd_HH-mm-ss', $Inv) } else { (Get-Item $path).CreationTime }
    $h0 = [TimeSpan]::Parse($rows[0].Heure).TotalSeconds
    $rel = { param($hms) $x = [TimeSpan]::Parse($hms).TotalSeconds - $h0; if ($x -lt -3600) { $x += 86400 }; [Math]::Max(0, $x) }   # passage de minuit
    # panneaux superposés (même axe du temps) ; chaque courbe appartient à un panneau
    $cCpu = RGB 251 146 60; $cGpu = RGB 96 165 250; $cSc = RGB 167 139 250
    $A.Panes = @(
        @{ Id = 'mem';  Title = 'MÉMOIRE';       Unit = 'Go';   Weight = 2.2; Fmt = '0.00' }
        @{ Id = 'rate'; Title = 'VITESSE MÉMOIRE SC'; Unit = 'Mo/s'; Weight = 1; Fmt = '0' }
        @{ Id = 'eng';  Title = 'ENGAGEMENT';    Unit = '%';    Weight = 0.8; Fmt = '0.0';  Fixed = 100 }
        @{ Id = 'phys'; Title = "RAM PHYSIQUE ET FICHIER D'ÉCHANGE"; Unit = 'Go'; Weight = 0.9; Fmt = '0.00' }
        @{ Id = 'virt'; Title = 'MÉMOIRE VIRTUELLE SC (RÉSERVÉE + ENGAGÉE)'; Unit = 'Go'; Weight = 0.7; Fmt = '#,0'; AutoMin = $true }
        @{ Id = 'flt';  Title = 'DÉFAUTS DE PAGE'; Unit = '/s'; Weight = 0.9; Fmt = '#,0' }
        @{ Id = 'load'; Title = 'CHARGE';        Unit = '%';    Weight = 1;   Fmt = '0';    Fixed = 100 }
        @{ Id = 'temp'; Title = 'TEMPÉRATURES';  Unit = '°C';   Weight = 1;   Fmt = '0';    AutoMin = $true }
        @{ Id = 'pow';  Title = 'PUISSANCE GPU'; Unit = 'W';    Weight = 0.8; Fmt = '0' }
        @{ Id = 'freq'; Title = 'FRÉQUENCES';    Unit = 'GHz';  Weight = 0.8; Fmt = '0.00'; AutoMin = $true }
        @{ Id = 'disk'; Title = 'DISQUE';        Unit = 'Mo/s'; Weight = 0.8; Fmt = '0.0' }
        @{ Id = 'trk';  Title = 'HEAD-TRACKING (MÉMOIRE PRIVÉE)'; Unit = 'Mo'; Weight = 0.6; Fmt = '0' }
    )
    $defs = @(
        @{ Pane = 'mem';  Key = 'Sys_Validee_Go';       Name = 'Système · engagée';        Col = $Pal.Cyan;       On = $true;  Fill = $true
           Tip = "Mémoire engagée (validée) totale du système : garantie en RAM ou dans le fichier d'échange. Ni la RAM utilisée, ni la mémoire virtuelle réservée." }
        @{ Pane = 'mem';  Key = 'Sys_Limite_Validee_Go'; Name = 'Limite engagement';       Col = (RGB 94 234 212); On = $false; Dash = $true
           Tip = "Limite d'engagement Windows = RAM + fichier d'échange. Elle monte si Windows agrandit le fichier d'échange." }
        @{ Pane = 'mem';  Key = 'SC_Validee_Go';        Name = 'SC · engagée (privée)';   Col = $cSc;            On = $true
           Tip = "Private Bytes : mémoire privée engagée de Star Citizen (en RAM ou dans le fichier d'échange). C'est elle qui fuit." }
        @{ Pane = 'mem';  Key = 'SC_WorkingSet_Go';     Name = 'SC · en RAM (WS)';        Col = (RGB 196 181 253); On = $false; Dash = $true
           Tip = 'Working Set : pages de SC présentes en RAM physique (privées + partagées).' }
        @{ Pane = 'mem';  Key = 'SC_PrivateWS_Go';      Name = 'SC · en RAM privée';       Col = (RGB 221 214 254); On = $false; Dash = $true
           Tip = "Private Working Set : la partie privée du Working Set (non partagée avec d'autres processus)." }
        @{ Pane = 'mem';  Key = 'Sys_RAM_Dispo_Go';     Name = 'RAM physique dispo';       Col = $Pal.Ok;         On = $true }
        @{ Pane = 'mem';  Key = 'SC_GPU_Dediee_Go';     Name = 'VRAM (SC)';                Col = $cGpu;           On = $true }
        @{ Pane = 'phys'; Key = 'Sys_RAM_Utilisee_Go';  Name = 'RAM physique utilisée';    Col = (RGB 134 239 172); On = $false }
        @{ Pane = 'phys'; Key = 'Pagefile_Go';          Name = "Échange utilisé";          Col = $Pal.Warn;       On = $false
           Tip = "Partie du fichier d'échange occupée (pages écrites sur disque)." }
        @{ Pane = 'phys'; Key = 'Pagefile_Taille_Go';   Name = "Échange (taille)";         Col = (RGB 253 224 71); On = $false; Dash = $true
           Tip = "Taille actuelle du fichier d'échange (Windows peut l'agrandir, ce qui relève la limite d'engagement)." }
        @{ Pane = 'eng';  Key = 'Sys_Validee_pct';      Name = 'Engagement (% de la limite)'; Col = $Pal.Cyan;    On = $true
           Tip = "Mémoire engagée du système en % de la limite d'engagement. À 100 %, les allocations échouent (plantage)." }
        @{ Pane = 'eng';  Key = 'Pagefile_pct';         Name = "Fichier d'échange (% utilisé)"; Col = $Pal.Warn;  On = $false; Dash = $true }
        @{ Pane = 'virt'; Key = 'SC_Virtuelle_Go';      Name = 'SC · Virtual Bytes';       Col = (RGB 148 163 184); On = $false
           Tip = "Espace d'adresses réservé + engagé (dont fichiers mappés). Une réservation ne consomme ni RAM ni engagement : plusieurs To sont normaux en 64 bits." }
        @{ Pane = 'flt';  Key = 'SC_Defauts_s';         Name = 'SC · défauts de page';     Col = $cSc;            On = $true
           Tip = "Accès à une page absente du Working Set. La plupart sont « doux » (page déjà en RAM, page neuve) : ils ne lisent pas le disque." }
        @{ Pane = 'flt';  Key = 'SC_Defauts_Durs_s';    Name = 'SC · dont lus sur disque'; Col = $Pal.Crit;       On = $true
           Tip = 'Défauts de page durs : la page a dû être lue sur le disque (fichier d''échange ou fichier mappé).' }
        @{ Pane = 'flt';  Key = 'Defauts_Page_s';       Name = 'Système · défauts de page'; Col = $Pal.Cyan;      On = $false; Dash = $true }
        @{ Pane = 'rate'; Key = 'SC_Pente15_Mo_s';      Name = 'Pente 15 s';               Col = $Pal.Leak;       On = $true }
        @{ Pane = 'rate'; Key = 'SC_Pente30_Mo_s';      Name = 'Pente 30 s';               Col = (RGB 240 171 252); On = $false; Dash = $true }
        @{ Pane = 'rate'; Key = 'SC_Vitesse_calc';      Name = 'Variation entre mesures';  Col = (RGB 148 163 184); On = $false; Dash = $true }   # calculée (anciennes sessions)
        @{ Pane = 'load'; Key = 'CPU_pct';              Name = 'CPU';                      Col = $cCpu;           On = $true }
        @{ Pane = 'load'; Key = 'SC_CPU_pct';           Name = 'Star Citizen (CPU)';       Col = $cSc;            On = $false; Dash = $true }
        @{ Pane = 'load'; Key = 'GPU_pct';              Name = 'GPU';                      Col = $cGpu;           On = $true }
        @{ Pane = 'load'; Key = 'GPU_Vent_pct';         Name = 'Ventilateur GPU';          Col = (RGB 148 163 184); On = $false; Dash = $true }
        @{ Pane = 'temp'; Key = 'CPU_Temp_C';           Name = 'CPU';                      Col = $cCpu;           On = $true }
        @{ Pane = 'temp'; Key = 'GPU_Temp_C';           Name = 'GPU';                      Col = $cGpu;           On = $true }
        @{ Pane = 'pow';  Key = 'GPU_W';                Name = 'GPU';                      Col = $cGpu;           On = $true }
        @{ Pane = 'pow';  Key = 'GPU_Puissance_pct';    Name = 'GPU (% du TDP)';           Col = $cGpu;           On = $false; Dash = $true; Unit = '% TDP' }
        @{ Pane = 'freq'; Key = 'CPU_GHz';              Name = 'CPU';                      Col = $cCpu;           On = $false }
        @{ Pane = 'freq'; Key = 'GPU_MHz';              Name = 'GPU';                      Col = $cGpu;           On = $false; Scale = 0.001 }
        @{ Pane = 'disk'; Key = 'Pagination_Mo_s';      Name = 'Pagination (lecture)';     Col = $Pal.Crit;       On = $true }
        @{ Pane = 'disk'; Key = 'Disque_Lecture_Mo_s';  Name = 'Lecture disque';           Col = $Pal.Ok;         On = $false }
        @{ Pane = 'disk'; Key = 'Disque_Ecriture_Mo_s'; Name = 'Écriture disque';          Col = (RGB 244 114 182); On = $false }
        @{ Pane = 'trk';  Key = 'AITrack_Mo';           Name = 'AITrack';                  Col = $Pal.Soft;       On = $false }
        @{ Pane = 'trk';  Key = 'opentrack_Mo';         Name = 'opentrack';                Col = (RGB 196 181 253); On = $false }
    )
    $T = New-Object System.Collections.Generic.List[double]
    $vals = @{}; foreach ($d in $defs) { $vals[$d.Key] = New-Object System.Collections.Generic.List[double] }
    $notes = @{}; $names = @{}   # clé : « libellé d'origine|hh:mm:ss » ; la dernière modification l'emporte
    foreach ($r in $rows) {
        $sec = & $rel $r.Heure
        if ($r.Minutes) {   # ligne de mesure (les lignes de note ajoutées après coup n'ont pas de minutes)
            $T.Add($sec); foreach ($d in $defs) { $vals[$d.Key].Add((Num $r.($d.Key))) } }
        if (-not $r.Repere) { continue }
        foreach ($item in ($r.Repere -split ' \| ')) {
            $item = $item.Trim(); if (-not $item) { continue }
            $n = [regex]::Match($item, '^(note|nom) (.+?) \((\d\d:\d\d:\d\d)\) : (.*)$')
            if ($n.Success) {
                $key = $n.Groups[2].Value + '|' + $n.Groups[3].Value; $val = $n.Groups[4].Value
                if ($n.Groups[1].Value -eq 'note') { $notes[$key] = $(if ($val -eq '(effacée)') { '' } else { $val }) } else { $names[$key] = $val }
                continue }
            $p = [regex]::Match($item, '^(.*) \((\d\d:\d\d:\d\d)\)$')
            $label = if ($p.Success) { $p.Groups[1].Value } else { $item }
            $clock = if ($p.Success) { $p.Groups[2].Value } else { $r.Heure }
            $kind = if ($label -match '^repère \d+$') { 'manual' } elseif ($label -match '^alerte') { 'alert' } elseif ($label -match '^Mort : (abattu|tué|percuté) par (?!PNJ)') { 'deathp' } elseif ($label -match '^Mort') { 'death' } elseif ($label -match '^Kill joueur') { 'killp' } elseif ($label -match '^(Kill :|Vaisseau détruit)') { 'kill' } elseif ($label -match '^Alt-tab') { 'focus' } elseif ($label -match '^(Fuite|Début de fuite|Fin de capture)') { 'leak' } elseif ($label -match '^Logiciel :') { 'soft' } else { 'auto' }
            $tRel = & $rel $clock
            $A.Marks.Add(@{ T = $tRel; When = $A.Start.AddSeconds($tRel); Clock = $clock; Orig = $label; Label = $label; Kind = $kind; Note = ''; Csv = $path })
        }
    }
    foreach ($mk in $A.Marks) {
        $key = $mk.Orig + '|' + $mk.Clock
        if ($notes.ContainsKey($key)) { $mk.Note = $notes[$key] }
        if ($names.ContainsKey($key) -and $names[$key]) { $mk.Label = $names[$key] } }
    $A.T = $T.ToArray(); $A.Dur = $(if ($T.Count) { $T[$T.Count - 1] } else { 60 })
    $A.Modes = Get-SessionModes $path $A.Start $h0 $A.T   # couleur de la courbe « Système · engagée » : menu / AC / PU
    # vitesse calculée entre deux mesures du CSV (Mo/s) : disponible aussi pour les sessions d'avant la détection de fuite
    $sv = $vals['SC_Validee_Go']; $dv = $vals['SC_Vitesse_calc']
    for ($i = 1; $i -lt $T.Count; $i++) {
        $dt = $T[$i] - $T[$i - 1]
        if ($dt -gt 0 -and -not [double]::IsNaN($sv[$i]) -and -not [double]::IsNaN($sv[$i - 1])) { $dv[$i] = ($sv[$i] - $sv[$i - 1]) * 1024 / $dt } }
    # % d'engagement absent (anciennes sessions) : calculé depuis la mémoire engagée et la limite
    $ep = $vals['Sys_Validee_pct']; $sl = $vals['Sys_Limite_Validee_Go']; $sg = $vals['Sys_Validee_Go']
    if (-not @($ep | Where-Object { -not [double]::IsNaN($_) }).Count) {
        for ($i = 0; $i -lt $ep.Count; $i++) { if ($sl[$i] -gt 0) { $ep[$i] = 100 * $sg[$i] / $sl[$i] } } }
    # épisodes de fuite : du repère « Fuite suspectée » (début estimé) au repère de fin suivant
    $A.LeakRuns = New-Object System.Collections.Generic.List[object]; $open = $null
    foreach ($mk in @($A.Marks | Where-Object { $_.Kind -eq 'leak' } | Sort-Object { $_.T })) {
        if ($mk.Orig -like 'Début de fuite*' -or $mk.Orig -like 'Fuite suspectée*') { if ($open -ne $null) { $A.LeakRuns.Add(@{ T0 = $open; T1 = $mk.T }) }; $open = $mk.T }
        elseif ($open -ne $null) { $A.LeakRuns.Add(@{ T0 = $open; T1 = $mk.T }); $open = $null } }
    if ($open -ne $null) { $A.LeakRuns.Add(@{ T0 = $open; T1 = $A.Dur }) }
    $A.ByKey = @{}
    $A.Series = foreach ($d in $defs) {
        $arr = $vals[$d.Key].ToArray()
        if ($d.Scale) { for ($i = 0; $i -lt $arr.Length; $i++) { $arr[$i] = $arr[$i] * $d.Scale } }
        $d.Vals = $arr
        $d.Avail = $false; foreach ($v in $arr) { if (-not [double]::IsNaN($v)) { $d.Avail = $true; break } }   # colonne absente / capteur indisponible
        if (-not $d.Avail) { $d.On = $false }
        $A.ByKey[$d.Key] = $d; $d }
    foreach ($pn in $A.Panes) { $pn.Series = @($A.Series | Where-Object { $_.Pane -eq $pn.Id }) }
    # carte non NVIDIA : pas de watts, la puissance est en % du TDP (fournie par Windows)
    if (-not $A.ByKey['GPU_W'].Avail -and $A.ByKey['GPU_Puissance_pct'].Avail) {
        $A.ByKey['GPU_Puissance_pct'].On = $true; $A.ByKey['GPU_Puissance_pct'].Dash = $false
        ($A.Panes | Where-Object { $_.Id -eq 'pow' }).Unit = '% TDP' }
    # session enregistrée avant la détection de fuite : vitesse calculée à partir de la mémoire de SC
    if (-not $A.ByKey['SC_Pente15_Mo_s'].Avail -and $A.ByKey['SC_Vitesse_calc'].Avail) {
        $A.ByKey['SC_Vitesse_calc'].On = $true; $A.ByKey['SC_Vitesse_calc'].Dash = $false }
    return $A
}

function Get-Peak($sr, [switch]$Min) {
    $best = [double]::NaN; $bi = -1
    for ($i = 0; $i -lt $sr.Vals.Count; $i++) { $v = $sr.Vals[$i]; if ([double]::IsNaN($v)) { continue }
        if ($bi -lt 0 -or ($Min -and $v -lt $best) -or (-not $Min -and $v -gt $best)) { $best = $v; $bi = $i } }
    return @{ V = $best; I = $bi }
}

# ---------------------------------------------------------------- épisodes, fin de session, contexte (communs au rapport,
# à la comparaison des sessions et à la liste des incidents : mêmes règles partout)
function Parse-Dur([string]$s) {   # « 4 min 24 s », « 1 h 05 min », « 38 s » -> secondes
    $m = [regex]::Match($s, '(?:(\d+) h)?\s*(?:(\d+) min)?\s*(?:(\d+) s)?')
    return 3600 * [int]('0' + $m.Groups[1].Value) + 60 * [int]('0' + $m.Groups[2].Value) + [int]('0' + $m.Groups[3].Value)
}
function Get-Stamp([string]$name) {   # date de début lue dans le nom du fichier (session_ / incident_ / mesures_)
    $m = [regex]::Match($name, '(\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d)'); if (-not $m.Success) { return $null }
    return [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd_HH-mm-ss', $Inv)
}
# fichier incident (mesures 1 s) qui couvre une fuite : il commence ~2 min avant le début estimé
function Find-IncidentFor([datetime]$when, [string]$self = '') {
    if ([IO.Path]::GetFileName($self) -like 'incident_*') { return $null }
    foreach ($fi in @(Get-ChildItem $TrackDir -Filter 'incident_*.csv' -ErrorAction SilentlyContinue)) {
        $t = Get-Stamp $fi.Name; if ($t -and $t -ge $when.AddSeconds(-$CapPre - 80) -and $t -le $when.AddSeconds(5)) { return $fi.FullName } }
    return $null
}
# session enregistrée qui contient un instant (début <= instant <= fin, fin lue dans la dernière ligne)
function Find-SessionFor([datetime]$when) {
    foreach ($fi in (Get-Sessions)) {
        $t = Get-Stamp $fi.Name; if (-not $t -or $t -gt $when) { continue }
        $mn = [double]::NaN
        try { $last = (Get-Content -LiteralPath $fi.FullName -Tail 5 -Encoding utf8 | ForEach-Object { ($_ -split ';')[1] } | Where-Object { $_ } | Select-Object -Last 1); $mn = Num $last } catch { }
        if ([double]::IsNaN($mn) -or $when -le $t.AddMinutes($mn + 1)) { return $fi.FullName } }
    return $null
}
function Get-RawFile([string]$path) {   # mesures brutes d'une session : mesures_<même horodatage>.csv
    $m = [regex]::Match([IO.Path]::GetFileName($path), '^session_(.+)\.csv$'); if (-not $m.Success) { return $null }
    $r = Join-Path $TrackDir "mesures_$($m.Groups[1].Value).csv"; if (Test-Path -LiteralPath $r) { return $r }; return $null
}
# contexte d'une session lu dans ses Game.log copiés (Game_<horodatage>[_partieN].log), sans rien supposer :
#   mode   : « <Join PU> » = univers persistant ; gamerules / game mode « EA_… » = Arena Commander
#   rendu  : « vkCreateDevice » = Vulkan ; création d'un appareil D3D11 sans Vulkan = DX11 ; sinon « ? »
#   vaisseau : « Local client node […] releasing control token for '<vaisseau>' » = vaisseau que le joueur pilotait
#              (écrit quand on le quitte : un vaisseau jamais quitté n'apparaît pas)
$MetaCache = @{}
function Get-SessionMeta([string]$path) {
    $live = $S.Tracking -and $path -eq $S.Csv
    if (-not $live -and $MetaCache.ContainsKey($path)) { return $MetaCache[$path] }
    $r = @{ Mode = '?'; AC = ''; Renderer = '?'; Ships = ''; Logs = 0 }
    $m = [regex]::Match([IO.Path]::GetFileName($path), '^session_(.+)\.csv$')
    $logs = @(); if ($m.Success) { $logs = @(Get-ChildItem $TrackDir -Filter "Game_$($m.Groups[1].Value)*.log" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
    if ($live -and (Test-Path $GameLog)) { $logs += $GameLog }
    $pu = $false; $ac = New-Object System.Collections.Generic.List[string]; $vk = $false; $dx = $false; $ships = New-Object System.Collections.Generic.List[string]
    foreach ($l in $logs) {
        try { $fs = [System.IO.File]::Open($l, 'Open', 'Read', 'ReadWrite, Delete'); try { $t = (New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Close() } } catch { continue }
        $r.Logs++
        if ($t.Contains('<Join PU>')) { $pu = $true }
        foreach ($x in [regex]::Matches($t, '(?:gamerules="|Requesting game mode [^/\s"]*/)(EA_\w+)')) { $v = $x.Groups[1].Value -replace '^EA_', ''; if (-not $ac.Contains($v)) { $ac.Add($v) } }
        if ($t.Contains('vkCreateDevice')) { $vk = $true }
        if ($t -match '(?i)D3D11CreateDevice|Direct3D ?11 device') { $dx = $true }
        foreach ($x in [regex]::Matches($t, "Local client node \[\d+\] releasing control token for '([A-Za-z0-9_]+?)_\d{6,}'")) { $v = Ship-Name $x.Groups[1].Value; if (-not $ships.Contains($v)) { $ships.Add($v) } }
    }
    if ($pu -and $ac.Count) { $r.Mode = 'PU + AC' } elseif ($pu) { $r.Mode = 'PU' } elseif ($ac.Count) { $r.Mode = 'AC' }
    $r.AC = ($ac -join ', '); $r.Renderer = $(if ($vk) { 'Vulkan' } elseif ($dx) { 'DX11' } else { '?' }); $r.Ships = (@($ships | Select-Object -First 4) -join ', ')
    if (-not $live) { $MetaCache[$path] = $r }
    return $r
}
# head-tracking pendant la session : mémoire d'AITrack / opentrack relevée dans le CSV, ou repère « Logiciel : … lancé »
function Get-TrackingUse($A) {
    $n = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'AITrack_Mo', 'opentrack_Mo') { $sr = $A.ByKey[$k]; if ($sr -and $sr.Avail) { $n.Add(($k -replace '_Mo$', '')) } }
    foreach ($mk in $A.Marks) { $x = [regex]::Match($mk.Orig, '^Logiciel : (.+) lancé$'); if ($x.Success -and -not $n.Contains($x.Groups[1].Value)) { $n.Add($x.Groups[1].Value) } }
    if ($n.Count) { return 'oui (' + ($n -join ', ') + ')' }
    if ($A.Cols -contains 'AITrack_Mo') { return 'non' }; return '?'
}
# épisodes de fuite d'un fichier : du repère de début (début estimé) au repère de fin suivant
function Get-LeakEpisodes($A, [bool]$live = $false) {
    $out = New-Object System.Collections.Generic.List[object]
    $starts = @($A.Marks | Where-Object { $_.Kind -eq 'leak' -and ($_.Orig -like 'Début de fuite*' -or $_.Orig -like 'Fuite suspectée*') } | Sort-Object { $_.T })
    $vk = if ($A.ByKey['SC_Pente15_Mo_s'].Avail) { 'SC_Pente15_Mo_s' } else { 'SC_Vitesse_calc' }
    $n = 0
    foreach ($s0 in $starts) {
        $n++
        $next = if ($n -lt $starts.Count) { $starts[$n].T } else { [double]::MaxValue }
        $endMk = @($A.Marks | Where-Object { $_.Kind -eq 'leak' -and $_.T -ge $s0.T -and $_.T -lt $next -and $_ -ne $s0 -and $_.Orig -notlike 'Fin de capture*' } | Sort-Object { $_.T } | Select-Object -First 1)
        $endMk = if ($endMk.Count) { $endMk[0] } else { $null }
        $t1 = if ($endMk) { $endMk.T } else { $A.Dur }
        $m = if ($endMk) { [regex]::Match($endMk.Orig, '\(\+([\d,\.]+) Go en (.+?), pic (\d+) Mo/s\)') } else { $null }
        $ok = $m -and $m.Success
        # vitesse max : courbe mesurée pendant l'épisode, ou valeurs écrites dans les repères si plus élevées
        $vmax = (Get-Stat $A $vk $s0.T $t1).Max
        $p0 = [regex]::Match($s0.Orig, '\((\d+) Mo/s\)'); if ($p0.Success -and ([double]::IsNaN($vmax) -or [double]$p0.Groups[1].Value -gt $vmax)) { $vmax = [double]$p0.Groups[1].Value }
        if ($ok -and ([double]::IsNaN($vmax) -or [double]$m.Groups[3].Value -gt $vmax)) { $vmax = [double]$m.Groups[3].Value }
        $dur = if ($ok) { $m.Groups[2].Value } else { Format-Dur ($t1 - $s0.T) }
        $sA = Get-Stat $A 'SC_Validee_Go' $s0.T ($s0.T + 3); $sB = Get-Stat $A 'SC_Validee_Go' ($t1 - 20) $t1
        $gain = if ($ok) { '+' + $m.Groups[1].Value + ' Go' } elseif ($sA.N -and $sB.N) { '+{0:0.0} Go' -f ($sB.Last - $sA.First) } else { '' }
        $ep = @{ N = $n; Start = $s0; End = $endMk; T0 = $s0.T; T1 = $t1; VMax = $vmax; Dur = $dur; DurS = $(if ($ok) { Parse-Dur $dur } else { $t1 - $s0.T }); Gain = $gain
                 IssueT = $(if ($endMk) { $endMk.T } else { $null }); Incident = (Find-IncidentFor $s0.When $A.Path) }
        if (-not $endMk) { $ep.IssueK = $(if ($live) { 'encours' } else { 'sansfin' }); $ep.IssueC = $Pal.Warn
            $ep.IssueX = $(if ($live) { '    Issue : en cours' } else { '    Issue : toujours en cours à la fin du fichier (pas de retour à la normale)' }) }
        elseif ($endMk.Orig -like 'Fuite écartée*') { $ep.IssueK = 'ecartee'; $ep.IssueC = $Pal.Muted; $ep.IssueX = '    Issue : retour à la normale à {0} — écartée, chargement probable' -f $endMk.Clock }
        elseif ($endMk.Orig -like 'Fuite : fin de hausse*') { $ep.IssueK = 'retour'; $ep.IssueC = $Pal.Ok; $ep.IssueX = '    Issue : retour à la normale à {0} (la mémoire reste au niveau atteint)' -f $endMk.Clock }
        elseif ($endMk.Orig -match '^Fuite : (jeu fermé|jeu relancé|application fermée)') { $ep.IssueK = 'ferme'; $ep.IssueC = $Pal.Crit; $ep.IssueX = '    Issue : pas de retour à la normale — {0} à {1}' -f $Matches[1], $endMk.Clock }
        else { $ep.IssueK = 'autre'; $ep.IssueC = $Pal.Text; $ep.IssueX = '    Issue : {0} ({1})' -f $endMk.Orig, $endMk.Clock }
        $out.Add($ep)
    }
    return , $out
}
# fin de session : arrêt volontaire (fermeture propre <SystemQuit> dans le Game.log), plantage probable (le jeu disparaît
# sans elle), plantage de l'appli / du PC (pas de repère « Fin du tracking » alors que le jeu tournait), arrêt manuel…
# K : volontaire, plantage, plantage_pc, manuel, appli, encours, incident, ?
function Get-SessionEnd($A, [bool]$live = $false) {
    $out = New-Object System.Collections.Generic.List[object]
    $isInc = [IO.Path]::GetFileName($A.Path) -like 'incident_*'
    $newFmt = $A.Cols -contains 'SC_Defauts_s'
    $sc = $A.ByKey['SC_Validee_Go']
    $quits = @($A.Marks | Where-Object { $_.Orig -eq 'Fermeture du jeu' })
    $gone = @($A.Marks | Where-Object { $_.Orig -eq 'Star Citizen fermé' -or $_.Orig -eq 'Fin du tracking : Star Citizen fermé' } | Sort-Object { $_.T })
    $endTrk = @($A.Marks | Where-Object { $_.Orig -like 'Fin du tracking*' } | Select-Object -Last 1)
    $closures = @($gone | Where-Object { $_.Orig -eq 'Star Citizen fermé' }); if (-not $closures.Count) { $closures = @($gone | Select-Object -First 1) }
    foreach ($g0 in $closures) {
        if (-not $g0) { continue }
        $q0 = @($quits | Where-Object { $_.T -ge $g0.T - 180 -and $_.T -le $g0.T + 10 })
        $inLeak = @($A.LeakRuns | Where-Object { $g0.T -ge $_.T0 - 5 -and $g0.T -le $_.T1 + 5 }).Count
        if ($q0.Count) { $out.Add(@{ K = 'volontaire'; C = $Pal.Ok; T = $q0[0].T; X = ('  Arrêt volontaire du jeu à {0} (fermeture propre signalée par le Game.log)' -f $q0[0].Clock) }) }
        else { $out.Add(@{ K = 'plantage'; C = $Pal.Crit; T = $g0.T; X = ('  Jeu fermé à {0} sans fermeture propre dans le Game.log : plantage ou fermeture forcée probable{1}' -f $g0.Clock, $(if ($inLeak) { ', pendant une fuite suspectée' } else { '' })) }) } }
    if (-not $out.Count) {
        $lastSc = if ($sc.Avail -and $A.T.Count) { -not [double]::IsNaN($sc.Vals[$A.T.Count - 1]) } else { $false }
        $e = if ($live) { @{ K = 'encours'; C = $Pal.Muted; X = '  Session en cours.' } }
        elseif ($endTrk.Count -and $endTrk[0].Orig -like '*arrêt manuel*') { @{ K = 'manuel'; C = $Pal.Text; T = $endTrk[0].T; X = ('  Tracking arrêté manuellement à {0}{1}.' -f $endTrk[0].Clock, $(if ($lastSc) { ', jeu encore lancé' } else { '' })) } }
        elseif ($endTrk.Count -and $endTrk[0].Orig -like '*application fermée*') { @{ K = 'appli'; C = $Pal.Text; T = $endTrk[0].T; X = ('  Application de suivi fermée à {0}{1}.' -f $endTrk[0].Clock, $(if ($lastSc) { ', jeu encore lancé' } else { '' })) } }
        elseif ($quits.Count) { @{ K = 'volontaire'; C = $Pal.Ok; T = $quits[-1].T; X = ('  Arrêt volontaire du jeu à {0} (Game.log).' -f $quits[-1].Clock) } }
        elseif ($isInc) { @{ K = 'incident'; C = $Pal.Dim; X = '  Voir la session correspondante (un incident ne couvre que la fuite).' } }
        elseif ($newFmt -and $lastSc) { @{ K = 'plantage_pc'; C = $Pal.Crit; T = $A.Dur; X = ('  Session interrompue sans fin enregistrée alors que le jeu tournait (dernière mesure {0}) : plantage de l''application ou du PC probable.' -f $A.Start.AddSeconds($A.Dur).ToString('HH:mm:ss')) } }
        else { @{ K = '?'; C = $Pal.Dim; X = '  Indéterminé (session enregistrée avant ce suivi, ou jeu non lancé).' } }
        $out.Add($e) }
    return , $out
}
# résumé d'un fichier pour la comparaison / la liste des incidents ; mis en cache (tracking\cache\*.json),
# recalculé si le CSV ou ses Game.log changent
$SumVer = 1
function Get-FileSummary($fi) {
    $live = ($S.Tracking -and $fi.FullName -eq $S.Csv) -or $fi.FullName -eq $Cap.File
    $m = [regex]::Match($fi.Name, '^session_(.+)\.csv$')
    $logSig = if ($m.Success) { (@(Get-ChildItem $TrackDir -Filter "Game_$($m.Groups[1].Value)*.log" -ErrorAction SilentlyContinue) | Measure-Object Length -Sum).Sum } else { 0 }
    $sig = '{0}|{1}|{2}|{3}' -f $SumVer, $fi.Length, $fi.LastWriteTimeUtc.Ticks, $logSig
    $cdir = Join-Path $TrackDir 'cache'; $cf = Join-Path $cdir ($fi.BaseName + '.json')
    if (-not $live -and (Test-Path -LiteralPath $cf)) { try { $c = Get-Content -LiteralPath $cf -Raw -Encoding utf8 | ConvertFrom-Json; if ($c.Sig -eq $sig) { return $c } } catch { } }
    $A = Load-Session $fi.FullName
    $nan = { param($v) if ($v -eq $null -or [double]::IsNaN([double]$v)) { $null } else { [Math]::Round([double]$v, 2) } }
    $sc = $A.ByKey['SC_Validee_Go']; $play = 0.0; $scT0 = $null
    if ($sc.Avail) { for ($i = 0; $i -lt $A.T.Count; $i++) { if (-not [double]::IsNaN($sc.Vals[$i])) { if ($scT0 -eq $null) { $scT0 = $A.T[$i] }; if ($i) { $play += $A.T[$i] - $A.T[$i - 1] } } } }
    $vk = if ($A.ByKey['SC_Pente15_Mo_s'].Avail) { 'SC_Pente15_Mo_s' } else { 'SC_Vitesse_calc' }
    $eps = Get-LeakEpisodes $A $live
    $end = Get-SessionEnd $A $live   # liste (pas @() : la liste entière deviendrait un seul élément)
    $isSes = $fi.Name -like 'session_*'
    $meta = if ($isSes) { Get-SessionMeta $fi.FullName } else { @{ Mode = ''; AC = ''; Renderer = ''; Ships = '' } }
    $trk = if ($isSes) { Get-TrackingUse $A } else { '' }
    $nk = @{}; foreach ($kk in 'kill', 'killp', 'death', 'deathp') { $nk[$kk] = @($A.Marks | Where-Object { $_.Kind -eq $kk }).Count }
    $e1 = if ($eps.Count) { $eps[0] } else { $null }
    $r = [pscustomobject]@{
        Sig = $sig; Name = $fi.Name; Path = $fi.FullName; Start = $A.Start.ToString('s'); Dur = [Math]::Round($A.Dur); Play = [Math]::Round($play); Rows = $A.T.Count
        ScMax = (& $nan (Get-Stat $A 'SC_Validee_Go').Max); SysPctMax = (& $nan (Get-Stat $A 'Sys_Validee_pct').Max)
        VMax = (& $nan (Get-Stat $A $vk).Max); VCalc = ($vk -eq 'SC_Vitesse_calc'); Detect = [bool]$A.ByKey['SC_Pente15_Mo_s'].Avail
        Leaks = $eps.Count; FirstLeakAfter = $(if ($e1 -and $scT0 -ne $null) { [Math]::Round($e1.T0 - $scT0) } else { $null })
        LeakVMax = $(if ($eps.Count) { & $nan (@($eps | ForEach-Object { $_.VMax }) | Measure-Object -Maximum).Maximum } else { $null })
        LeakDurMax = $(if ($eps.Count) { (@($eps | ForEach-Object { $_.DurS }) | Measure-Object -Maximum).Maximum } else { $null })
        Ep1Clock = $(if ($e1) { $e1.Start.Clock } else { '' }); Ep1Dur = $(if ($e1) { $e1.Dur } else { '' }); Ep1Gain = $(if ($e1) { $e1.Gain } else { '' })
        Ep1VMax = $(if ($e1) { & $nan $e1.VMax } else { $null }); Ep1Issue = $(if ($e1) { $e1.IssueK } else { '' })
        Mode = $meta.Mode; AC = $meta.AC; Renderer = $meta.Renderer; Ships = $meta.Ships; Tracking = $trk
        EndK = $(if ($end.Count) { $end[$end.Count - 1].K } else { '?' }); Crash = @($end | Where-Object { $_.K -eq 'plantage' -or $_.K -eq 'plantage_pc' }).Count
        Kills = $nk.kill + $nk.killp; Deaths = $nk.death + $nk.deathp }
    if (-not $live) { try { if (-not (Test-Path $cdir)) { New-Item -ItemType Directory -Path $cdir | Out-Null }; $r | ConvertTo-Json -Compress | Out-File -LiteralPath $cf -Encoding utf8 } catch { } }
    return $r
}
# traitement progressif d'une liste de fichiers (un par tic de minuterie : l'interface reste réactive), puis rendu
function Start-Progressive($form, $status, $files, [scriptblock]$done) {
    $st = @{ Files = @($files); I = 0; Res = (New-Object System.Collections.Generic.List[object]); F = $form; Lbl = $status; Done = $done }
    $tm = New-Object System.Windows.Forms.Timer; $tm.Interval = 15; $tm.Tag = $st
    $tm.Add_Tick({ param($sender)
        $st = $sender.Tag
        if ($st.F.IsDisposed) { $sender.Stop(); $sender.Dispose(); return }
        if ($st.I -lt $st.Files.Count) {
            $fi = $st.Files[$st.I]; $st.I++
            $st.Lbl.Text = 'Lecture {0} / {1} · {2}' -f $st.I, $st.Files.Count, $fi.Name
            try { $st.Res.Add((Get-FileSummary $fi)) } catch { Log-Error "Résumé $($fi.Name) : $_" }
            return }
        $sender.Stop(); $sender.Dispose(); $st.Lbl.Text = ''
        try { & $st.Done $st.Res } catch { Log-Error "Affichage : $_ (ligne $($_.InvocationInfo.ScriptLineNumber))" } })
    $tm.Start()
}
function New-ListForm([string]$title, [int]$w, [int]$h) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title; $f.AutoScaleMode = 'Dpi'; $f.ClientSize = New-Object System.Drawing.Size($w, $h); $f.MinimumSize = New-Object System.Drawing.Size(640, 400)
    $f.BackColor = $Pal.Bg; $f.ForeColor = $Pal.Text; $f.StartPosition = 'CenterScreen'; $f.Padding = New-Object System.Windows.Forms.Padding(16)
    try { $f.Icon = $form.Icon } catch { }
    $f.Add_HandleCreated({ param($sender) try { [SCMem]::DarkTitle($sender.Handle, (ToRef $Pal.Bg), (ToRef $Pal.CyanDim), (ToRef $Pal.Cyan)) } catch { } })
    $rt = New-RichView; $rt.Dock = 'Fill'; $rt.Cursor = 'Default'; $rt.Font = (Fnt 9.5 $false 'Consolas')
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Dock = 'Bottom'; $lbl.Height = 22; $lbl.ForeColor = $Pal.Muted; $lbl.Font = Fnt 8.5 $false $fontTech; $lbl.TextAlign = 'MiddleLeft'
    $f.Controls.Add($rt); $f.Controls.Add($lbl)
    return @{ F = $f; Rt = $rt; Lbl = $lbl }
}
function Add-Link($rt, $hits, [string]$text, $open, $color = $Pal.Cyan) {
    $hits.Add(@{ At = $rt.TextLength; End = $rt.TextLength + $text.Length; T = $null; Open = $open }); Add-Rich $rt $text $color
}
function Fit([string]$s, [int]$n) { if ($s.Length -gt $n - 1) { $s.Substring(0, $n - 2) + '… ' } else { $s.PadRight($n) } }   # colonne de n caractères, toujours un espace après

# ---- comparaison des sessions : tendances par mode de jeu, head-tracking, rendu, vaisseau
function Show-Compare {
    $W = New-ListForm 'Comparer les sessions · tendances' 1240 760
    $W.Lbl.Text = 'Lecture des sessions…'
    $W.F.Show()
    Start-Progressive $W.F $W.Lbl @(Get-Sessions | Sort-Object Name) ({ param($res) Render-Compare $W.Rt $res }.GetNewClosure())
}
function Render-Compare($rt, $res) {
    $hits = New-Object System.Collections.Generic.List[object]
    $rows = @($res | Sort-Object Start)
    $valid = @($rows | Where-Object { $_.Play -ge 60 })   # sessions où le jeu a vraiment tourné
    $det = @($valid | Where-Object { $_.Detect })          # avec la détection de fuite (seules à compter les fuites)
    Add-Rich $rt "COMPARAISON DES SESSIONS`n" $Pal.Text $true
    Add-Rich $rt ("{0} session(s) enregistrée(s), {1} avec le jeu lancé, dont {2} avec la détection de fuite.`n" -f $rows.Count, $valid.Count, $det.Count) $Pal.Muted
    Add-Rich $rt "Mode, rendu et vaisseau sont lus dans les Game.log copiés de chaque session (« ? » = pas dans les logs). Clic sur une ligne = analyse de la session.`n`n" $Pal.Dim
    # tableau
    Add-Rich $rt ('{0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}' -f (Fit 'Date' 13), (Fit 'Jeu' 12), (Fit 'Mode' 9), (Fit 'Rendu' 8), (Fit 'Tracking' 26), (Fit 'Vaisseau(x)' 24), (Fit 'SC max' 9), (Fit 'Vit.max' 9), (Fit 'Fuites' 7), (Fit '1re fuite' 13), "Fin`n") $Pal.Muted $true
    foreach ($r in $rows) {
        $t = [datetime]$r.Start
        $fu = if (-not $r.Detect) { '—' } else { "$($r.Leaks)" }
        $fin = switch ($r.EndK) { 'volontaire' { 'arrêt volontaire' } 'plantage' { 'plantage probable' } 'plantage_pc' { 'appli/PC planté ?' } 'manuel' { 'arrêt manuel' } 'appli' { 'appli fermée' } 'encours' { 'en cours' } default { '?' } }
        $line = '{0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}' -f (Fit $t.ToString('dd/MM HH:mm') 13), (Fit (Format-Long $r.Play) 12), (Fit $(if ($r.Mode) { $r.Mode } else { '?' }) 9), (Fit $r.Renderer 8), (Fit $r.Tracking 26), (Fit $(if ($r.Ships) { $r.Ships } else { '?' }) 24),
            (Fit $(if ($r.ScMax -ne $null) { '{0:0.0} Go' -f $r.ScMax } else { '—' }) 9), (Fit $(if ($r.VMax -ne $null) { '{0:0}{1}' -f $r.VMax, $(if ($r.VCalc) { '*' } else { '' }) } else { '—' }) 9),
            (Fit $fu 7), (Fit $(if ($r.FirstLeakAfter -ne $null) { Format-Long $r.FirstLeakAfter } else { '—' }) 13), $fin
        $col = if ($r.Play -lt 60) { $Pal.Dim } elseif ($r.Leaks) { $Pal.Leak } elseif ($r.Crash) { $Pal.Warn } else { $Pal.Text }
        Add-Link $rt $hits $line $r.Path $col; Add-Rich $rt "`n" $Pal.Text }
    Add-Rich $rt "* vitesse « entre deux mesures » (anciennes sessions, une mesure toutes les 15 s) : pas comparable à la pente 15 s.`n" $Pal.Dim
    # tendances par groupe
    $grp = { param([string]$title, [scriptblock]$keys)
        Add-Rich $rt "`n$title`n" $Pal.Text $true
        $by = @{}
        foreach ($r in $det) { foreach ($k in @(& $keys $r)) { if (-not $k) { $k = '?' }; if (-not $by.ContainsKey($k)) { $by[$k] = New-Object System.Collections.Generic.List[object] }; $by[$k].Add($r) } }
        if (-not $by.Count) { Add-Rich $rt "  aucune session avec la détection de fuite pour l'instant`n" $Pal.Dim; return }
        Add-Rich $rt ('  {0}{1}{2}{3}{4}{5}{6}{7}' -f (Fit '' 26), (Fit 'Sessions' 10), (Fit 'Heures' 9), (Fit 'Fuites' 8), (Fit 'Fuites/h' 10), (Fit 'Sess. avec fuite' 18), (Fit '1re fuite (méd.)' 18), "SC max moy.`n") $Pal.Muted
        foreach ($k in @($by.Keys | Sort-Object)) {
            $g = $by[$k]; $h = ($g | Measure-Object Play -Sum).Sum / 3600; $lk = ($g | Measure-Object Leaks -Sum).Sum
            $wl = @($g | Where-Object { $_.Leaks -gt 0 }).Count
            $fl = @($g | Where-Object { $_.FirstLeakAfter -ne $null } | ForEach-Object { [double]$_.FirstLeakAfter } | Sort-Object)
            $med = if ($fl.Count) { Format-Long $fl[[int][Math]::Floor(($fl.Count - 1) / 2)] } else { '—' }
            $sm = @($g | Where-Object { $_.ScMax -ne $null } | ForEach-Object { [double]$_.ScMax }); $smv = if ($sm.Count) { '{0:0.0} Go' -f (($sm | Measure-Object -Average).Average) } else { '—' }
            $few = $g.Count -lt 3
            Add-Rich $rt ('  {0}{1}{2}{3}{4}{5}{6}{7}' -f (Fit $k 26), (Fit "$($g.Count)" 10), (Fit ('{0:0.0}' -f $h) 9), (Fit "$lk" 8), (Fit $(if ($h -gt 0) { '{0:0.00}' -f ($lk / $h) } else { '—' }) 10), (Fit ('{0}/{1} ({2:0} %)' -f $wl, $g.Count, (100 * $wl / $g.Count)) 18), (Fit $med 18), $smv) $(if ($few) { $Pal.Dim } else { $Pal.Text })
            Add-Rich $rt $(if ($few) { "   (trop peu de sessions)`n" } else { "`n" }) $Pal.Dim }
    }
    & $grp 'PU / ARENA COMMANDER' { param($r) $r.Mode }
    & $grp 'AVEC / SANS HEAD-TRACKING' { param($r) if ($r.Tracking -like 'oui*') { 'avec head-tracking' } elseif ($r.Tracking -eq 'non') { 'sans head-tracking' } else { '?' } }
    & $grp 'RENDU (DX11 / VULKAN)' { param($r) $r.Renderer }
    & $grp 'VAISSEAU (sessions où il apparaît dans le Game.log)' { param($r) if ($r.Ships) { @($r.Ships -split ', ') } else { '? (non relevé)' } }
    Add-Rich $rt "`nÀ LIRE AVANT DE CONCLURE`n" $Pal.Warn $true
    Add-Rich $rt ("  · Les groupes se recoupent (ex. toutes les sessions Arena Commander jouées avec le head-tracking) : une différence entre`n" +
                  "    deux groupes peut venir d'un autre facteur. Avec moins de 3 sessions par groupe, aucune tendance n'est fiable.`n" +
                  "  · « Fuites/h » rapporte les fuites au temps de jeu ; « 1re fuite » = délai entre le lancement du jeu et le début estimé.`n" +
                  "  · Rendu : Vulkan est reconnu à « vkCreateDevice » dans le Game.log ; la signature DX11 n'a pas encore pu être vérifiée sur un vrai log.`n" +
                  "  · $ChronoNote`n") $Pal.Warn
    Add-Rich $rt "`n" $Pal.Text
    Add-Link $rt $hits '→ Événements récurrents avant les fuites (toutes sessions)' { Show-Recurrence } $Pal.Leak; Add-Rich $rt "`n" $Pal.Text
    Add-Link $rt $hits '→ Incidents détectés (mesures détaillées)' { Show-Incidents } $Pal.Leak; Add-Rich $rt "`n" $Pal.Text
    $rt.Select(0, 0)
    Set-RichLinks $rt $hits
}

# ---- incidents détectés : liste + accès direct aux mesures 1 s, à la chronologie et à la session
function Show-Incidents {
    $W = New-ListForm 'Incidents détectés' 1000 640
    $files = @(Get-ChildItem $TrackDir -Filter 'incident_*.csv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    $W.F.Show()
    if (-not $files.Count) { Add-Rich $W.Rt "INCIDENTS DÉTECTÉS`n`nAucun incident enregistré pour l'instant : un fichier incident_*.csv est créé à chaque fuite suspectée confirmée.`n" $Pal.Dim; return }
    Start-Progressive $W.F $W.Lbl $files ({ param($res) Render-Incidents $W.Rt $res }.GetNewClosure())
}
function Render-Incidents($rt, $res) {
    $hits = New-Object System.Collections.Generic.List[object]
    Add-Rich $rt "INCIDENTS DÉTECTÉS`n" $Pal.Text $true
    Add-Rich $rt ("{0} incident(s) · chaque fichier contient les 2 minutes qui précèdent le début estimé puis une mesure par seconde.`n`n" -f ($res.Count)) $Pal.Muted
    foreach ($r in @($res | Sort-Object Start -Descending)) {
        $t = [datetime]$r.Start
        $iss = switch ($r.Ep1Issue) { 'retour' { 'retour à la normale' } 'ecartee' { 'écartée (chargement probable)' } 'ferme' { 'jeu fermé pendant la fuite' } 'sansfin' { 'capture interrompue (appli ou PC arrêté ?)' } 'encours' { 'en cours' } default { '—' } }
        Add-Rich $rt ("● {0}  début de fuite {1}`n" -f $t.ToString('dd/MM/yyyy'), $(if ($r.Ep1Clock) { $r.Ep1Clock } else { '?' })) $Pal.Leak $true
        Add-Rich $rt ('   vitesse max {0} Mo/s · emballement {1} · {2} · {3} ' -f $(if ($r.Ep1VMax -ne $null) { '{0:0}' -f $r.Ep1VMax } else { '—' }), $(if ($r.Ep1Dur) { $r.Ep1Dur } else { '—' }), $(if ($r.Ep1Gain) { $r.Ep1Gain } else { '—' }), $iss) $Pal.Text
        Add-Rich $rt ("   ({0} mesures)`n   " -f $r.Rows) $Pal.Dim
        Add-Link $rt $hits '→ mesures détaillées' $r.Path; Add-Rich $rt '     ' $Pal.Text
        $chr = $r.Path -replace '\.csv$', '_chronologie.txt'
        if (Test-Path -LiteralPath $chr) { Add-Link $rt $hits '→ chronologie' $chr; Add-Rich $rt '     ' $Pal.Text }
        $ses = if ($r.Ep1Clock) { Find-SessionFor ([datetime]::Parse($t.ToString('yyyy-MM-dd') + ' ' + $r.Ep1Clock, $Inv)) } else { $null }
        if ($ses) { Add-Link $rt $hits ('→ session ' + [IO.Path]::GetFileName($ses)) $ses } else { Add-Rich $rt '(pas de session enregistrée à ce moment)' $Pal.Dim }
        Add-Rich $rt "`n`n" $Pal.Text }
    $rt.Select(0, 0)
    Set-RichLinks $rt $hits
}

# ---------------------------------------------------------------- rapport de session
# statistiques d'une courbe sur [t0, t1] ; $leak : $null = tout, $true = pendant les fuites, $false = hors fuites
function Get-Stat($A, [string]$key, [double]$t0 = -1e18, [double]$t1 = 1e18, $leak = $null) {
    $r = @{ N = 0; Mean = [double]::NaN; Max = [double]::NaN; MaxT = 0.0; Min = [double]::NaN; MinT = 0.0; First = [double]::NaN; Last = [double]::NaN }
    $sr = $A.ByKey[$key]; if (-not $sr -or -not $sr.Avail) { return $r }
    $sum = 0.0
    for ($i = 0; $i -lt $A.T.Count; $i++) {
        $t = $A.T[$i]; if ($t -lt $t0 -or $t -gt $t1) { continue }
        $v = $sr.Vals[$i]; if ([double]::IsNaN($v)) { continue }
        if ($leak -ne $null) { $in = $false; foreach ($rn in $A.LeakRuns) { if ($t -ge $rn.T0 -and $t -le $rn.T1) { $in = $true; break } }; if ($in -ne $leak) { continue } }
        $sum += $v; $r.N++; if ($r.N -eq 1) { $r.First = $v }; $r.Last = $v
        if ($r.N -eq 1 -or $v -gt $r.Max) { $r.Max = $v; $r.MaxT = $t }
        if ($r.N -eq 1 -or $v -lt $r.Min) { $r.Min = $v; $r.MinT = $t } }
    if ($r.N) { $r.Mean = $sum / $r.N }
    return $r
}
function Format-Long([double]$sec) { if ($sec -ge 3600) { '{0} h {1:00} min' -f [int][Math]::Floor($sec / 3600), [int][Math]::Floor(($sec % 3600) / 60) } else { Format-Dur $sec } }
# lignes du rapport : @{ X = texte ; C = couleur ; B = gras ; T = instant (s depuis le début, clic dans l'analyse) }
function Build-SessionReport($A) {
    $R = New-Object System.Collections.Generic.List[object]
    function Add-RLine([string]$x, $c = $Pal.Text, [bool]$b = $false, $t = $null, $open = $null) { $R.Add(@{ X = $x; C = $c; B = $b; T = $t; Open = $open }) }
    function Add-RHead([string]$x) { Add-RLine '' $Pal.Text; Add-RLine $x $Pal.Muted $true }
    $at = { param($t, $fmt = 'HH:mm') $A.Start.AddSeconds($t).ToString($fmt) }
    $isInc = [IO.Path]::GetFileName($A.Path) -like 'incident_*'
    $newFmt = $A.Cols -contains 'SC_Defauts_s'   # session enregistrée avec la version actuelle (repères de fin, défauts de page…)
    $live = ($S.Tracking -and $A.Path -eq $S.Csv) -or $A.Path -eq $Cap.File
    $starts = @($A.Marks | Where-Object { $_.Kind -eq 'leak' -and ($_.Orig -like 'Début de fuite*' -or $_.Orig -like 'Fuite suspectée*') } | Sort-Object { $_.T })

    Add-RLine $(if ($isInc) { "RAPPORT DE L'INCIDENT" } else { 'RAPPORT DE SESSION' }) $Pal.Text $true
    Add-RLine ('{0}  ·  {1} → {2}{3}' -f $A.Start.ToString('dd/MM/yyyy'), $A.Start.ToString('HH:mm'), $A.Start.AddSeconds($A.Dur).ToString('HH:mm'), $(if ($live) { '  ·  en cours' } else { '' })) $Pal.Muted
    # contexte lu dans les Game.log copiés de la session (rien d'inventé : « ? » si l'information n'y est pas)
    if (-not $isInc) {
        $meta = Get-SessionMeta $A.Path
        Add-RLine ('Mode {0}  ·  rendu {1}  ·  head-tracking {2}' -f $meta.Mode, $meta.Renderer, (Get-TrackingUse $A)) $Pal.Muted
        if ($meta.Ships) { Add-RLine ('Vaisseau(x) piloté(s) : {0}' -f $meta.Ships) $Pal.Muted } }
    $raw = Get-RawFile $A.Path
    if ($raw) { Add-RLine ('→ mesures brutes horodatées (5 s, 1 s pendant une anomalie) : {0}' -f [IO.Path]::GetFileName($raw)) $Pal.Cyan $false $null $raw }

    # durée
    Add-RHead 'DURÉE'
    Add-RLine ('  Totale : {0}' -f (Format-Long $A.Dur))
    $sc = $A.ByKey['SC_Validee_Go']
    if ($sc.Avail) { $play = 0.0; for ($i = 1; $i -lt $A.T.Count; $i++) { if (-not [double]::IsNaN($sc.Vals[$i])) { $play += $A.T[$i] - $A.T[$i - 1] } }
                     Add-RLine ('  Star Citizen lancé : {0}' -f (Format-Long $play)) }

    # mémoire
    Add-RHead 'MÉMOIRE'
    $st = Get-Stat $A 'SC_Validee_Go'
    if ($st.N) { Add-RLine ('  SC engagée (Private Bytes) : moy. {0} Go · max {1} Go à {2}' -f (Fmt-N $st.Mean '0.0'), (Fmt-N $st.Max '0.0'), (& $at $st.MaxT)) $Pal.Text $false $st.MaxT }
    $st = Get-Stat $A 'SC_WorkingSet_Go'
    if ($st.N) { Add-RLine ('  SC en RAM (Working Set) : moy. {0} Go · max {1} Go' -f (Fmt-N $st.Mean '0.0'), (Fmt-N $st.Max '0.0')) }
    $st = Get-Stat $A 'Sys_Validee_Go'
    if ($st.N) { Add-RLine ('  Système engagé : moy. {0} Go · max {1} Go à {2}' -f (Fmt-N $st.Mean '0.0'), (Fmt-N $st.Max '0.0'), (& $at $st.MaxT)) $Pal.Text $false $st.MaxT }
    $st = Get-Stat $A 'Sys_Validee_pct'
    if ($st.N) { Add-RLine ('  Engagement max : {0} % de la limite à {1}' -f (Fmt-N $st.Max '0'), (& $at $st.MaxT)) $(if ($st.Max -ge 90) { $Pal.Crit } elseif ($st.Max -ge 75) { $Pal.Warn } else { $Pal.Text }) $false $st.MaxT }
    $st = Get-Stat $A 'Sys_RAM_Dispo_Go'
    if ($st.N) { Add-RLine ('  RAM physique disponible min. : {0} Go à {1}' -f (Fmt-N $st.Min '0.0'), (& $at $st.MinT)) $Pal.Text $false $st.MinT }
    $st = Get-Stat $A 'SC_GPU_Dediee_Go'
    if ($st.N) { Add-RLine ('  VRAM SC max : {0} Go' -f (Fmt-N $st.Max '0.0')) }
    $vk = if ($A.ByKey['SC_Pente15_Mo_s'].Avail) { 'SC_Pente15_Mo_s' } else { 'SC_Vitesse_calc' }
    $st = Get-Stat $A $vk
    if ($st.N) { Add-RLine ('  Vitesse de croissance max : {0} Mo/s à {1}{2}' -f (Fmt-N $st.Max '0'), (& $at $st.MaxT), $(if ($vk -eq 'SC_Vitesse_calc') { ' (entre deux mesures)' } else { '' })) $Pal.Text $false $st.MaxT
                 Add-RLine '    (chargements compris : un pic isolé n''est pas une fuite)' $Pal.Dim }

    # anomalies
    Add-RHead 'ANOMALIES · FUITES SUSPECTÉES'
    if (-not $starts.Count -and -not $A.ByKey['SC_Pente15_Mo_s'].Avail) { Add-RLine '  Détection non disponible : session enregistrée avant la détection de fuite.' $Pal.Dim }
    elseif (-not $starts.Count) { Add-RLine '  Aucune fuite suspectée.' $Pal.Ok }
    else { Add-RLine ('  {0} fuite(s) suspectée(s)' -f $starts.Count) $Pal.Leak $true }
    foreach ($ep in (Get-LeakEpisodes $A $live)) {
        Add-RLine '' $Pal.Text
        Add-RLine ('  ● Fuite {0} — début estimé {1}' -f $ep.N, $ep.Start.Clock) $Pal.Leak $true $ep.T0
        Add-RLine ('    Vitesse max {0} Mo/s · emballement {1}{2}' -f (Fmt-N $ep.VMax '0'), $ep.Dur, $(if ($ep.Gain) { " · $($ep.Gain)" } else { '' }))
        Add-RLine $ep.IssueX $ep.IssueC $false $ep.IssueT
        if ($ep.Incident) { Add-RLine ('    → mesures détaillées (1 mesure/s) : {0}' -f [IO.Path]::GetFileName($ep.Incident)) $Pal.Cyan $false $null $ep.Incident }
        # événements précédents
        Add-RLine ('    Événements des {0} s précédentes :' -f $ChronoWin) $Pal.Muted
        $evs = Get-ChronoEvents $ep.Start.When $A.Marks; $after = $false
        if (-not @($evs | Where-Object { $_.When -le $ep.Start.When }).Count) { Add-RLine '      aucun événement relevé' $Pal.Dim }
        foreach ($ev in $evs) {
            if (-not $after -and $ev.When -gt $ep.Start.When) { $after = $true; Add-RLine '      ── début de la hausse ──' $Pal.Leak }
            Add-RLine ("      {0}`t{1}{2}" -f (Format-Rel ($ev.When - $ep.Start.When).TotalSeconds), $ev.Label, $(if ($ev.Note) { "  « $($ev.Note) »" } else { '' })) $(if ($ev.Kind -eq 'auto') { $Pal.Text } else { Mark-Color $ev.Kind }) $false $ev.T }
    }
    if ($starts.Count) { Add-RLine ''; Add-RLine "  $ChronoNote" $Pal.Warn }

    # défauts de page et pagination
    Add-RHead 'DÉFAUTS DE PAGE ET PAGINATION'
    $q = $A.Dur / 4; $any = $false
    foreach ($d in @(@('SC_Defauts_s', 'Défauts de page SC', '/s', '#,0'), @('SC_Defauts_Durs_s', 'dont lus sur disque (SC)', '/s', '#,0.#'),
                     @('Defauts_Page_s', 'Défauts de page système', '/s', '#,0'), @('Pagination_Mo_s', 'Pagination (lecture disque)', ' Mo/s', '0.0'))) {
        $st = Get-Stat $A $d[0]; if (-not $st.N) { continue }; $any = $true
        Add-RLine ('  {0} : moy. {1}{3} · max {2}{3} à {4}' -f $d[1], (Fmt-N $st.Mean $d[3]), (Fmt-N $st.Max $d[3]), $d[2], (& $at $st.MaxT)) $Pal.Text $false $st.MaxT
        $q1 = Get-Stat $A $d[0] 0 $q; $q4 = Get-Stat $A $d[0] ($A.Dur - $q) $A.Dur   # (pas $a / $b : PowerShell confondrait $a avec $A)
        $line = '    évolution : 1er quart {0} → dernier quart {1}' -f (Fmt-N $q1.Mean $d[3]), (Fmt-N $q4.Mean $d[3])
        if ($A.LeakRuns.Count) { $li = Get-Stat $A $d[0] -leak $true; $lo = Get-Stat $A $d[0] -leak $false
            $line += ' · pendant les fuites {0} / hors fuites {1}' -f (Fmt-N $li.Mean $d[3]), (Fmt-N $lo.Mean $d[3]) }
        Add-RLine $line $Pal.Muted }
    $st = Get-Stat $A 'Pagefile_Go'
    if ($st.N) { $any = $true; $sz = Get-Stat $A 'Pagefile_Taille_Go'
        Add-RLine ("  Fichier d'échange utilisé : {0} → {1} Go · max {2} Go à {3}{4}" -f (Fmt-N $st.First '0.0'), (Fmt-N $st.Last '0.0'), (Fmt-N $st.Max '0.0'), (& $at $st.MaxT), $(if ($sz.N) { ' (taille max {0} Go)' -f (Fmt-N $sz.Max '0') } else { '' })) $Pal.Text $false $st.MaxT }
    if ($any) { Add-RLine '  Les défauts de page « doux » ne touchent pas le disque ; seuls les défauts durs et la pagination le lisent.' $Pal.Dim }
    else { Add-RLine '  Non mesuré dans cette session.' $Pal.Dim }

    # fin de session : arrêt volontaire ou plantage
    Add-RHead 'FIN DE SESSION'
    foreach ($e in (Get-SessionEnd $A $live)) { Add-RLine $e.X $e.C $false $e.T }
    # combat (statistiques déjà présentes dans l'en-tête de l'analyse)
    Add-RHead 'COMBAT'
    $nk = @{}; foreach ($kk in 'kill', 'killp', 'death', 'deathp') { $nk[$kk] = @($A.Marks | Where-Object { $_.Kind -eq $kk }).Count }
    if ($nk.kill + $nk.killp + $nk.death + $nk.deathp) {
        Add-RLine ('  K/D {0}   ·   JOUEURS {1}' -f (Format-KD ($nk.kill + $nk.killp) ($nk.death + $nk.deathp)), (Format-KD $nk.killp $nk.deathp))
        Add-RLine ('  Kills : {0} PNJ, {1} joueur(s) · morts : {2} (dont {3} par un joueur)' -f $nk.kill, $nk.killp, ($nk.death + $nk.deathp), $nk.deathp) $Pal.Muted }
    else { Add-RLine '  Aucun combat relevé.' $Pal.Dim }
    return , $R
}
function Report-Text($R) {   # version fichier texte : la tabulation devient une colonne alignée
    (@($R | ForEach-Object { if ($_.X -match "^(.*?)`t(.*)$") { $Matches[1].PadRight(20) + $Matches[2] } else { $_.X } }) -join "`r`n") + "`r`n"
}
# rendu dans une zone de texte ; clic sur une ligne datée = la courbe va à cet instant ; ligne « → fichier » = l'ouvre
function Show-Report($rt, $R) {
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($l in $R) {
        if ($l.T -ne $null -or $l.Open) { $hits.Add(@{ At = $rt.TextLength; End = $rt.TextLength + $l.X.Length; T = $(if ($l.T -ne $null) { [double]$l.T } else { $null }); Open = $l.Open }) }
        Add-Rich $rt ($l.X + "`n") $l.C $l.B }
    $rt.SelectAll(); $rt.SelectionTabs = [int[]]@(110); $rt.Select(0, 0)
    return , $hits
}
# ouvre une cible de lien : CSV -> analyse, autre fichier -> application par défaut, scriptblock -> exécuté
function Open-Target($o) {
    try {
        if ($o -is [scriptblock]) { & $o }
        elseif ("$o" -like '*.csv') { [void](Show-Analysis "$o") }
        elseif (Test-Path -LiteralPath "$o") { Start-Process -FilePath "$o" }
    } catch { Log-Error "Ouverture : $_" }
}
# zones cliquables d'une zone de texte (rapport, comparaison, incidents) : main au survol, clic = Open-Target ou déplacement de la courbe
function Set-RichLinks($rt, $hits, $A = $null, $g = $null) {
    $rt.Tag = @{ Hits = $hits; A = $A; G = $g }
    $rt.Add_MouseClick({ param($sender, $e)
        $at = $sender.GetCharIndexFromPosition($e.Location); $best = $null
        foreach ($h in $sender.Tag.Hits) { if ($at -ge $h.At -and $at -le $h.End) { $best = $h; break } }
        if (-not $best) { return }
        if ($best.Open) { Open-Target $best.Open; return }
        $an = $sender.Tag.A; if (-not $an -or $best.T -eq $null) { return }
        $an.Span = 240.0; $an.V0 = $best.T - 150; Clamp-View $an; $sender.Tag.G.Invalidate() })
    $rt.Add_MouseMove({ param($sender, $e)
        $at = $sender.GetCharIndexFromPosition($e.Location); $on = $false
        foreach ($h in $sender.Tag.Hits) { if ($at -ge $h.At -and $at -le $h.End -and ($h.Open -or $sender.Tag.A)) { $on = $true; break } }
        $sender.Cursor = $(if ($on) { 'Hand' } else { 'Default' }) })
}

function Show-Analysis([string]$path) {
    try { $A = Load-Session $path } catch { [void][System.Windows.Forms.MessageBox]::Show("Impossible de lire ce fichier :`n$_", 'Analyse', 'OK', 'Warning'); return }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Analyse · ' + [IO.Path]::GetFileName($path)
    $f.AutoScaleMode = 'Dpi'; $f.ClientSize = New-Object System.Drawing.Size(1040, 760); $f.MinimumSize = New-Object System.Drawing.Size(620, 460)
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea   # pas plus grand que l'écran
    if ($f.Height -gt $wa.Height - 20) { $f.Height = $wa.Height - 20 }; if ($f.Width -gt $wa.Width - 20) { $f.Width = $wa.Width - 20 }
    $f.BackColor = $Pal.Bg; $f.ForeColor = $Pal.Text; $f.Font = Fnt 9; $f.StartPosition = 'CenterScreen'
    $f.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 16)
    try { $f.Icon = $form.Icon } catch { }
    $f.Add_HandleCreated({ param($sender) try { [SCMem]::DarkTitle($sender.Handle, (ToRef $Pal.Bg), (ToRef $Pal.CyanDim), (ToRef $Pal.Cyan)) } catch { } })

    $g = New-Object SCGraph; $g.Dock = 'Fill'; $g.BackColor = $Pal.Panel; $g.Tag = $A
    $f.Controls.Add($g)

    # rapport de la session (panneau de droite) : durée, mémoire, anomalies + événements précédents, défauts de page,
    # fin de session (arrêt / plantage), combat. Clic sur une ligne datée = la courbe va à cet instant.
    $f.ClientSize = New-Object System.Drawing.Size(([Math]::Min($wa.Width - 40, 1420)), $f.ClientSize.Height)
    $side = New-Object System.Windows.Forms.Panel; $side.Dock = 'Right'; $side.Width = 400; $side.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $rt = New-RichView; $rt.Dock = 'Fill'
    $btnRec = New-Object System.Windows.Forms.Button; $btnRec.Dock = 'Bottom'; $btnRec.Height = 30; $btnRec.Text = 'ÉVÉNEMENTS RÉCURRENTS (TOUTES SESSIONS)'
    $btnRec.FlatStyle = 'Flat'; $btnRec.FlatAppearance.BorderColor = $Pal.Leak; $btnRec.FlatAppearance.MouseOverBackColor = $Pal.CyanHover
    $btnRec.ForeColor = $Pal.Leak; $btnRec.BackColor = $Pal.Bg; $btnRec.Font = Fnt 8 $false $fontTech; $btnRec.Cursor = 'Hand'
    $btnRec.Add_Click({ try { Show-Recurrence } catch { Log-Error "Récurrences : $_" } })
    $side.Controls.Add($rt); $side.Controls.Add($btnRec)
    $hits = New-Object System.Collections.Generic.List[object]
    try { $hits = Show-Report $rt (Build-SessionReport $A) } catch { Log-Error "Rapport : $_"; Add-Rich $rt "Rapport indisponible : $_" $Pal.Warn }
    Set-RichLinks $rt $hits $A $g
    $f.Controls.Add($side)

    # cases à cocher des courbes
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Top'; $bar.AutoSize = $true; $bar.AutoSizeMode = 'GrowAndShrink'; $bar.WrapContents = $true
    $bar.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 8)
    foreach ($pn in $A.Panes) {
        # un bloc par panneau : le retour à la ligne se fait entre les groupes, pas au milieu
        $grp = New-Object System.Windows.Forms.FlowLayoutPanel; $grp.AutoSize = $true; $grp.AutoSizeMode = 'GrowAndShrink'; $grp.WrapContents = $false
        $grp.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2); $bar.Controls.Add($grp)
        $lg = New-Object System.Windows.Forms.Label; $lg.Text = $pn.Title; $lg.AutoSize = $true; $lg.Font = Fnt 7.5 $true $fontTech; $lg.ForeColor = $Pal.Dim
        $lg.Margin = New-Object System.Windows.Forms.Padding(0, 4, 6, 0); $grp.Controls.Add($lg)
        $last = $null
        foreach ($sr in $pn.Series) {
            $c = New-Object System.Windows.Forms.CheckBox; $c.Text = $sr.Name; $c.AutoSize = $true; $c.Checked = $sr.On; $c.Enabled = $sr.Avail
            $c.ForeColor = $(if ($sr.Avail) { $sr.Col } else { $Pal.Dim }); $c.Font = Fnt 9; Set-CheckLook $c
            $c.Margin = New-Object System.Windows.Forms.Padding(0, 1, 10, 2)
            if ($sr.Avail -and $sr.Tip) { $tips.SetToolTip($c, $sr.Tip) }
            if (-not $sr.Avail) { $tips.SetToolTip($c,$(if ($sr.Key -eq 'CPU_Temp_C') { "Pas de mesure : lancer MSI Afterburner avec la surveillance « CPU temperature » (Windows ne la donne pas sans droits admin)." } else { 'Pas de mesure dans cette session.' })) }
            $c.Tag = @{ S = $sr; G = $g }
            $c.Add_CheckedChanged({ param($sender) $sender.Tag.S.On = $sender.Checked; $sender.Tag.G.Invalidate() })
            $grp.Controls.Add($c); $last = $c }
        if ($last) { $last.Margin = New-Object System.Windows.Forms.Padding(0, 1, 26, 2) }   # espace entre groupes
    }
    $f.Controls.Add($bar)

    # en-tête : session + chiffres clés
    $hd = New-Object System.Windows.Forms.Panel; $hd.Dock = 'Top'; $hd.Height = 78
    $f.Controls.Add($hd)
    # chiffres clés : « valeur unité (heure) », seulement pour les mesures présentes
    $pk = { param($key, $label, $fmt, $unit, $min)
        $sr = $A.ByKey[$key]; if (-not $sr.Avail) { return $null }
        $p = if ($min) { Get-Peak $sr -Min } else { Get-Peak $sr }
        if ($p.I -lt 0) { return $null }
        '{0} {1} {2} ({3})' -f $label, $p.V.ToString($fmt), $unit, $A.Start.AddSeconds($A.T[$p.I]).ToString('HH:mm') }
    $avg = { param($key, $label, $fmt, $unit)
        $sr = $A.ByKey[$key]; if (-not $sr.Avail) { return $null }
        $sum = 0.0; $cnt = 0; foreach ($v in $sr.Vals) { if (-not [double]::IsNaN($v)) { $sum += $v; $cnt++ } }
        if ($cnt) { '{0} {1} {2}' -f $label, ($sum / $cnt).ToString($fmt), $unit } }
    $nMan = @($A.Marks | Where-Object { $_.Kind -eq 'manual' }).Count
    $l1 = @((& $pk 'Sys_Validee_Go' 'Pic engagé système' '0.0' 'Go' $false), (& $pk 'Sys_Validee_pct' 'engagement max.' '0' '%' $false), (& $pk 'SC_Validee_Go' 'pic SC (Private Bytes)' '0.0' 'Go' $false),
            (& $pk 'Sys_RAM_Dispo_Go' 'RAM dispo min.' '0.0' 'Go' $true), (& $pk 'SC_GPU_Dediee_Go' 'pic VRAM SC' '0.0' 'Go' $false),
            ('{0} repères perso, {1} événements' -f $nMan, ($A.Marks.Count - $nMan))) | Where-Object { $_ }
    $leakStarts = @($A.Marks | Where-Object { $_.Kind -eq 'leak' -and ($_.Orig -like 'Début de fuite*' -or $_.Orig -like 'Fuite suspectée*') } | Sort-Object { $_.T })
    if ($leakStarts.Count) { $l1 = @('{0} FUITE(S) SUSPECTÉE(S), 1re à {1}' -f $leakStarts.Count, $leakStarts[0].Clock) + $l1 }
    $l2 = @((& $avg 'CPU_pct' 'CPU moy.' '0' '%'), (& $pk 'CPU_Temp_C' 'pic CPU' '0' '°C' $false),
            (& $avg 'GPU_pct' 'GPU moy.' '0' '%'), (& $pk 'GPU_Temp_C' 'pic GPU' '0' '°C' $false), $(if ($A.ByKey['GPU_W'].Avail) { & $pk 'GPU_W' 'pic puissance GPU' '0' 'W' $false } else { & $pk 'GPU_Puissance_pct' 'pic puissance GPU' '0' '% TDP' $false }),
            (& $pk 'Pagination_Mo_s' 'pagination max.' '0.0' 'Mo/s' $false),
            $(if ($A.ByKey['SC_Pente15_Mo_s'].Avail) { & $pk 'SC_Pente15_Mo_s' 'pente SC max.' '0' 'Mo/s' $false } else { & $pk 'SC_Vitesse_calc' 'vitesse SC max.' '0' 'Mo/s' $false })) | Where-Object { $_ }
    [void](New-Label ('{4} DU {0}  ·  {1}  →  {2}  ·  {3:0} MIN' -f $A.Start.ToString('dd/MM/yyyy'), $A.Start.ToString('HH:mm'), $A.Start.AddSeconds($A.Dur).ToString('HH:mm'), ($A.Dur / 60), $(if ([IO.Path]::GetFileName($path) -like 'incident_*') { 'INCIDENT DE FUITE' } else { 'SESSION' })) 0 12 1200 20 (Fnt 10 $true $fontTech) $Pal.Text 'TopLeft' $hd)
    [void](New-Label ($l1 -join '   ·   ') 0 36 1200 18 (Fnt 8.5) $Pal.Muted 'TopLeft' $hd)
    [void](New-Label $(if ($l2) { $l2 -join '   ·   ' } else { 'Pas de mesures CPU / GPU / disque dans cette session (enregistrée avant leur ajout).' }) 0 54 1200 18 (Fnt 8.5) $Pal.Muted 'TopLeft' $hd)
    $nk = @{}; foreach ($kk in 'kill','killp','death','deathp') { $nk[$kk] = @($A.Marks | Where-Object { $_.Kind -eq $kk }).Count }
    if ($nk.kill + $nk.killp + $nk.death + $nk.deathp) {   # session avec du combat : ligne K/D
        $hd.Height = 96
        [void](New-Label ('K/D  {0}   ·   JOUEURS  {1}' -f (Format-KD ($nk.kill + $nk.killp) ($nk.death + $nk.deathp)), (Format-KD $nk.killp $nk.deathp)) 0 72 1200 18 (Fnt 8.5 $false $fontTech) $Pal.Text 'TopLeft' $hd) }

    $g.Add_Paint({ param($sender, $e) try { Draw-Analysis $e.Graphics $sender.Tag $sender.ClientSize.Width $sender.ClientSize.Height } catch { Log-Error "Dessin analyse : $_" } })
    $A.Graph = $g; $A.Ed = New-MarkerEditor $g 44 14 34
    $A.V0 = 0.0; $A.Span = [Math]::Max(60.0, $A.Dur); $A.Drag = $null; $A.Pan = $null; $A.Panned = $false; $A.OverThumb = $false; $A.HoverY = -1
    $g.Add_MouseMove({ param($sender, $e)
        $an = $sender.Tag; $an.HoverX = $e.X; $an.HoverY = $e.Y
        $sc = Get-ScrollRects $an
        if ($an.Drag -and $sc) {   # glisser la barre de défilement
            $room = $sc.Track.Width - $sc.Thumb.Width
            if ($room -gt 0) { $an.V0 = $an.Drag.V0 + ($e.X - $an.Drag.X0) / $room * ($sc.Full - $an.Span); Clamp-View $an } }
        if ($an.Pan -and $an.Geo) {   # clic maintenu dans la courbe + glisser : défiler
            $dx = $e.X - $an.Pan.X0; if ([Math]::Abs($dx) -gt 3) { $an.Pan.Moved = $true }
            if ($an.Pan.Moved) { $an.V0 = $an.Pan.V0 - $dx / $an.Geo.PW * $an.Span; Clamp-View $an; if ($an.Ed.Active) { Layout-Editor $an.Ed } } }
        $an.OverThumb = [bool]($sc -and $sc.Thumb.Contains([single]$e.X, [single]($sc.Thumb.Y + 3)) -and $e.Y -ge $sc.Track.Y - 6)
        $inPlot = $an.Geo -and $e.Y -le $an.Geo.PT + $an.Geo.PH
        $sender.Cursor = $(if ($an.Drag -or $an.OverThumb -or ($an.Pan -and $an.Pan.Moved)) { 'SizeWE' } elseif ($inPlot -and (Find-AnaMarks $an $e.X).Count) { 'Hand' } else { 'Default' })
        $sender.Invalidate() })
    $g.Add_MouseLeave({ param($sender) $sender.Tag.HoverX = -1; $sender.Tag.OverThumb = $false; $sender.Invalidate() })
    $g.Add_MouseEnter({ param($sender)   # prendre le focus pour recevoir la molette (sans voler celui de l'éditeur ni d'une autre fenêtre)
        if (-not $sender.Tag.Ed.Active -and [System.Windows.Forms.Form]::ActiveForm -eq $sender.FindForm()) { [void]$sender.Focus() } })
    $g.Add_MouseWheel({ param($sender, $e)
        $an = $sender.Tag
        if ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) { $an.V0 -= $e.Delta / 120.0 * $an.Span * 0.15; Clamp-View $an }   # Maj + molette : défiler
        else { Zoom-Analysis $an $e.X $e.Delta }
        if ($an.Ed.Active) { Layout-Editor $an.Ed }
        $sender.Invalidate() })
    $g.Add_MouseDown({ param($sender, $e)
        $an = $sender.Tag; $sc = Get-ScrollRects $an
        if ($e.Button -eq 'Left' -and $an.Geo -and $e.Y -le $an.Geo.PT + $an.Geo.PH) { $an.Pan = @{ X0 = $e.X; V0 = $an.V0; Moved = $false }; return }
        if (-not $sc -or $e.Button -ne 'Left' -or $e.Y -lt $sc.Track.Y - 6) { return }
        if (-not $sc.Thumb.Contains([single]$e.X, [single]($sc.Thumb.Y + 3))) {   # clic sur la piste : centrer la vue à cet endroit
            $an.V0 = ($e.X - $sc.Track.X) / $sc.Track.Width * $sc.Full - $an.Span / 2; Clamp-View $an }
        $an.Drag = @{ X0 = $e.X; V0 = $an.V0 }; $sender.Invalidate() })
    $g.Add_MouseUp({ param($sender) $an = $sender.Tag; $an.Panned = [bool]($an.Pan -and $an.Pan.Moved); $an.Pan = $null; $an.Drag = $null; $sender.Invalidate() })
    $g.Add_MouseClick({ param($sender, $e)
        $an = $sender.Tag
        if ($an.Panned) { $an.Panned = $false; return }   # fin d'un glisser : pas un clic
        if (-not $an.Geo -or $e.Y -gt $an.Geo.PT + $an.Geo.PH) { return }   # clic sous la courbe (axe, barre) : rien
        $hits = Find-AnaMarks $an $e.X
        if ($hits.Count) { Open-Editor $an.Ed (Sort-Hits $hits { param($mk) AnaMark-X $an $mk } $e.X) } else { Close-Editor $an.Ed $true } })
    $g.Add_Resize({ param($sender) if ($sender.Tag.Ed.Active) { Layout-Editor $sender.Tag.Ed } })
    $f.Tag = $A
    $f.Add_FormClosing({ param($sender) try { Close-Editor $sender.Tag.Ed $true } catch { }; [void]$S.Analyses.Remove($sender.Tag) })
    $S.Analyses.Add($A)
    $f.Show()
    return $f
}

function AnaMark-X($A, $mk) { if (-not $A.Geo) { return -1000 }; $A.Geo.PL + $A.Geo.PW * ($mk.T - $A.V0) / $A.Span }
# vue affichée : de V0 à V0 + Span secondes (zoom molette, défilement par la barre du bas)
function Clamp-View($A) {
    $full = [Math]::Max(60.0, $A.Dur)
    $A.Span = [Math]::Min($full, [Math]::Max(60.0, $A.Span))   # zoom max : 1 minute à l'écran
    $A.V0 = [Math]::Min($full - $A.Span, [Math]::Max(0.0, $A.V0))
}
function Zoom-Analysis($A, [double]$mx, [int]$delta) {
    if (-not $A.Geo) { return }
    $rx = [Math]::Min(1.0, [Math]::Max(0.0, ($mx - $A.Geo.PL) / $A.Geo.PW))
    $tc = $A.V0 + $rx * $A.Span                                  # instant sous la souris : reste sous la souris
    $A.Span = $A.Span * [Math]::Pow(1.25, -$delta / 120.0)
    Clamp-View $A; $A.V0 = $tc - $rx * $A.Span; Clamp-View $A
}
# barre de défilement (dessinée, pour rester dans le thème sombre)
function Get-ScrollRects($A) {
    $gm = $A.Geo; $full = [Math]::Max(60.0, $A.Dur)
    if (-not $gm -or $A.Span -ge $full - 0.5) { return $null }
    $track = New-Object System.Drawing.RectangleF([single]$gm.PL, [single]($gm.H - 10), [single]$gm.PW, [single]6)
    $tw = [Math]::Max(24.0, $gm.PW * $A.Span / $full)
    $tx = $gm.PL + ($gm.PW - $tw) * $A.V0 / ($full - $A.Span)
    return @{ Track = $track; Thumb = (New-Object System.Drawing.RectangleF([single]$tx, [single]($gm.H - 10), [single]$tw, [single]6)); Full = $full }
}
function Find-AnaMarks($A, [double]$mx) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $A.Geo) { return , $out }
    foreach ($mk in $A.Marks) { $x = AnaMark-X $A $mk
        if ($x -ge $A.Geo.PL - 1 -and $x -le $A.Geo.PL + $A.Geo.PW + 1 -and [Math]::Abs($x - $mx) -le 5) { $out.Add($mk) } }   # repères visibles seulement
    return , $out
}
function Nice-Step([double]$raw) {
    if ($raw -le 0 -or [double]::IsNaN($raw)) { return 1.0 }
    $p10 = [Math]::Pow(10, [Math]::Floor([Math]::Log10($raw)))
    foreach ($m in 1, 2, 2.5, 5, 10) { if ($raw -le $m * $p10 + 1e-9) { return $m * $p10 } }
    return 10 * $p10
}
# premier indice dont l'instant est >= t (dichotomie ; tableau croissant), borné au dernier indice
function Find-Index([double[]]$arr, [double]$t) {
    $k = [Array]::BinarySearch($arr, $t); if ($k -lt 0) { $k = -$k - 1 }
    return [Math]::Min([Math]::Max(0, $k), $arr.Length - 1)
}
function Pane-Y($pn, [double]$v) { $pn.Y + $pn.H * (1 - ($v - $pn.Lo) / ($pn.Hi - $pn.Lo)) }

function Draw-Analysis($gr, $A, [int]$w, [int]$hh) {
    $gr.SmoothingMode = 'AntiAlias'; $gr.TextRenderingHint = 'ClearTypeGridFit'
    $pl = 48; $pr = 14; $pt = 14; $pb = 34; $pw = $w - $pl - $pr; $ph = $hh - $pt - $pb
    if ($pw -lt 50 -or $ph -lt 30) { return }
    Clamp-View $A
    $v0 = $A.V0; $span = $A.Span; $v1 = $v0 + $span
    $A.Geo = @{ PL = $pl; PW = $pw; PT = $pt; PH = $ph; H = $hh }   # pour le clic / survol / défilement
    $toX = { param($t) $pl + $pw * ($t - $v0) / $span }
    $fnt = Fnt 7.5 $false $fontTech; $fntB = Fnt 7.5 $true $fontTech
    $brDim = Brush-Of ($Pal.Dim)
    $penGrid = Pen-Of ($Pal.Line)
    $fmtR = $FmtFar

    # mesures dans la vue (+ une de chaque côté), avec un pas si elles sont plus nombreuses que les pixels
    $n = $A.T.Count; $i0 = 0; $i1 = $n - 1
    # bornes par recherche dichotomique (les instants sont croissants) : pas de parcours de toute la session à chaque dessin
    if ($n) { $i0 = [Math]::Max(0, (Find-Index $A.T $v0) - 1); $i1 = [Math]::Min($n - 1, (Find-Index $A.T $v1) + 1) }
    $stride = [Math]::Max(1, [int][Math]::Floor(($i1 - $i0 + 1) / ($pw * 1.5)))

    # panneaux affichés (au moins une courbe cochée), hauteur selon leur poids
    $panes = @($A.Panes | Where-Object { @($_.Series | Where-Object { $_.On }).Count })
    $A.Visible = $panes
    if (-not $panes.Count) { $gr.DrawString('Aucune courbe sélectionnée.', (Fnt 10), $brDim, $pl + 10, $pt + 10); return }
    $gap = 14; $sumW = 0.0; foreach ($pn in $panes) { $sumW += $pn.Weight }
    $yy = [double]$pt; $avail = $ph - $gap * ($panes.Count - 1)
    foreach ($pn in $panes) { $pn.Y = $yy; $pn.H = $avail * $pn.Weight / $sumW; $yy += $pn.H + $gap }

    # graduations du temps (communes)
    $tickM = 60.0
    foreach ($c in 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60) { if (($span / 60) / $c -le $pw / 80) { $tickM = $c; break } }
    $off = $A.Start.Minute + $A.Start.Second / 60   # alignées sur l'horloge
    $fmt = if ($tickM -lt 1) { 'HH:mm:ss' } else { 'HH:mm' }
    $ticks = New-Object System.Collections.Generic.List[double]
    for ($mm = [Math]::Ceiling(($v0 / 60 + $off) / $tickM) * $tickM - $off; $mm * 60 -le $v1; $mm += $tickM) { $ticks.Add($mm) }

    foreach ($pn in $panes) {
        $vis = @($pn.Series | Where-Object { $_.On })
        # échelle verticale de la portion visible
        $lo = [double]::MaxValue; $hi = [double]::MinValue
        foreach ($sr in $vis) { $mm2 = [SCDraw]::MinMax($sr.Vals, $i0, $i1); if ($mm2[0] -lt $lo) { $lo = $mm2[0] }; if ($mm2[1] -gt $hi) { $hi = $mm2[1] } }
        if ($hi -lt $lo) { $lo = 0.0; $hi = 1.0 }
        if ($pn.Fixed) { $lo = 0.0; $hi = [double]$pn.Fixed }
        else {
            if ($pn.Id -eq 'mem' -and $pn.Series[0].On) { $hi = [Math]::Max($hi, 10) }
            if ($pn.Id -eq 'rate') { $hi = [Math]::Max($hi, $S.FuiteSeuil * 1.15) }   # seuil de fuite toujours visible
            if (-not $pn.AutoMin) { $lo = 0.0 } else { $lo = $lo - ($hi - $lo) * 0.1 }
            $hi = $hi + ($hi - $lo) * 0.08; if ($hi - $lo -lt 1e-6) { $hi = $lo + 1 } }
        $lines = [Math]::Max(1, [Math]::Floor($pn.H / 28))
        $step = Nice-Step (($hi - $lo) / $lines)
        $pn.Lo = [Math]::Floor($lo / $step) * $step; $pn.Hi = [Math]::Ceiling($hi / $step - 1e-9) * $step
        if ($pn.Hi -le $pn.Lo) { $pn.Hi = $pn.Lo + $step }
        if ($pn.AutoMin -and $pn.Lo -lt 0) { $pn.Lo = 0.0 }
        # grille, axe, titre
        $lf = if ($step -lt 1) { '0.0#' } else { '0' }
        for ($v = $pn.Lo; $v -le $pn.Hi + $step * 0.01; $v += $step) {
            $y = Pane-Y $pn $v; $gr.DrawLine($penGrid, $pl, $y, $w - $pr, $y)
            $gr.DrawString($v.ToString($lf), $fnt, $brDim, (New-Object System.Drawing.RectangleF(0, ($y - 7), ($pl - 5), 14)), $fmtR) }
        foreach ($mm in $ticks) { $x = & $toX ($mm * 60); $gr.DrawLine($penGrid, $x, $pn.Y, $x, $pn.Y + $pn.H) }
        $title = "$($pn.Title) · $($pn.Unit)"; $tsz = [System.Windows.Forms.TextRenderer]::MeasureText($title, $fntB)   # TextRenderer : accents des majuscules
        $gr.FillRectangle((Brush-Of ([System.Drawing.Color]::FromArgb(200, $Pal.Panel))), [single]($pl + 4), [single]($pn.Y + 1), [single]($tsz.Width + 2), [single]$tsz.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($gr, $title, $fntB, (New-Object System.Drawing.Point([int]($pl + 4), [int]($pn.Y + 1))), $Pal.Muted)
        # seuils d'alerte (mémoire validée système)
        if ($pn.Id -eq 'mem' -and $pn.Series[0].On) {
            foreach ($th in @(@{ v = $S.Avert; col = $Pal.Warn }, @{ v = $S.Seuil; col = $Pal.Crit })) {
                if ($th.v -gt $pn.Hi) { continue }
                $pen = Pen-Of ([System.Drawing.Color]::FromArgb(150, $th.col)) 1 $true
                $y = Pane-Y $pn $th.v; $gr.DrawLine($pen, $pl, $y, $w - $pr, $y) } }
        # seuil de fuite (réglage actuel)
        if ($pn.Id -eq 'rate' -and $S.FuiteSeuil -le $pn.Hi) {
            $pen = Pen-Of ([System.Drawing.Color]::FromArgb(150, $Pal.Leak)) 1 $true
            $y = Pane-Y $pn $S.FuiteSeuil; $gr.DrawLine($pen, $pl, $y, $w - $pr, $y) }
        # courbes (coupées là où la valeur manque, ex. jeu fermé), limitées au panneau
        $gr.SetClip((New-Object System.Drawing.RectangleF([single]$pl, [single]($pn.Y - 1), [single]$pw, [single]($pn.H + 2))))
        foreach ($sr in $vis) {
            # « Système · engagée » (la courbe du suivi en direct) : blanc = menu, rouge = Arena Commander, bleu = PU
            $byMode = $sr.Key -eq 'Sys_Validee_Go'
            $segs = [SCDraw]::SegsMode($A.T, $sr.Vals, $(if ($byMode) { $A.Modes } else { $null }), $i0, $i1, $stride, $pl, $pw, $v0, $span, $pn.Y, $pn.H, $pn.Lo, $pn.Hi)
            foreach ($kv in $segs) {
                $sg = $kv.Value; $col = if ($byMode) { Mode-Color $kv.Key } else { $sr.Col }
                if ($sg.Length -lt 2) { $gr.FillEllipse((Brush-Of ($col)), $sg[0].X - 2, $sg[0].Y - 2, 4, 4); continue }
                if ($sr.Fill) {
                    $base = [single]($pn.Y + $pn.H)
                    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush([System.Drawing.PointF]::new(0, [single]$pn.Y), [System.Drawing.PointF]::new(0, $base),
                        [System.Drawing.Color]::FromArgb(55, $col), [System.Drawing.Color]::FromArgb(0, $col))
                    $gr.FillPolygon($grad, [SCDraw]::Area($sg, $base)); $grad.Dispose() }
                $gr.DrawLines((Pen-Of ($col) 1.6 ([bool]$sr.Dash)), $sg) } }
        $gr.ResetClip()
    }
    $last = $panes[$panes.Count - 1]; $plotBot = $last.Y + $last.H
    # heures sous le dernier panneau
    foreach ($mm in $ticks) {
        $x = & $toX ($mm * 60); $lab = $A.Start.AddMinutes($mm).ToString($fmt); $sz = $gr.MeasureString($lab, $fnt)
        $gr.DrawString($lab, $fnt, $brDim, $x - $sz.Width / 2, $plotBot + 6) }
    # barre de défilement quand on est zoomé
    $sc = Get-ScrollRects $A
    if ($sc) {
        $gr.FillRectangle((Brush-Of ($Pal.Field)), $sc.Track)
        $gr.FillRectangle((Brush-Of ($(if ($A.Drag -or $A.OverThumb) { $Pal.Cyan } else { $Pal.CyanDim }))), $sc.Thumb)
        $zl = 'zoom ×{0:0.#}' -f ($sc.Full / $span); $sz = $gr.MeasureString($zl, $fnt)
        $gr.DrawString($zl, $fnt, $brDim, $w - $pr - $sz.Width, 0) }

    # repères : sur toute la hauteur
    $gr.SetClip((New-Object System.Drawing.RectangleF([single]$pl, [single]0, [single]$pw, [single]($plotBot + 1))))
    # épisodes de fuite suspectée : bande fuchsia sur tous les panneaux
    $brLeak = Brush-Of ([System.Drawing.Color]::FromArgb(30, $Pal.Leak))
        foreach ($rn in $A.LeakRuns) {   # hachures : les 2 minutes avant le début estimé (fenêtre des événements corrélés)
        $p0 = $rn.T0 - $ChronoWin; if ($rn.T0 -lt $v0 -or $p0 -gt $v1) { continue }
        $x0 = [single](& $toX $p0); $x1 = [single](& $toX $rn.T0)
        foreach ($pn in $panes) { $gr.FillRectangle($brPre, $x0, [single]$pn.Y, [single][Math]::Max(1, $x1 - $x0), [single]$pn.H) } }
    foreach ($rn in $A.LeakRuns) {
        if ($rn.T1 -lt $v0 -or $rn.T0 -gt $v1) { continue }
        $x0 = [single](& $toX $rn.T0); $x1 = [single](& $toX $rn.T1)
        foreach ($pn in $panes) { $gr.FillRectangle($brLeak, $x0, [single]$pn.Y, [single][Math]::Max(1, $x1 - $x0), [single]$pn.H) } }
    $hover = $A.HoverX -ge $pl -and $A.HoverX -le $w - $pr
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($mk in $A.Marks) {
        if ($mk.T -lt $v0 - 1 -or $mk.T -gt $v1 + 1) { continue }
        $x = [single](& $toX $mk.T)
        $col = Mark-Color $mk.Kind
        $alpha = if ($mk.Kind -eq 'auto') { 70 } else { 180 }   # (pas $a : PowerShell confondrait avec $A)
        $near = $hover -and [Math]::Abs($x - $A.HoverX) -le 5; if ($near) { $hits.Add($mk) }
        if ($near -or $mk -eq $A.Ed.Active) { $alpha = 255; if ($mk.Kind -eq 'auto') { $col = $Pal.Text } }
        $pen = Pen-Of ([System.Drawing.Color]::FromArgb($alpha, $col)) 1
        foreach ($pn in $panes) { $gr.DrawLine($pen, $x, [single]$pn.Y, $x, [single]($pn.Y + $pn.H)) }
        $low = $mk.Kind -eq 'focus'   # alt-tab : flèche en bas, point de note en haut
        $tip = if ($low) { @([single]$plotBot, [single]($plotBot - 6)) } else { @([single]$pt, [single]($pt + 6)) }
        $gr.FillPolygon((Brush-Of ([System.Drawing.Color]::FromArgb([Math]::Min(255, $alpha + 40), $col))),
            [System.Drawing.PointF[]]@([System.Drawing.PointF]::new(($x - 3.5), $tip[0]), [System.Drawing.PointF]::new(($x + 3.5), $tip[0]), [System.Drawing.PointF]::new($x, $tip[1])))
        if ($mk.Note) { $gr.FillEllipse((Brush-Of ($col)), $x - 3, $(if ($low) { [single]($pt + 1) } else { [single]($plotBot - 7) }), 6, 6) }
    }
    $gr.ResetClip()

    if (-not $hover -or $n -eq 0 -or $A.Ed.Active -or $A.Drag -or ($A.Pan -and $A.Pan.Moved) -or $A.HoverY -gt $plotBot) { return }
    # survol : ligne verticale + valeurs de la mesure la plus proche, panneau par panneau, + repères proches
    $tm = $v0 + ($A.HoverX - $pl) / $pw * $span
    $bi = Find-Index $A.T $tm   # mesure la plus proche de la souris
    if ($bi -gt 0 -and [Math]::Abs($A.T[$bi - 1] - $tm) -lt [Math]::Abs($A.T[$bi] - $tm)) { $bi-- }
    $xi = [single](& $toX $A.T[$bi])
    $penX = Pen-Of ([System.Drawing.Color]::FromArgb(140, $Pal.Text)) 1
    foreach ($pn in $panes) { $gr.DrawLine($penX, $xi, [single]$pn.Y, $xi, [single]($pn.Y + $pn.H)) }
    $fB = Fnt 8 $true $fontTech; $fT = Fnt 8 $false $fontTech; $fN = (Fnt 8.5 $false $fontUI ([System.Drawing.FontStyle]::Italic))
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add(@{ T = ('{0}  ·  +{1:0.0} min' -f $A.Start.AddSeconds($A.T[$bi]).ToString('HH:mm:ss'), ($A.T[$bi] / 60)); F = $fB; C = $Pal.Text })
    foreach ($pn in $panes) {
        $first = $true
        foreach ($sr in @($pn.Series | Where-Object { $_.On })) {
            $v = $sr.Vals[$bi]; if ([double]::IsNaN($v)) { continue }
            $gr.FillEllipse((Brush-Of ($sr.Col)), $xi - 3.5, [single](Pane-Y $pn $v) - 3.5, 7, 7)
            if ($first) { $rows.Add(@{ T = $pn.Title; F = $fntB; C = $Pal.Dim; Gap = $true }); $first = $false }
            $rows.Add(@{ T = $sr.Name; R = ('{0} {1}' -f $v.ToString($pn.Fmt), $(if ($sr.Unit) { $sr.Unit } else { $pn.Unit })); F = $fT; C = $sr.Col }) } }
    $shown = 0
    foreach ($mk in $hits) {
        if ($shown -ge 6) { $rows.Add(@{ T = "+ $($hits.Count - 6) autre(s)"; F = $fT; C = $Pal.Dim }); break }
        $shown++
        $c = Mark-Color $mk.Kind
        $lab = $mk.Label.Substring(0, 1).ToUpper() + $mk.Label.Substring(1)
        $rows.Add(@{ T = "$($mk.Clock)  $lab"; F = $(if ($mk.Kind -eq 'auto' -and $mk.Label -ceq $mk.Orig) { $fT } else { $fB }); C = $c; Gap = ($shown -eq 1) })
        if ($mk.Label -cne $mk.Orig) { $rows.Add(@{ T = "à l'origine : $($mk.Orig)"; F = $fT; C = $Pal.Dim }) }
        if ($mk.Note) { $rows.Add(@{ T = "« $($mk.Note) »"; F = $fN; C = $Pal.Text }) } }
    $maxW = 300; $tw = [single]0; $th2 = [single]0
    foreach ($r in $rows) {
        $sz = $gr.MeasureString($r.T, $r.F, $maxW); $r.H = $sz.Height + $(if ($r.Gap) { 5 } else { 0 }); $th2 += $r.H
        $rw = $sz.Width; if ($r.R) { $r.RW = $gr.MeasureString($r.R, $fB).Width; $rw += 24 + $r.RW }
        if ($rw -gt $tw) { $tw = $rw } }
    $bw = $tw + 16; $bh = $th2 + 12
    $bx = [single]($A.HoverX + 14); if ($bx + $bw -gt $w - 2) { $bx = [single]($A.HoverX - 14 - $bw) }; if ($bx -lt 2) { $bx = [single]2 }
    $by = [single]($A.HoverY - $bh / 2); $by = [single][Math]::Max(2, [Math]::Min($by, $hh - 2 - $bh))   # suit la souris verticalement
    $gr.FillRectangle((Brush-Of ([System.Drawing.Color]::FromArgb(242, $Pal.Bg))), $bx, $by, $bw, $bh)
    $gr.DrawRectangle((Pen-Of ($Pal.CyanDim)), $bx, $by, $bw, $bh)
    $yy = $by + 6
    foreach ($r in $rows) {
        $o = if ($r.Gap) { 5 } else { 0 }
        $gr.DrawString($r.T, $r.F, (Brush-Of ($r.C)), (New-Object System.Drawing.RectangleF(($bx + 8), ($yy + $o), $maxW, ($r.H - $o))))
        if ($r.R) { $gr.DrawString($r.R, $fB, (Brush-Of ($Pal.Text)), [single]($bx + $bw - 8 - $r.RW), [single]($yy + $o)) }
        $yy += $r.H }
}

# ---------------------------------------------------------------- événements
$numSeuil.Add_ValueChanged({ $S.Seuil = [double]$numSeuil.Value; $S.AlertLevel = 0; Save-Settings; $graph.Invalidate() })
$numAvert.Add_ValueChanged({ $S.Avert = [double]$numAvert.Value; Save-Settings; $graph.Invalidate() })
$numFuite.Add_ValueChanged({ $S.FuiteSeuil = [double]$numFuite.Value; Save-Settings; foreach ($an in $S.Analyses) { $an.Graph.Invalidate() } })
$numFuiteDur.Add_ValueChanged({ $S.FuiteDuree = [int]$numFuiteDur.Value; Save-Settings })
$numCap.Add_ValueChanged({ $S.CapInterval = [int]$numCap.Value; Save-Settings; Update-CapLabel })
$numFin.Add_ValueChanged({ $S.FinCalme = [int]$numFin.Value; Save-Settings })
$numInt.Add_ValueChanged({ $S.Interval = [int]$numInt.Value; Save-Settings })
$chkSon.Add_CheckedChanged({ $S.Son = $chkSon.Checked; Save-Settings })
$chkTop.Add_CheckedChanged({ if ($S.TopMost -ne $chkTop.Checked) { Set-Pin $chkTop.Checked; Save-Settings } })
$chkAuto.Add_CheckedChanged({ $S.AutoTrack = $chkAuto.Checked; Save-Settings })
$btnTrack.Add_Click({
    try {
        if ($S.Tracking) {
            # arrêt manuel : pas de redémarrage automatique pour cette partie
            $sc = @(Get-Process -Name 'StarCitizen' -ErrorAction SilentlyContinue); if ($sc.Count) { $S.NoAutoPid = $sc[0].Id }
            Write-Row; Stop-Tracking
        } else { Start-Tracking }
    } catch { Log-Error "Tracking : $_"; $lblStatus.Text = "Erreur : $_" } })
$btnTest.Add_Click({ $chime.Play(); $S.Flash = 6; $flashTimer.Start() })
$btnMark.Add_Click({ $n = $S.MarkerCount; Add-ManualMarker; if ($S.MarkerCount -gt $n) { Open-Editor $S.Ed @($S.LastAdded) -Note } })   # bouton : saisie de note directe (pas avec Ctrl+Alt+R en jeu)
$btnAna.Add_Click({ try { Show-AnalysisMenu } catch { Log-Error "Menu analyse : $_" } })

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 2000
$timer.Add_Tick({ try { Tick } catch { Log-Error "Tick : $_" } })
# capture autour des anomalies : minuterie à la seconde (Cap-Tick décide de mesurer ou non)
$capTimer = New-Object System.Windows.Forms.Timer; $capTimer.Interval = 1000
$capTimer.Add_Tick({ try { Cap-Tick } catch { Log-Error "Capture : $_" } })
# clignotement pour « Tester l'alerte »
$flashTimer = New-Object System.Windows.Forms.Timer; $flashTimer.Interval = 220
$flashTimer.Add_Tick({
    if ($S.Flash -le 0) { $flashTimer.Stop(); try { Tick } catch { }; return }
    $S.Flash--
    $accent.BackColor = $(if ($S.Flash % 2) { $Pal.Crit } else { $Pal.Bg }); $lblBig.ForeColor = $(if ($S.Flash % 2) { $Pal.Crit } else { $Pal.Dim })
    $lblState.Text = '●  TEST ALERTE'; $lblState.ForeColor = $Pal.Crit })
# raccourci Ctrl+Alt+R (hook clavier bas niveau, voir SCKeyHook)
$hookOk = $false
try { $hookOk = [SCKeyHook]::Start() } catch { Log-Error "Raccourci : $_" }
if (-not $hookOk) { $lblKey.Text = 'Ctrl+Alt+R / D indisponibles'; $lblKey.ForeColor = $Pal.Warn
    $tips.SetToolTip($lblKey, "Impossible d'installer le raccourci clavier global.") }
# Ctrl+Alt+D : fenêtre rendue invisible (opacité 0 : transparente aux clics) plutôt que cachée — cacher la fenêtre
# principale terminerait ShowDialog. Réduite dans la barre des tâches : réaffichée sans prendre le focus au jeu.
function Toggle-Display {
    if ($form.WindowState -eq 'Minimized') { [SCMem]::ShowNoActivate($form.Handle); $form.Opacity = 1.0 }
    elseif ($form.Opacity -lt 1) { $form.Opacity = 1.0 }
    elseif ([SCMem]::ForegroundPid() -eq $PID) { $form.WindowState = 'Minimized' }   # l'outil a le focus : réduit (un clic dans la barre des tâches le rend)
    else { try { Close-Editor $S.Ed $true } catch { }; $form.Opacity = 0.0 }
}
$form.Add_Activated({ if ($form.Opacity -lt 1) { $form.Opacity = 1.0 } })   # masquée puis cliquée dans la barre des tâches : réaffichée
$form.Add_Resize({ if ($form.WindowState -eq 'Minimized' -and $form.Opacity -lt 1) { $form.Opacity = 1.0 } })   # masquée puis réduite : réapparaît à la restauration
$tips.SetToolTip($lblKey, "Raccourcis globaux, actifs même en jeu :`nCtrl+Alt+R : poser un repère`nCtrl+Alt+D : masquer / réafficher cette fenêtre")
$hkTimer = New-Object System.Windows.Forms.Timer; $hkTimer.Interval = 250   # raccourci + alt-tab (stabilité 0,5 s de toute façon)
$hkTimer.Add_Tick({
    if ([SCKeyHook]::Count -gt $S.HotSeen) { $S.HotSeen = [SCKeyHook]::Count; try { Add-ManualMarker } catch { Log-Error "Repère : $_" } }
    if ([SCKeyHook]::CountD -gt $S.HotSeenD) { $S.HotSeenD = [SCKeyHook]::CountD; try { Toggle-Display } catch { Log-Error "Afficher / masquer : $_" } }
    if ($form.Opacity -lt 1 -and [SCMem]::ForegroundPid() -eq $PID) { $form.Opacity = 1.0 }   # masquée mais reprise au premier plan (barre des tâches, alt-tab) : réaffichée
    try { Watch-Focus } catch { Log-Error "Alt-tab : $_" } })
# alt-tab : le jeu perd / reprend le premier plan (état stable 0,5 s pour ignorer les clignotements)
$S.ScPid = 0; $S.InGame = $null; $S.FgCand = $null; $S.FgSince = Get-Date; $S.FocusOutAt = $null
function Watch-Focus {
    if (-not $S.ScPid) { $S.InGame = $null; $S.FgCand = $null; return }
    $in = [SCMem]::ForegroundPid() -eq $S.ScPid
    if ($in -ne $S.FgCand) { $S.FgCand = $in; $S.FgSince = Get-Date; return }
    if ($in -eq $S.InGame -or ((Get-Date) - $S.FgSince).TotalMilliseconds -lt 500) { return }
    $first = $S.InGame -eq $null; $S.InGame = $in
    if ($first) { return }   # état initial : pas un alt-tab
    if (-not $in) {
        $S.FocusOutAt = $S.FgSince
        # programme qui a pris le premier plan (changement de focus)
        $to = ''; try { $fp = [SCMem]::ForegroundPid(); if ($fp) { $to = [SCProcInfo]::NameOf($fp); if (-not $to) { $to = (Get-Process -Id $fp -ErrorAction Stop).ProcessName } } } catch { }
        Add-Event $(if ($to) { "Alt-tab : sortie du jeu (vers $to)" } else { 'Alt-tab : sortie du jeu' }) 'focus' $S.FgSince }
    else {
        $lab = 'Alt-tab : retour en jeu'
        if ($S.FocusOutAt) { $d = $S.FgSince - $S.FocusOutAt; $lab += $(if ($d.TotalMinutes -ge 1) { ' (absent {0} min {1:00} s)' -f [int][Math]::Floor($d.TotalMinutes), $d.Seconds } else { ' (absent {0} s)' -f [int]$d.TotalSeconds }) }
        Add-Event $lab 'focus' $S.FgSince }
}

$form.Add_Shown({
    Update-KD
    # taille du mode complet : mÃ©morisÃ©e (en coordonnÃ©es de conception) ou largeur d'origine + courbe par dÃ©faut
    $S.K = $head.Width / 480.0   # facteur DPI : l'en-tÃªte mesure 480 en coordonnÃ©es de conception Ã  ce stade
    try {
        $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        $cw = if ($S.W) { [Math]::Min($wa.Width, [Math]::Max((D $NarrowMin), (D $S.W))) } else { $form.ClientSize.Width }
        $ch = if ($S.H) { [Math]::Min($wa.Height, (D $S.H)) } else { $form.ClientSize.Height }
        # (pas de mise en page pendant le setter : WinForms y réécrit sa taille cliente en cache à la fin)
        $S.InLayout = $true; try { $form.ClientSize = New-Object System.Drawing.Size($cw, $ch) } finally { $S.InLayout = $false }
        if ($S.H) { Layout-Full } else { Layout-Full $GraphDef }
    } catch { Log-Error "Mise en page initiale : $_" }
    if ($S.Compact) { $S.Compact = $false; Set-Compact $true }
    Set-Pin ([bool]$S.TopMost)
    Init-GameLog
    try { Tick } catch { Log-Error "Premier affichage : $_" }; $timer.Start(); $hkTimer.Start()
    try { Cap-Tick } catch { Log-Error "Capture : $_" }; $capTimer.Start()
    if ($TestTrack) { Start-Tracking '(test)' }
    if ($TestSeconds -gt 0) {
        $script:tt = New-Object System.Windows.Forms.Timer; $script:tt.Interval = $TestSeconds * 1000
        $script:tt.Add_Tick({ $script:tt.Stop()
            if ($Snapshot) { $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height); $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height))); $bmp.Save($Snapshot) }
            $form.Close() })
        $script:tt.Start() } })
$form.Add_FormClosing({
    $timer.Stop(); $hkTimer.Stop(); $capTimer.Stop()
    try { Close-Incident 'application fermée' } catch { Log-Error "Capture incident : $_" }
    try { Close-Editor $S.Ed $true } catch { }
    foreach ($an in $S.Analyses.ToArray()) { try { Close-Editor $an.Ed $true } catch { } }   # (pas @($S.Analyses) : bloque sous PowerShell 5.1)
    if ($S.Tracking) { try { Write-Row } catch { }; Stop-Tracking ' (application fermée)' }
    try { [SCKeyHook]::Stop() } catch { }
    Save-Settings })

try { [void]$form.ShowDialog() } catch { Log-Error "Fenêtre : $_" }
