// Lecture du Game.log de Star Citizen : mode de jeu (univers persistant / Arena Commander / menu).
//
// Même règle que l'outil PowerShell (memoire/) :
//   gamerules="EA_…" ou « Requesting game mode …/EA_… »  → Arena Commander
//   gamerules="SC_…" (hors SC_Frontend) ou « <Join PU> »  → univers persistant
//   SC_Frontend, « <SystemQuit> »                          → menu / jeu fermé
//
// Léger : toutes les 2 s, on regarde seulement la taille du fichier ; s'il a grossi, on lit les
// octets ajoutés depuis la dernière fois (jamais tout le fichier, sauf une fois au démarrage).
// Le jeu recrée le fichier à chaque lancement : s'il rétrécit, on repart du début.
import fs from 'node:fs'
import path from 'node:path'
import type { Flat } from './flat.ts'

export type GameMode = 'pu' | 'ac' | 'menu'

const DEFAULT_DIR = 'C:\\Program Files\\Roberts Space Industries\\StarCitizen\\LIVE'
const POLL_MS = 2000
const MAX_FIRST_READ = 8 * 2 ** 20 // octets lus au plus au démarrage (fin du fichier)
const MODE_RX = /gamerules="([^"]+)"|Requesting game mode [^/\s"]*\/(\w+)|(<Join PU>)|(<SystemQuit>)/g

function modeOf(m: RegExpExecArray): GameMode {
  if (m[3]) return 'pu'
  if (m[4]) return 'menu'
  const rules = m[1] ?? m[2] ?? ''
  if (rules.startsWith('EA_')) return 'ac'
  if (rules.startsWith('SC_') && rules !== 'SC_Frontend') return 'pu'
  return 'menu'
}

// Dernier mode trouvé dans un morceau de texte (ou null)
function lastMode(text: string): GameMode | null {
  let mode: GameMode | null = null
  MODE_RX.lastIndex = 0
  for (let m = MODE_RX.exec(text); m; m = MODE_RX.exec(text)) mode = modeOf(m)
  return mode
}

export function createGameLogReader(gameDir = DEFAULT_DIR) {
  const file = path.join(gameDir, 'Game.log')
  let timer: NodeJS.Timeout | null = null
  let pos = 0
  let rest = '' // fin de ligne incomplète, gardée pour la lecture suivante
  let mode: GameMode | null = null

  function readFrom(start: number, end: number): string {
    const fd = fs.openSync(file, 'r') // Node ouvre en lecture partagée : le jeu peut continuer d'écrire
    try {
      const buf = Buffer.alloc(end - start)
      fs.readSync(fd, buf, 0, buf.length, start)
      return buf.toString('utf8')
    } finally {
      fs.closeSync(fd)
    }
  }

  function poll(): void {
    let size: number
    try {
      size = fs.statSync(file).size
    } catch {
      mode = null // pas de Game.log (jeu jamais lancé, autre dossier)
      return
    }
    if (size < pos) { pos = 0; rest = ''; mode = null } // nouveau fichier (jeu relancé)
    if (size === pos) return
    if (pos === 0 && size > MAX_FIRST_READ) pos = size - MAX_FIRST_READ // premier passage : la fin suffit
    const text = rest + readFrom(pos, size)
    pos = size
    const cut = text.lastIndexOf('\n')
    rest = cut >= 0 ? text.slice(cut + 1) : text
    const found = lastMode(cut >= 0 ? text.slice(0, cut) : '')
    if (found) mode = found
  }

  return {
    start() {
      if (timer) return
      poll() // premier passage : lit le fichier existant une fois
      timer = setInterval(poll, POLL_MS)
    },
    stop() {
      if (timer) clearInterval(timer)
      timer = null
    },
    flat: (): Flat => (mode ? { 'game.mode': mode } : {}),
  }
}
