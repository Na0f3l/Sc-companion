// Emplacements utilisés par le service.
//
// Données de l'utilisateur (sessions, config.json, données vaisseaux mises à jour) : %LOCALAPPDATA%\SC Companion,
// accessible en écriture même si l'appli est installée dans Program Files. Au premier lancement, les données de
// l'ancien emplacement (service/data) y sont copiées (l'ancien dossier est laissé tel quel).
//
// Dossier du jeu : celui du dernier lancement noté par le launcher RSI dans son journal
// (« Launching Star Citizen LIVE from (D:\Games\StarCitizen\LIVE) ») : autre disque, PTU, EPTU… ; sinon le
// dossier d'installation par défaut. --game-dir le force.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const OLD_DATA = path.join(import.meta.dirname, '..', 'data')

export const DATA_DIR = process.env.SCC_DATA_DIR ?? path.join(process.env.LOCALAPPDATA ?? path.join(os.homedir(), 'AppData', 'Local'), 'SC Companion')

if (!fs.existsSync(DATA_DIR)) {
  try {
    if (fs.existsSync(OLD_DATA)) {
      fs.cpSync(OLD_DATA, DATA_DIR, { recursive: true })
      console.log(`Data moved to ${DATA_DIR} (copied from ${OLD_DATA})`)
    } else fs.mkdirSync(DATA_DIR, { recursive: true })
  } catch (e) {
    console.error(`Could not create ${DATA_DIR}:`, (e as Error).message)
  }
}

export const DEFAULT_GAME_DIR = 'C:\\Program Files\\Roberts Space Industries\\StarCitizen\\LIVE'
const LAUNCHER_LOG = path.join(process.env.APPDATA ?? path.join(os.homedir(), 'AppData', 'Roaming'), 'rsilauncher', 'logs', 'log.log')
const LAUNCH_RX = /Launching Star Citizen \w+ from \(([^)]+)\)/g
const TAIL = 512 * 1024 // le journal du launcher fait quelques Mo : la fin suffit (le dernier lancement)

/** Dossier du dernier lancement du jeu d'après le launcher RSI (null : introuvable). */
function fromLauncher(): string | null {
  try {
    const size = fs.statSync(LAUNCHER_LOG).size
    const fd = fs.openSync(LAUNCHER_LOG, 'r')
    try {
      for (const start of [Math.max(0, size - TAIL), 0]) { // la fin d'abord, tout le fichier sinon
        const buf = Buffer.alloc(size - start)
        fs.readSync(fd, buf, 0, buf.length, start)
        let last: string | null = null
        for (const m of buf.toString('utf8').matchAll(LAUNCH_RX)) last = m[1]!
        if (last) return last.replace(/\\\\/g, '\\') // chemin échappé dans le journal (\\ → \)
        if (start === 0) break
      }
    } finally {
      fs.closeSync(fd)
    }
  } catch {
    /* pas de launcher, ou journal illisible */
  }
  return null
}

/**
 * Dossier du jeu à lire (Game.log) : forcé, sinon celui du launcher s'il existe, sinon le dossier par défaut.
 * Appelé à chaque lecture du Game.log (passage LIVE → PTU sans relancer le service) : le journal du launcher
 * n'est relu que s'il a changé (une simple date de modification sinon).
 */
let cache = { mtime: -1, dir: DEFAULT_GAME_DIR }
export function gameDir(forced?: string): string {
  if (forced) return forced
  let mtime = 0
  try {
    mtime = fs.statSync(LAUNCHER_LOG).mtimeMs
  } catch {
    /* pas de launcher */
  }
  if (mtime !== cache.mtime) {
    const dir = fromLauncher()
    cache = { mtime, dir: dir && fs.existsSync(dir) ? dir : DEFAULT_GAME_DIR }
  }
  return cache.dir
}
