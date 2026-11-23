// Mesures système : mémoire de Star Citizen, mémoire du système, CPU, GPU, et détection de fuite.
//
// Mêmes sources que l'outil PowerShell (memoire/), appelées depuis Node avec koffi :
//  - NtQuerySystemInformation(SystemProcessInformation) : mémoire privée de StarCitizen.exe,
//    sans ouvrir de handle sur le processus (compatible anti-triche) ;
//  - K32GetPerformanceInfo : mémoire engagée du système / limite, RAM disponible ;
//  - GetSystemTimes : charge CPU ;
//  - nvml.dll (installée avec le pilote NVIDIA) : charge, température et VRAM du GPU.
//
// Une mesure par seconde, uniquement quand un écran est connecté. Historique borné à 120 s.
import koffi from 'koffi'
import type { Flat } from './flat.ts'

// ---- Réglages (repris de memoire/app/reglages.json) ----------------------------------
const LEAK_RATE = 100 // Mo/s : pente 15 s au-delà de laquelle la mémoire de SC « fuit »
// Durée exigée au-dessus du seuil. L'outil PowerShell utilise 15 s + 30 s pendant les chargements
// (détectés dans le Game.log). Sans le Game.log ici, on exige directement 45 s :
// un chargement (150 à 300 Mo/s pendant 15 à 45 s) ne déclenche pas d'alerte.
const LEAK_DURATION = 45 // s
const CALM_AFTER = 60 // s de calme (pente 30 s < seuil / 3) pour clore un épisode
const STARTUP = 180 // s : pas de détection pendant le chargement initial du jeu
const SAMPLE_MS = 1000
const SC_EXE = 'starcitizen.exe'

// ---- Appels natifs ------------------------------------------------------------------
const kernel32 = koffi.load('kernel32.dll')
const ntdll = koffi.load('ntdll.dll')

const PERF_INFO = koffi.struct('PERFORMANCE_INFORMATION', {
  cb: 'uint32', CommitTotal: 'size_t', CommitLimit: 'size_t', CommitPeak: 'size_t',
  PhysicalTotal: 'size_t', PhysicalAvailable: 'size_t', SystemCache: 'size_t',
  KernelTotal: 'size_t', KernelPaged: 'size_t', KernelNonpaged: 'size_t', PageSize: 'size_t',
  HandleCount: 'uint32', ProcessCount: 'uint32', ThreadCount: 'uint32',
})
const getPerformanceInfo = kernel32.func('bool __stdcall K32GetPerformanceInfo(_Out_ PERFORMANCE_INFORMATION *p, uint32 cb)')
const FILETIME = koffi.struct('FILETIME', { lo: 'uint32', hi: 'uint32' })
const getSystemTimes = kernel32.func('bool __stdcall GetSystemTimes(_Out_ FILETIME *idle, _Out_ FILETIME *kernel, _Out_ FILETIME *user)')
const ntQuery = ntdll.func('int __stdcall NtQuerySystemInformation(int cls, _Out_ uint8_t *buf, uint32 len, _Out_ uint32 *ret)')

// GPU NVIDIA : facultatif (autre marque ou pas de pilote → pas de valeurs GPU)
interface Nvml {
  util(): { gpu: number } | null
  temp(): number | null
  mem(): { used: number; total: number } | null
}
function loadNvml(): Nvml | null {
  try {
    const lib = koffi.load('nvml.dll')
    const UTIL = koffi.struct('nvmlUtilization_t', { gpu: 'uint32', memory: 'uint32' })
    const MEM = koffi.struct('nvmlMemory_t', { total: 'uint64', free: 'uint64', used: 'uint64' })
    void UTIL
    void MEM
    const init = lib.func('int nvmlInit_v2()')
    const getHandle = lib.func('int nvmlDeviceGetHandleByIndex_v2(uint32 i, _Out_ void **h)')
    const getUtil = lib.func('int nvmlDeviceGetUtilizationRates(void *h, _Out_ nvmlUtilization_t *u)')
    const getTemp = lib.func('int nvmlDeviceGetTemperature(void *h, int sensor, _Out_ uint32 *t)')
    const getMem = lib.func('int nvmlDeviceGetMemoryInfo(void *h, _Out_ nvmlMemory_t *m)')
    const h: unknown[] = [null]
    if (init() !== 0 || getHandle(0, h) !== 0) return null
    const dev = h[0]
    return {
      util: () => { const u = { gpu: 0 }; return getUtil(dev, u) === 0 ? u : null },
      temp: () => { const t = [0]; return getTemp(dev, 0, t) === 0 ? t[0] : null },
      mem: () => {
        const m = { used: 0, total: 0 }
        return getMem(dev, m) === 0 ? { used: Number(m.used), total: Number(m.total) } : null
      },
    }
  } catch {
    return null
  }
}

// Mémoire privée (octets) et date de création de StarCitizen.exe, ou null s'il ne tourne pas.
// Offsets de SYSTEM_PROCESS_INFORMATION en 64 bits (les mêmes que l'outil PowerShell).
let procBuf = Buffer.alloc(1 << 20)
function readStarCitizen(): { privateBytes: number; created: number } | null {
  const ret = [0]
  for (;;) {
    const st = ntQuery(5, procBuf, procBuf.length, ret)
    if (st === -1073741820) { procBuf = Buffer.alloc(ret[0] + (1 << 16)); continue } // STATUS_INFO_LENGTH_MISMATCH
    if (st !== 0) return null
    break
  }
  const base = BigInt(koffi.address(procBuf))
  let off = 0
  let found: { privateBytes: number; created: number } | null = null
  for (;;) {
    const nameLen = procBuf.readUInt16LE(off + 0x38)
    const ptr = procBuf.readBigUInt64LE(off + 0x40)
    if (ptr && nameLen === SC_EXE.length * 2) {
      const at = Number(ptr - base)
      if (at >= 0 && at + nameLen <= procBuf.length && procBuf.toString('utf16le', at, at + nameLen).toLowerCase() === SC_EXE) {
        const priv = Number(procBuf.readBigInt64LE(off + 0xc8))
        const created = Number(procBuf.readBigInt64LE(off + 0x20)) // FILETIME (100 ns depuis 1601)
        found = found ? { privateBytes: found.privateBytes + priv, created: Math.min(found.created, created) } : { privateBytes: priv, created }
      }
    }
    const next = procBuf.readUInt32LE(off)
    if (!next) break
    off += next
  }
  return found
}
const fileTimeToMs = (ft: number) => ft / 1e4 - 11644473600000

// ---- Pente (Mo/s) par régression linéaire sur les `win` dernières secondes ----------
interface Pt { t: number; mb: number }
function slope(buf: Pt[], win: number): number | null {
  const n = buf.length
  if (n < 3) return null
  const tEnd = buf[n - 1].t
  const y0 = buf[n - 1].mb
  let k = 0, sx = 0, sy = 0, sxx = 0, sxy = 0, tFirst = tEnd
  for (let i = n - 1; i >= 0; i--) {
    const x = buf[i].t - tEnd
    if (-x > win + 0.5) break
    const y = buf[i].mb - y0
    sx += x; sy += y; sxx += x * x; sxy += x * y; k++; tFirst = buf[i].t
  }
  if (k < 3 || tEnd - tFirst < win * 0.6) return null // fenêtre trop peu remplie
  const den = k * sxx - sx * sx
  return den > 1e-9 ? (k * sxy - sx * sy) / den : null
}

// ---- Moniteur -----------------------------------------------------------------------
export type LeakState = 'startup' | 'stable' | 'rising' | 'leak' | 'recovering'

export function createSystemMonitor() {
  const nvml = loadNvml()
  let timer: NodeJS.Timeout | null = null
  let out: Flat = {}

  // état entre deux mesures
  let prevCpu: number[] | null = null
  const hist: Pt[] = [] // mémoire de SC, 120 s max
  let hotSince: number | null = null
  let leak: { onsetMb: number; calmSince: number | null } | null = null
  let scCreated = 0

  function cpuPct(): number | null {
    const i = { lo: 0, hi: 0 }, k = { lo: 0, hi: 0 }, u = { lo: 0, hi: 0 }
    if (!getSystemTimes(i, k, u)) return null
    const v = (f: { lo: number; hi: number }) => f.hi * 2 ** 32 + f.lo
    const cur = [v(i), v(k), v(u)]
    const prev = prevCpu
    prevCpu = cur
    if (!prev) return null
    const total = cur[1] - prev[1] + (cur[2] - prev[2]) // le temps noyau inclut le temps d'inactivité
    return total > 0 ? (1 - (cur[0] - prev[0]) / total) * 100 : null
  }

  function sample(): void {
    const f: Flat = {}
    const now = Date.now() / 1000

    const p = { cb: 0, CommitTotal: 0, CommitLimit: 0, PhysicalTotal: 0, PhysicalAvailable: 0, PageSize: 0 }
    if (getPerformanceInfo(p, koffi.sizeof(PERF_INFO))) {
      const page = Number(p.PageSize)
      const gb = (pages: number | bigint) => (Number(pages) * page) / 2 ** 30
      f['sys.commit_gb'] = gb(p.CommitTotal)
      f['sys.commit_limit_gb'] = gb(p.CommitLimit)
      f['sys.commit_pct'] = (Number(p.CommitTotal) / Number(p.CommitLimit)) * 100
      f['sys.ram_avail_gb'] = gb(p.PhysicalAvailable)
      f['sys.ram_total_gb'] = gb(p.PhysicalTotal)
    }
    const cpu = cpuPct()
    if (cpu !== null) f['sys.cpu_pct'] = cpu
    if (nvml) {
      const u = nvml.util()
      const t = nvml.temp()
      const m = nvml.mem()
      if (u) f['sys.gpu_pct'] = u.gpu
      if (t !== null) f['sys.gpu_temp'] = t
      if (m) { f['sys.vram_used_gb'] = m.used / 2 ** 30; f['sys.vram_total_gb'] = m.total / 2 ** 30 }
    }

    // ---- Star Citizen + détection de fuite (logique de l'outil PowerShell) ----
    const sc = readStarCitizen()
    if (!sc) {
      hist.length = 0; hotSince = null; leak = null; scCreated = 0
    } else {
      if (sc.created !== scCreated) { hist.length = 0; hotSince = null; leak = null; scCreated = sc.created } // jeu (re)lancé
      const mb = sc.privateBytes / 2 ** 20
      hist.push({ t: now, mb })
      while (hist.length && now - hist[0].t > 120) hist.shift()

      const s15 = slope(hist, 15)
      const s30 = slope(hist, 30)
      const startup = Date.now() - fileTimeToMs(sc.created) < STARTUP * 1000
      const hot = s15 !== null && s15 >= LEAK_RATE
      hotSince = hot && !startup ? (hotSince ?? now) : null

      if (leak) {
        const calm = s30 !== null && s30 < LEAK_RATE / 3
        if (!calm) leak.calmSince = null
        else if (leak.calmSince === null) leak.calmSince = now
        else if (now - leak.calmSince >= CALM_AFTER) leak = null // fin de l'épisode
      } else if (hotSince !== null && now - hotSince >= LEAK_DURATION) {
        leak = { onsetMb: hist.find((h) => h.t >= hotSince!)?.mb ?? mb, calmSince: null }
      }

      const state: LeakState = leak ? (leak.calmSince !== null ? 'recovering' : 'leak') : startup ? 'startup' : hotSince !== null ? 'rising' : 'stable'
      const fiveAgo = [...hist].reverse().find((h) => now - h.t >= 5)
      f['sc.private_mb'] = mb
      f['sc.delta5_mb'] = fiveAgo ? mb - fiveAgo.mb : 0
      if (s15 !== null) f['sc.slope15'] = s15
      if (s30 !== null) f['sc.slope30'] = s30
      f['sc.leak'] = state
      if (leak) f['sc.leak_growth_mb'] = mb - leak.onsetMb
    }
    out = f
  }

  return {
    gpu: nvml !== null,
    start() {
      if (timer) return
      sample()
      timer = setInterval(sample, SAMPLE_MS)
    },
    stop() {
      if (timer) clearInterval(timer)
      timer = null
      out = {}
      prevCpu = null
    },
    flat: (): Flat => out,
  }
}
