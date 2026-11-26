// Emplacements utilisés par le service.
//
// Données de l'utilisateur (sessions, config.json, données vaisseaux mises à jour) : %LOCALAPPDATA%\SC Companion,
// accessible en écriture même si l'appli est installée dans Program Files. Au premier lancement, les données de
// l'ancien emplacement (service/data) y sont copiées (l'ancien dossier est laissé tel quel).
//
// Dossier du jeu : celui de StarCitizen.exe s'il tourne, sinon celui du dernier lancement noté par le launcher RSI
// dans son journal (« Launching Star Citizen LIVE from (D:\Games\StarCitizen\LIVE) ») : autre disque, PTU, EPTU… ;
// sinon le dossier d'installation par défaut. Un dossier choisi dans le menu, ou --game-dir, passe avant.
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

/** D'où vient le dossier du jeu : ligne de commande, choix dans le menu, jeu en cours, launcher, défaut. */
export type GameDirSource = 'cli' | 'manual' | 'game' | 'launcher' | 'default'

let forced = '' // --game-dir
let manual = '' // choisi dans le menu (config.json), '' = automatique
let running: string | null = null // dossier de StarCitizen.exe en cours d'exécution (system.ts)
let lastRunning: string | null = null // le dernier vu, si le launcher ne dit rien

export const setForcedGameDir = (dir: string | undefined): void => void (forced = dir ? normalizeGameDir(dir) : '')
export const setManualGameDir = (dir: string): void => void (manual = dir)
export function setRunningGameDir(dir: string | null): void {
  running = dir
  if (dir) lastRunning = dir
}

/** Chemin donné par l'utilisateur → dossier du jeu : …\Bin64\StarCitizen.exe, …\Game.log ou …\Bin64 → …\LIVE. */
export function normalizeGameDir(p: string): string {
  let dir = path.resolve(p.trim().replace(/^"(.*)"$/, '$1'))
  if (/\.(exe|log)$/i.test(dir)) dir = path.dirname(dir)
  if (path.basename(dir).toLowerCase() === 'bin64') dir = path.dirname(dir)
  return dir
}

/** Le dossier contient-il un jeu (exe ou Game.log) ? */
export const looksLikeGameDir = (dir: string): boolean =>
  fs.existsSync(path.join(dir, 'Bin64', 'StarCitizen.exe')) || fs.existsSync(path.join(dir, 'Game.log'))

let launcher = { mtime: -1, dir: null as string | null }
function launcherDir(): string | null {
  let mtime = 0
  try {
    mtime = fs.statSync(LAUNCHER_LOG).mtimeMs
  } catch {
    /* pas de launcher */
  }
  if (mtime !== launcher.mtime) { // journal relu seulement s'il a changé
    const dir = fromLauncher()
    launcher = { mtime, dir: dir && fs.existsSync(dir) ? dir : null }
  }
  return launcher.dir
}

/**
 * Dossier du jeu (Game.log, schéma de télémétrie) et sa provenance. Par ordre de priorité : --game-dir, choix du
 * menu, jeu en cours d'exécution (le plus sûr : LIVE, PTU, autre disque, lancé sans le launcher…), dernier
 * lancement noté par le launcher, dernier jeu vu tournant, dossier par défaut.
 * Appelé à chaque lecture du Game.log : passage LIVE → PTU suivi sans relancer le service.
 */
export function gameDirInfo(): { dir: string; src: GameDirSource } {
  if (forced) return { dir: forced, src: 'cli' }
  if (manual) return { dir: manual, src: 'manual' }
  if (running) return { dir: running, src: 'game' }
  const l = launcherDir()
  if (l) return { dir: l, src: 'launcher' }
  if (lastRunning) return { dir: lastRunning, src: 'game' }
  return { dir: DEFAULT_GAME_DIR, src: 'default' }
}

export const gameDir = (): string => gameDirInfo().dir
