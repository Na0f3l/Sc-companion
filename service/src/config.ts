// Réglages du service, communs à tous les écrans (PC, téléphone) : ceux qui agissent sur un calcul fait ici,
// comme la détection de fuite mémoire, et le dossier du jeu. Les écrans les modifient par le WebSocket
// ({ type: 'config', … }, { type: 'gameDir', … }) et les reçoivent dans l'état (clés cfg.*).
// Gardés dans config.json, dans le dossier des données (paths.ts).
import fs from 'node:fs'
import path from 'node:path'
import type { Flat } from './flat.ts'
import { DATA_DIR, gameDirInfo, looksLikeGameDir, normalizeGameDir, setManualGameDir } from './paths.ts'
import { picking } from './picker.ts'

type NumKey = 'leakRate' | 'leakDuration'
export interface Config {
  leakRate: number // Mo/s : croissance de la mémoire du jeu (pente sur 15 s) considérée comme anormale
  leakDuration: number // s : durée pendant laquelle elle doit durer pour parler de fuite
  gameDir: string // dossier du jeu choisi dans le menu ; '' = détection automatique (paths.ts)
}

export const DEFAULTS: Config = { leakRate: 100, leakDuration: 45, gameDir: '' }
// bornes acceptées (un écran ne peut pas envoyer n'importe quoi)
const LIMITS: Record<NumKey, [number, number]> = { leakRate: [20, 1000], leakDuration: [10, 600] }

const FILE = path.join(DATA_DIR, 'config.json')

function load(): Config {
  const out = { ...DEFAULTS }
  try {
    const saved = JSON.parse(fs.readFileSync(FILE, 'utf8')) as Partial<Config>
    for (const k of Object.keys(LIMITS) as NumKey[]) {
      const v = Number(saved[k])
      if (Number.isFinite(v)) out[k] = clamp(k, v)
    }
    if (typeof saved.gameDir === 'string') out.gameDir = saved.gameDir
  } catch {
    /* pas encore de réglages */
  }
  return out
}

function clamp(k: NumKey, v: number): number {
  const [lo, hi] = LIMITS[k]
  return Math.min(hi, Math.max(lo, Math.round(v)))
}

export const config: Config = load()
setManualGameDir(config.gameDir)

let saveTimer: NodeJS.Timeout | null = null
// une flèche maintenue envoie une valeur toutes les 80 ms : on n'écrit qu'une fois le réglage posé
function save(): void {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    try {
      fs.mkdirSync(path.dirname(FILE), { recursive: true })
      fs.writeFileSync(FILE, JSON.stringify(config, null, 2))
    } catch (e) {
      console.error('Could not save config:', (e as Error).message)
    }
  }, 1000)
}

/** Applique les champs reçus d'un écran (les inconnus ou invalides sont ignorés), puis enregistre. */
export function updateConfig(patch: Record<string, unknown>): void {
  let changed = false
  for (const k of Object.keys(LIMITS) as NumKey[]) {
    const v = Number(patch[k])
    if (k in patch && Number.isFinite(v) && clamp(k, v) !== config[k]) {
      config[k] = clamp(k, v)
      changed = true
    }
  }
  if (changed) save()
}

/** Dossier du jeu choisi (exe, Game.log ou dossier), ou '' pour revenir à la détection automatique. */
export function setGameDir(p: string): void {
  const dir = p ? normalizeGameDir(p) : ''
  if (dir === config.gameDir) return
  config.gameDir = dir
  setManualGameDir(dir)
  console.log(dir ? `Game folder set to ${dir}` : 'Game folder: automatic detection')
  save()
}

// le dossier contient-il bien le jeu ? vérifié quand il change, pas à chaque envoi (5 fois par seconde)
let checked = { dir: '', ok: false }
export function configFlat(): Flat {
  const { dir, src } = gameDirInfo()
  if (dir !== checked.dir) checked = { dir, ok: looksLikeGameDir(dir) }
  return {
    'cfg.leak_rate': config.leakRate,
    'cfg.leak_duration': config.leakDuration,
    'cfg.game_dir': dir,
    'cfg.game_dir_src': src,
    'cfg.game_dir_ok': checked.ok,
    'cfg.game_dir_picking': picking(),
  }
}
