// Réglages du service, communs à tous les écrans (PC, téléphone) : ceux qui agissent sur un calcul fait ici,
// comme la détection de fuite mémoire. Les écrans les modifient par le WebSocket ({ type: 'config', … }) et
// les reçoivent dans l'état (clés cfg.*). Gardés dans service/data/config.json (non publié, voir .gitignore).
import fs from 'node:fs'
import path from 'node:path'
import type { Flat } from './flat.ts'

export interface Config {
  leakRate: number // Mo/s : croissance de la mémoire du jeu (pente sur 15 s) considérée comme anormale
  leakDuration: number // s : durée pendant laquelle elle doit durer pour parler de fuite
}

export const DEFAULTS: Config = { leakRate: 100, leakDuration: 45 }
// bornes acceptées (un écran ne peut pas envoyer n'importe quoi)
const LIMITS: Record<keyof Config, [number, number]> = { leakRate: [20, 1000], leakDuration: [10, 600] }

const FILE = path.join(import.meta.dirname, '..', 'data', 'config.json')

function load(): Config {
  try {
    const saved = JSON.parse(fs.readFileSync(FILE, 'utf8')) as Partial<Config>
    const out = { ...DEFAULTS }
    for (const k of Object.keys(LIMITS) as (keyof Config)[]) {
      const v = Number(saved[k])
      if (Number.isFinite(v)) out[k] = clamp(k, v)
    }
    return out
  } catch {
    return { ...DEFAULTS }
  }
}

function clamp(k: keyof Config, v: number): number {
  const [lo, hi] = LIMITS[k]
  return Math.min(hi, Math.max(lo, Math.round(v)))
}

export const config: Config = load()

let saveTimer: NodeJS.Timeout | null = null

/** Applique les champs reçus d'un écran (les inconnus ou invalides sont ignorés), puis enregistre. */
export function updateConfig(patch: Record<string, unknown>): void {
  let changed = false
  for (const k of Object.keys(LIMITS) as (keyof Config)[]) {
    const v = Number(patch[k])
    if (k in patch && Number.isFinite(v) && clamp(k, v) !== config[k]) {
      config[k] = clamp(k, v)
      changed = true
    }
  }
  if (!changed) return
  // une flèche maintenue envoie une valeur toutes les 80 ms : on n'écrit qu'une fois le réglage posé
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

export const configFlat = (): Flat => ({ 'cfg.leak_rate': config.leakRate, 'cfg.leak_duration': config.leakDuration })
