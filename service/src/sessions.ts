// Sessions de jeu : mémoire et événements enregistrés d'un lancement de Star Citizen à sa fermeture,
// pour les revoir ensuite (panneau Sessions de l'interface).
//
// Une session commence au lancement du jeu (heure du processus) et se termine 30 s après sa fermeture : un
// Alt-F4 suivi d'une relance immédiate (crash, fuite) reste la même session. Si le service redémarre pendant
// la partie, il reprend la session en cours.
//
// Un fichier par session, <dossier des données>/sessions/<début>.jsonl (paths.ts), écrit au fil de
// l'eau (par paquets toutes les 10 s) : rien n'est perdu si le service s'arrête. Une ligne par donnée :
//   {"v":1,"start":ms}                en-tête
//   [t s, Mo du jeu, % engagement]    une mesure (toutes les 2 s)
//   {"e":[ms, niveau, texte]}         un événement (mort, kill, contrat…, voir gamelog.ts)
//   {"uec":[ms, solde]}               le solde aUEC quand il change (télémétrie : argent gagné / dépensé)
//   {"end":ms}                        fin de session
// ~50 Ko par heure de jeu. Les 5 dernières sessions sont gardées ; une session sauvegardée (dossier saved/)
// est gardée indéfiniment et ne compte pas dans les 5.
import fs from 'node:fs'
import path from 'node:path'
import type { LogEvent } from './gamelog.ts'
import type { Sample } from './system.ts'
import { DATA_DIR } from './paths.ts'

const DIR = process.env.SCC_SESSIONS_DIR ?? path.join(DATA_DIR, 'sessions') // (autre dossier : tests)
const SAVED = path.join(DIR, 'saved')
const GRACE_S = 30 // jeu fermé depuis plus longtemps : session terminée
const KEEP = 5 // sessions non sauvegardées gardées
const FLUSH_MS = 10_000
const ID_RX = /^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d$/
const LEAK_LABEL = 'RAM leak detected' // épisode de fuite, noté comme un événement

export interface SessionSummary {
  id: string
  saved: boolean
  live: boolean
  closingIn?: number // s : session en cours, jeu fermé → fin dans ce délai (sauf relance du jeu)
  start: number // ms
  end: number // ms (dernière mesure pour une session en cours)
  peakMb: number
  peakPct: number
  counts: Record<string, number> // événements par niveau (death, kill, success, failure…)
  leaks: number
  // argent : solde au début et à la fin, total gagné et total dépensé (null : solde jamais reçu)
  money: { start: number; end: number; earned: number; spent: number } | null
}

export interface SessionData extends SessionSummary {
  t: number[] // s
  mb: (number | null)[]
  pct: (number | null)[]
  events: LogEvent[]
  uec: [number, number][] // [ms, solde]
}

const pad = (n: number) => String(n).padStart(2, '0')
function idOf(ms: number): string {
  const d = new Date(ms)
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}_${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`
}

function fileOf(id: string): string | null {
  if (!ID_RX.test(id)) return null
  for (const dir of [DIR, SAVED]) {
    const f = path.join(dir, `${id}.jsonl`)
    if (fs.existsSync(f)) return f
  }
  return null
}

// ---- Lecture d'un fichier ----------------------------------------------------------------------
function parse(file: string): SessionData {
  const id = path.basename(file, '.jsonl')
  const out: SessionData = {
    id, saved: path.dirname(file) === SAVED, live: false, start: 0, end: 0, peakMb: 0, peakPct: 0,
    counts: {}, leaks: 0, money: null, t: [], mb: [], pct: [], events: [], uec: [],
  }
  let ended = 0
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line) continue
    let d: unknown
    try {
      d = JSON.parse(line)
    } catch {
      continue // ligne coupée (arrêt brutal pendant une écriture)
    }
    if (Array.isArray(d)) {
      const [t, mb, pct] = d as [number, number | null, number | null]
      out.t.push(t); out.mb.push(mb); out.pct.push(pct)
      if (mb !== null && mb > out.peakMb) out.peakMb = mb
      if (pct !== null && pct > out.peakPct) out.peakPct = pct
    } else if (d && typeof d === 'object') {
      const o = d as { start?: number; e?: LogEvent; end?: number; uec?: [number, number] }
      if (o.uec) {
        const [, v] = o.uec
        const prev = out.uec[out.uec.length - 1]?.[1]
        out.uec.push(o.uec)
        if (!out.money) out.money = { start: v, end: v, earned: 0, spent: 0 }
        else if (prev !== undefined) {
          if (v > prev) out.money.earned += v - prev
          else out.money.spent += prev - v
          out.money.end = v
        }
      }
      if (o.start) out.start = o.start
      if (o.e) {
        out.events.push(o.e)
        out.counts[o.e[1]] = (out.counts[o.e[1]] ?? 0) + 1
        if (o.e[2] === LEAK_LABEL) out.leaks++
      }
      if (o.end) ended = o.end
    }
  }
  out.end = ended || (out.t.length ? out.t[out.t.length - 1]! * 1000 : out.start)
  return out
}
const hasEnd = (file: string) => fs.readFileSync(file, 'utf8').includes('{"end":')

// résumés en cache (fichier → date de modification) : la liste ne relit pas tout à chaque fois
const cache = new Map<string, { mtime: number; summary: SessionSummary }>()
function summary(file: string): SessionSummary {
  const mtime = fs.statSync(file).mtimeMs
  const hit = cache.get(file)
  if (hit && hit.mtime === mtime) return hit.summary
  const { t: _t, mb: _mb, pct: _p, events: _e, uec: _u, ...s } = parse(file)
  cache.set(file, { mtime, summary: s })
  return s
}

// ---- Enregistreur -------------------------------------------------------------------------------
export function createSessionRecorder() {
  fs.mkdirSync(SAVED, { recursive: true })

  let cur: { id: string; file: string; start: number; seen: Set<string> } | null = null
  let lastSeen = 0 // s : dernière mesure avec le jeu lancé
  let gameOff = false // dernière mesure : jeu fermé (session en délai de grâce)
  // délai avant la fin de la session en cours si le jeu est fermé (s, arrondi), sinon rien
  const closing = (file: string) =>
    cur?.file === file && gameOff ? { closingIn: Math.max(0, Math.ceil(lastSeen + GRACE_S - Date.now() / 1000)) } : {}
  let lastLeak: string | null = null
  let buf: string[] = []
  let timer: NodeJS.Timeout | null = null
  let booted = false
  let lastUec: number | null = null // dernier solde connu (écrit au début de chaque session)

  function flush(): void {
    if (!cur || !buf.length) return
    try {
      fs.appendFileSync(cur.file, buf.join('\n') + '\n')
    } catch (e) {
      console.error('Session write failed:', (e as Error).message)
    }
    buf = []
  }

  function open(at: number): void {
    const startMs = Math.round(at)
    const id = idOf(startMs)
    const file = path.join(DIR, `${id}.jsonl`)
    cur = { id, file, start: startMs, seen: new Set() }
    if (!fs.existsSync(file)) fs.writeFileSync(file, JSON.stringify({ v: 1, start: startMs }) + '\n')
    if (lastUec !== null) buf.push(JSON.stringify({ uec: [Date.now(), lastUec] })) // solde de départ
    timer = setInterval(flush, FLUSH_MS)
    console.log(`Session ${id} started`)
  }

  // reprise d'une session interrompue (service redémarré pendant la partie)
  function resume(file: string, data: SessionData): void {
    cur = { id: data.id, file, start: data.start, seen: new Set(data.events.map((e) => `${e[0]}|${e[2]}`)) }
    timer = setInterval(flush, FLUSH_MS)
    console.log(`Session ${data.id} resumed`)
  }

  function close(endMs: number): void {
    if (!cur) return
    buf.push(JSON.stringify({ end: endMs }))
    flush()
    if (timer) clearInterval(timer)
    timer = null
    console.log(`Session ${cur.id} ended`)
    cur = null
    lastLeak = null
    rotate()
  }

  // au plus KEEP sessions non sauvegardées (les plus anciennes partent)
  function rotate(): void {
    const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.jsonl')).sort()
    for (const f of files.slice(0, Math.max(0, files.length - KEEP))) {
      if (cur && f === `${cur.id}.jsonl`) continue
      fs.rmSync(path.join(DIR, f), { force: true })
      cache.delete(path.join(DIR, f))
    }
  }

  // Premier passage : sessions restées ouvertes (service arrêté pendant une partie) → reprise ou clôture
  function boot(s: Sample): void {
    booted = true
    const open = [...fs.readdirSync(DIR).map((f) => path.join(DIR, f)), ...fs.readdirSync(SAVED).map((f) => path.join(SAVED, f))]
      .filter((f) => f.endsWith('.jsonl') && !hasEnd(f))
      .sort((a, b) => path.basename(a).localeCompare(path.basename(b)))
    for (const file of open) {
      const data = parse(file)
      const lastT = data.t.length ? data.t[data.t.length - 1]! : data.start / 1000
      const isLatest = file === open[open.length - 1]
      // même partie : le jeu tournait déjà à la dernière mesure, ou a été relancé dans le délai de grâce
      if (isLatest && s.scMb !== null && s.scStartedAt !== null && s.scStartedAt / 1000 <= lastT + GRACE_S) {
        resume(file, data)
        lastSeen = s.t
      } else {
        fs.appendFileSync(file, JSON.stringify({ end: lastT * 1000 }) + '\n')
      }
    }
    rotate()
  }

  /** Événement du Game.log : gardé s'il tombe pendant la session en cours (et pas déjà noté). */
  function onEvent(e: LogEvent): void {
    if (!cur || e[0] < cur.start) return
    const key = `${e[0]}|${e[2]}`
    if (cur.seen.has(key)) return
    cur.seen.add(key)
    buf.push(JSON.stringify({ e }))
  }

  return {
    /** Solde aUEC (télémétrie), à chaque changement : noté dans la session en cours. */
    onBalance(ms: number, uec: number): void {
      if (uec === lastUec) return
      lastUec = uec
      if (cur) buf.push(JSON.stringify({ uec: [ms, uec] }))
    },
    /** À chaque mesure du moniteur système (toutes les 2 s, que des écrans soient ouverts ou non). */
    onSample(s: Sample): void {
      if (!booted) boot(s)
      gameOff = s.scMb === null
      if (s.scMb !== null) {
        lastSeen = s.t
        if (!cur) open(s.scStartedAt ?? Date.now())
        buf.push(JSON.stringify([Math.round(s.t), Math.round(s.scMb), s.commitPct === null ? null : Math.round(s.commitPct * 10) / 10]))
        // épisode de fuite : noté comme un événement (croix rouge sur la courbe)
        if (s.leak === 'leak' && lastLeak !== 'leak') onEvent([Math.round(s.t * 1000), 'failure', LEAK_LABEL])
        lastLeak = s.leak
      } else if (cur && s.t - lastSeen > GRACE_S) {
        close(lastSeen * 1000)
      }
    },
    onEvent,
    current: () => cur?.id ?? null,

    // ---- Consultation (routes HTTP, index.ts) ----
    list(): SessionSummary[] {
      flush()
      const files = [
        ...fs.readdirSync(DIR).filter((f) => f.endsWith('.jsonl')).map((f) => path.join(DIR, f)),
        ...fs.readdirSync(SAVED).filter((f) => f.endsWith('.jsonl')).map((f) => path.join(SAVED, f)),
      ]
      return files
        .map((f) => ({ ...summary(f), live: cur?.file === f, ...closing(f) }))
        .sort((a, b) => b.start - a.start)
    },
    get(id: string): SessionData | null {
      const file = fileOf(id)
      if (!file) return null
      if (cur?.file === file) flush()
      return { ...parse(file), live: cur?.file === file, ...closing(file) }
    },
    /** Sauvegarder (gardée indéfiniment) ou rendre à la rotation. */
    setSaved(id: string, saved: boolean): boolean {
      const file = fileOf(id)
      if (!file) return false
      const target = path.join(saved ? SAVED : DIR, `${id}.jsonl`)
      if (file === target) return true
      if (cur?.file === file) flush()
      fs.renameSync(file, target)
      cache.delete(file)
      if (cur?.file === file) cur.file = target
      if (!saved) rotate()
      return true
    },
    /** Supprimer (pas la session en cours). */
    remove(id: string): 'ok' | 'missing' | 'live' {
      const file = fileOf(id)
      if (!file) return 'missing'
      if (cur?.file === file) return 'live'
      fs.rmSync(file, { force: true })
      cache.delete(file)
      return 'ok'
    },
    /** Arrêt du service : écrire ce qui attend (la session reste ouverte, reprise au prochain démarrage). */
    flush,
  }
}
