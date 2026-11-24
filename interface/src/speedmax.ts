// Vitesse max d'un vaisseau, pour l'échelle de la barre de vitesse (barre pleine = vitesse max).
//
// Le jeu n'envoie pas la vitesse max. Par ordre de priorité :
//  1. vitesse réelle du vaisseau, tirée de ships.json (voir ships.ts) ; en SCM, barre pleine = vitesse
//     de boost (la plus haute atteignable dans ce mode), à défaut la SCM ;
//  2. la vitesse max APPRISE : la plus haute vitesse atteinte avec ce vaisseau dans ce mode (SCM / NAV),
//     mémorisée dans le navigateur ;
//  3. DEFAULTS tant que le vaisseau n'a jamais volé dans ce mode.
//
// Garde-fous de l'apprentissage :
//  - au-dessus de MAX_PLAUSIBLE, c'est du quantum (ou une valeur aberrante) : ignoré ;
//  - après un changement de vaisseau ou de mode, rien n'est appris pendant GRACE_MS (le temps de
//    ralentir après NAV → SCM, sinon la vitesse NAV serait apprise comme vitesse SCM).
import { reactive } from 'vue'
import { shipInfo } from './ships'

export type Mode = 'SCM' | 'NAV'

/** Vitesse réelle du vaisseau dans ce mode, prioritaire sur l'apprentissage. */
function known(ship: string, mode: Mode): number | undefined {
  const s = shipInfo(ship)
  return mode === 'NAV' ? s?.nav : (s?.boost ?? s?.scm)
}

const DEFAULTS: Record<Mode, number> = { SCM: 250, NAV: 1000 }
const MAX_PLAUSIBLE = 2500 // m/s : aucun vaisseau ne va plus vite hors quantum
const GRACE_MS = 15000
const KEY = 'sc-companion.speedmax'

function load(): Record<string, Partial<Record<Mode, number>>> {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? '{}')
  } catch {
    return {}
  }
}

// reactive : la barre se recalibre d'elle-même quand un nouveau maximum est appris
const learned = reactive(load())
let saveTimer: ReturnType<typeof setTimeout> | undefined
function save(): void {
  // au plus une écriture toutes les 2 s (pendant la première accélération, le max monte à chaque mesure)
  if (saveTimer) return
  saveTimer = setTimeout(() => {
    saveTimer = undefined
    try {
      localStorage.setItem(KEY, JSON.stringify(learned))
    } catch {
      /* stockage indisponible : appris le temps de la session */
    }
  }, 2000)
}

/** Vitesse correspondant à une barre pleine, et d'où elle vient. */
export function speedMax(ship: string, mode: Mode): { value: number; source: 'known' | 'learned' | 'default' } {
  const k = known(ship, mode)
  if (k) return { value: k, source: 'known' }
  const l = learned[ship]?.[mode]
  if (l) return { value: l, source: 'learned' }
  return { value: DEFAULTS[mode], source: 'default' }
}

let context = ''
let since = 0

/** À appeler à chaque nouvelle vitesse : retient la plus haute atteinte pour ce vaisseau et ce mode. */
export function learnSpeed(ship: string, mode: Mode, speed: number): void {
  if (!ship || known(ship, mode)) return
  const now = performance.now()
  const ctx = `${ship}|${mode}`
  if (ctx !== context) {
    context = ctx
    since = now
    return
  }
  if (now - since < GRACE_MS || speed > MAX_PLAUSIBLE) return
  const current = learned[ship]?.[mode] ?? 0
  if (speed > current && speed > DEFAULTS[mode] * 0.5) {
    learned[ship] = { ...learned[ship], [mode]: Math.ceil(speed) }
    save()
  }
}
