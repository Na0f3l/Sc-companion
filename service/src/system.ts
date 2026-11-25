// Mesures système : mémoire de Star Citizen, mémoire du système, CPU, GPU, et détection de fuite.
//
// Mêmes sources que l'outil PowerShell (memoire/), appelées depuis Node avec koffi :
//  - NtQuerySystemInformation(SystemProcessInformation) : mémoire privée de StarCitizen.exe,
//    sans ouvrir de handle sur le processus (compatible anti-triche) ;
//  - K32GetPerformanceInfo : mémoire engagée du système / limite, RAM disponible ;
//  - GetSystemTimes : charge CPU ;
//  - compteurs de performance Windows (pdh.dll) : charge GPU et VRAM utilisée.
//
// Une mesure toutes les 2 s, uniquement quand un écran est connecté. Historique borné à 120 s.
import koffi from 'koffi'
import { flatten, type Flat } from './flat.ts'
import { config } from './config.ts'

// ---- Réglages (repris de memoire/app/reglages.json) ----------------------------------
// Seuil et durée de la fuite : réglables depuis les écrans (config.ts ; par défaut 100 Mo/s pendant 45 s).
// Pente 15 s au-delà du seuil pendant toute la durée = fuite. L'outil PowerShell utilise 15 s + 30 s pendant
// les chargements (détectés dans le Game.log) ; ici on exige directement 45 s par défaut :
// un chargement (150 à 300 Mo/s pendant 15 à 45 s) ne déclenche pas d'alerte.
const CALM_AFTER = 60 // s de calme (pente 30 s < seuil / 3) pour clore un épisode
const STARTUP = 180 // s : pas de détection pendant le chargement initial du jeu
const LONG_POINTS = 3600 // historique long : 2 h à une mesure toutes les 2 s
const SAMPLE_MS = 2000 // comme l'outil PowerShell : assez pour la pente 15 s et la variation sur 5 s
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

// GPU via les compteurs de performance Windows (PDH), toutes marques de carte.
// Choisi plutôt que nvml.dll (pilote NVIDIA) : ~11 Mo au lieu de ~20 Mo, 0,5 ms par mesure.
// Pas de température par cette voie.
//   \GPU Engine(*)\Utilization Percentage : charge par moteur et par processus → somme des moteurs « 3D »
//   \GPU Adapter Memory(*)\Dedicated Usage : VRAM utilisée (octets) par carte
interface Gpu {
  sample(): { util: number; vramBytes: number } | null
  close(): void // ferme la requête et décharge pdh.dll (~23 Mo rendus)
}
function loadGpu(): Gpu | null {
  try {
    const pdh = koffi.load('pdh.dll')
    const open = pdh.func('uint32 __stdcall PdhOpenQueryW(void *src, uintptr_t user, _Out_ void **q)')
    const close = pdh.func('uint32 __stdcall PdhCloseQuery(void *q)')
    const add = pdh.func('uint32 __stdcall PdhAddEnglishCounterW(void *q, str16 path, uintptr_t user, _Out_ void **c)')
    const collect = pdh.func('uint32 __stdcall PdhCollectQueryData(void *q)')
    const getArray = pdh.func('uint32 __stdcall PdhGetFormattedCounterArrayW(void *c, uint32 fmt, _Inout_ uint32 *size, _Out_ uint32 *count, void *items)')
    const q: unknown[] = [null]
    const engine: unknown[] = [null]
    const vram: unknown[] = [null]
    if (open(null, 0, q) !== 0) return null
    if (add(q[0], '\\GPU Engine(*)\\Utilization Percentage', 0, engine) !== 0) return null
    add(q[0], '\\GPU Adapter Memory(*)\\Dedicated Usage', 0, vram) // facultatif
    collect(q[0]) // la charge se calcule entre deux collectes : la première sert de référence

    let buf = Buffer.alloc(64 * 1024) // réutilisé d'une mesure à l'autre
    const PDH_FMT_DOUBLE = 0x200
    const ITEM = 24 // PDH_FMT_COUNTERVALUE_ITEM_W : pointeur du nom (8) + statut (4) + remplissage (4) + double (8)

    // Parcourt les instances d'un compteur : appelle fn(nom, valeur)
    function each(counter: unknown, fn: (name: string, value: number) => void): boolean {
      const size = [buf.length]
      const count = [0]
      let st = getArray(counter, PDH_FMT_DOUBLE, size, count, buf)
      if (st === 0x800007d2 /* PDH_MORE_DATA */) {
        buf = Buffer.alloc(size[0] + 4096)
        size[0] = buf.length
        st = getArray(counter, PDH_FMT_DOUBLE, size, count, buf)
      }
      if (st !== 0) return false
      const base = BigInt(koffi.address(buf))
      for (let i = 0; i < count[0]; i++) {
        const at = Number(buf.readBigUInt64LE(i * ITEM) - base)
        let end = at
        while (end + 1 < buf.length && (buf[end] || buf[end + 1])) end += 2
        fn(buf.toString('utf16le', at, end), buf.readDoubleLE(i * ITEM + 16))
      }
      return true
    }

    return {
      sample() {
        if (collect(q[0]) !== 0) return null
        // charge 3D par carte (instance « …_luid_0x…_0x…_phys_0_eng_… »), puis la carte la plus chargée : sur un PC
        // à deux GPU (portable Intel + NVIDIA / AMD), additionner les deux fausserait la charge
        const perCard = new Map<string, number>()
        const ok = each(engine[0], (name, v) => {
          if (!name.endsWith('engtype_3D')) return
          const card = name.match(/luid_0x[0-9a-f]+_0x[0-9a-f]+/i)?.[0] ?? ''
          perCard.set(card, (perCard.get(card) ?? 0) + v)
        })
        if (!ok) return null
        const util = Math.max(0, ...perCard.values())
        let vramBytes = 0
        if (vram[0]) each(vram[0], (_, v) => { vramBytes = Math.max(vramBytes, v) })
        return { util: Math.min(100, util), vramBytes }
      },
      close() {
        try {
          close(q[0])
        } catch {
          /* déjà fermée */
        }
        pdh.unload()
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

/** Une mesure (toutes les 2 s) : temps en s, mémoire de SC en Mo (null = jeu fermé), engagement système en %. */
export interface Sample {
  t: number
  scMb: number | null
  scStartedAt: number | null // ms : lancement du processus StarCitizen.exe
  commitPct: number | null
  leak: LeakState | null
}

export function createSystemMonitor(onSample?: (s: Sample) => void) {
  // Mesure GPU : seulement quand un écran l'affiche (setGpu, index.ts) ; les compteurs de performance Windows
  // coûtent ~23 Mo, inutiles pour enregistrer une session sans écran
  let gpu: Gpu | null = null
  let timer: NodeJS.Timeout | null = null
  let out: Flat = {}

  // état entre deux mesures
  let prevCpu: number[] | null = null
  const hist: Pt[] = [] // mémoire de SC, 120 s max
  // Historique long pour la courbe zoomable de l'interface (GET /history) : 2 h à une mesure / 2 s = 3 600 points
  // au plus (~60 Ko). Temps en s, mémoire en Mo arrondie. Pas de mesure = jeu fermé (trou dans la courbe).
  const longT: number[] = []
  const longMb: number[] = []
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
    const g = gpu?.sample()
    if (g) {
      f['sys.gpu_pct'] = g.util
      if (g.vramBytes) f['sys.vram_used_gb'] = g.vramBytes / 2 ** 30
    }

    // ---- Star Citizen + détection de fuite (logique de l'outil PowerShell) ----
    const sc = readStarCitizen()
    if (!sc) {
      hist.length = 0; hotSince = null; leak = null; scCreated = 0
    } else {
      if (sc.created !== scCreated) { hist.length = 0; hotSince = null; leak = null; scCreated = sc.created } // jeu (re)lancé
      const mb = sc.privateBytes / 2 ** 20
      hist.push({ t: now, mb })
      longT.push(Math.round(now))
      longMb.push(Math.round(mb))
      if (longT.length > LONG_POINTS + 300) { longT.splice(0, 300); longMb.splice(0, 300) } // par paquets : pas de décalage à chaque mesure
      while (hist.length && now - hist[0].t > 120) hist.shift()

      const s15 = slope(hist, 15)
      const s30 = slope(hist, 30)
      const startup = Date.now() - fileTimeToMs(sc.created) < STARTUP * 1000
      const hot = s15 !== null && s15 >= config.leakRate
      hotSince = hot && !startup ? (hotSince ?? now) : null

      if (leak) {
        const calm = s30 !== null && s30 < config.leakRate / 3
        if (!calm) leak.calmSince = null
        else if (leak.calmSince === null) leak.calmSince = now
        else if (now - leak.calmSince >= CALM_AFTER) leak = null // fin de l'épisode
      } else if (hotSince !== null && now - hotSince >= config.leakDuration) {
        leak = { onsetMb: hist.find((h) => h.t >= hotSince!)?.mb ?? mb, calmSince: null }
      }

      const state: LeakState = leak ? (leak.calmSince !== null ? 'recovering' : 'leak') : startup ? 'startup' : hotSince !== null ? 'rising' : 'stable'
      // relevé d'il y a au moins 5 s (parcours depuis la fin, sans copier le tableau)
      let fiveAgo: Pt | undefined
      for (let i = hist.length - 1; i >= 0; i--) if (now - hist[i].t >= 5) { fiveAgo = hist[i]; break }
      f['sc.private_mb'] = mb
      f['sc.delta5_mb'] = fiveAgo ? mb - fiveAgo.mb : 0
      if (s15 !== null) f['sc.slope15'] = s15
      if (s30 !== null) f['sc.slope30'] = s30
      f['sc.leak'] = state
      if (leak) f['sc.leak_growth_mb'] = mb - leak.onsetMb
    }
    out = flatten(f) // arrondi une fois par mesure (et non à chaque envoi)
    onSample?.({
      t: now,
      scMb: typeof f['sc.private_mb'] === 'number' ? f['sc.private_mb'] : null,
      scStartedAt: sc ? fileTimeToMs(sc.created) : null,
      commitPct: typeof f['sys.commit_pct'] === 'number' ? f['sys.commit_pct'] : null,
      leak: typeof f['sc.leak'] === 'string' ? (f['sc.leak'] as LeakState) : null,
    })
  }

  return {
    /** Mesure GPU allumée (un écran est connecté) ou éteinte (mémoire rendue). */
    setGpu(on: boolean): void {
      if (on && !gpu) gpu = loadGpu()
      else if (!on && gpu) {
        gpu.close()
        gpu = null
      }
    },
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
    /** Mémoire de SC sur les 2 dernières heures : { t: [s…], mb: [Mo…] } */
    history: () => ({ t: longT.slice(-LONG_POINTS), mb: longMb.slice(-LONG_POINTS) }),
  }
}
