// Connexion au service et état de la télémétrie, partagés par toute l'interface.
//
// L'état est « à plat » : tm['vehicle.state.flight.instruments.speed'] = 312.4
// Vue observe chaque clé séparément : quand la vitesse change, seuls les éléments
// qui affichent la vitesse sont redessinés.
import { reactive, ref } from 'vue'

export type Value = string | number | boolean
type Msg =
  | { type: 'snapshot'; source: string; data: Record<string, Value> }
  | { type: 'patch'; set: Record<string, Value>; del: string[] }

export const tm = reactive<Record<string, Value>>({})
export const link = ref<'connecting' | 'online' | 'offline'>('connecting')
export const source = ref('')

// ---- Lecture typée (un champ absent = false / 0, comme dans le protocole du jeu) ----
export const num = (k: string, d = 0): number => (typeof tm[k] === 'number' ? (tm[k] as number) : d)
export const str = (k: string, d = ''): string => (typeof tm[k] === 'string' ? (tm[k] as string) : d)
export const bool = (k: string): boolean => tm[k] === true
export const has = (k: string): boolean => k in tm

// Préfixes des sections
export const ACT = 'actor.'
export const VEH = 'vehicle.state.'
export const FLI = 'vehicle.state.flight.instruments.'
export const WPN = 'weapons.'

// ---- Voyants du vaisseau (annunciators) ----
// Le jeu a 7 états : non spécifié, normal, éteint, mineur (fixe / clignotant), majeur (fixe / clignotant).
// Ramenés à 4 niveaux + un indicateur de clignotement.
export type AnnLevel = 'off' | 'nominal' | 'minor' | 'major'
const ANN_LEVEL: Record<string, AnnLevel> = {
  ANNUNCIATOR_STATE_NOMINAL: 'nominal',
  ANNUNCIATOR_STATE_MINOR_ON: 'minor',
  ANNUNCIATOR_STATE_MINOR_FLASHING: 'minor',
  ANNUNCIATOR_STATE_MAJOR_ON: 'major',
  ANNUNCIATOR_STATE_MAJOR_FLASHING: 'major',
}
export const annunciator = (k: string): AnnLevel => ANN_LEVEL[str(`${VEH}annunciators.${k}`)] ?? 'off'
export const annunciatorFlashing = (k: string): boolean => str(`${VEH}annunciators.${k}`).endsWith('_FLASHING')

// « pas de mesure » envoyé par le jeu (plus grand float 32 bits)
export const NO_VALUE = 1e30

// ---- WebSocket avec reconnexion automatique ----------------------------------------
let delay = 500

function clear(): void {
  for (const k of Object.keys(tm)) delete tm[k]
}

export function connect(): void {
  const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`)
  link.value = 'connecting'

  ws.onopen = () => {
    link.value = 'online'
    delay = 500
  }
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data as string) as Msg
    if (msg.type === 'snapshot') {
      clear()
      Object.assign(tm, msg.data)
      source.value = msg.source
    } else {
      Object.assign(tm, msg.set)
      for (const k of msg.del) delete tm[k]
    }
  }
  ws.onclose = () => {
    link.value = 'offline'
    clear()
    setTimeout(connect, delay)
    delay = Math.min(delay * 2, 5000) // 0,5 s, 1 s, 2 s… plafonné à 5 s
  }
}
