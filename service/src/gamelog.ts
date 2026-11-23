// Lecture du Game.log de Star Citizen : mode de jeu (univers persistant / Arena Commander / menu)
// et blessures du personnage.
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

// Blessures : notifications du HUD, ex. « Minor Injury Detected - Right leg - Tier 3 Treatment Required ».
// Tier 3 = mineure, 2 = modérée, 1 = grave. Le jeu ne note PAS la guérison : voir clearInjuries().
const INJURY_RX = /Injury Detected - (Head|Torso|Left arm|Right arm|Left leg|Right leg) - Tier ([123])/g
// Soin au lit médical : « <MED BED HEAL> … Perform surgery event Success … head: false torso: false leftArm: false
// rightArm: false leftLeg: false rightLeg: true » (true = partie soignée). Les autres soins (medpen, medgun)
// n'écrivent rien : pour eux, voir clearInjuries() (santé max revenue à 100).
const MEDBED_RX = /<MED BED HEAL>.*?surgery event Success.*?head: (true|false) torso: (true|false) leftArm: (true|false) rightArm: (true|false) leftLeg: (true|false) rightLeg: (true|false)/g
const MEDBED_PARTS = ['head', 'torso', 'left_arm', 'right_arm', 'left_leg', 'right_leg']
const PART_KEY: Record<string, string> = {
  Head: 'head', Torso: 'torso', 'Left arm': 'left_arm', 'Right arm': 'right_arm', 'Left leg': 'left_leg', 'Right leg': 'right_leg',
}

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
  // partie du corps → tier (la dernière notification fait foi) et moment où on l'a lue
  const injuries = new Map<string, { tier: number; at: number }>()

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
    if (size < pos) { pos = 0; rest = ''; mode = null; injuries.clear() } // nouveau fichier (jeu relancé)
    if (size === pos) return
    if (pos === 0 && size > MAX_FIRST_READ) pos = size - MAX_FIRST_READ // premier passage : la fin suffit
    const text = rest + readFrom(pos, size)
    pos = size
    const cut = text.lastIndexOf('\n')
    rest = cut >= 0 ? text.slice(cut + 1) : text
    const lines = cut >= 0 ? text.slice(0, cut) : ''
    const found = lastMode(lines)
    if (found) mode = found
    // blessures et soins dans l'ordre du log : une blessure soignée puis reprise reste affichée
    const events: [number, () => void][] = []
    INJURY_RX.lastIndex = 0
    for (let m = INJURY_RX.exec(lines); m; m = INJURY_RX.exec(lines)) {
      const part = PART_KEY[m[1]!]!
      const tier = Number(m[2])
      events.push([m.index, () => injuries.set(part, { tier, at: Date.now() })])
    }
    MEDBED_RX.lastIndex = 0
    for (let m = MEDBED_RX.exec(lines); m; m = MEDBED_RX.exec(lines)) {
      const healed = MEDBED_PARTS.filter((_, i) => m![i + 1] === 'true')
      events.push([m.index, () => healed.forEach((p) => injuries.delete(p))])
    }
    events.sort((a, b) => a[0] - b[0]).forEach(([, apply]) => apply())
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
    /**
     * Blessures soignées (le jeu ne l'écrit pas dans le log : décidé par le service, voir index.ts).
     * Seules celles lues depuis plus de 10 s sont effacées : une blessure toute neuve peut arriver dans le log
     * un instant avant que la santé max ne baisse dans la télémétrie.
     */
    clearInjuries() {
      const limit = Date.now() - 10_000
      for (const [part, i] of injuries) if (i.at < limit) injuries.delete(part)
    },
    flat: (): Flat => {
      const out: Flat = mode ? { 'game.mode': mode } : {}
      for (const [part, i] of injuries) out[`injury.${part}`] = i.tier
      return out
    },
  }
}
