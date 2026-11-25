// Connexion au service et état de la télémétrie, partagés par toute l'interface.
//
// L'état est « à plat » : tm['vehicle.state.flight.instruments.speed'] = 312.4
// Vue observe chaque clé séparément : quand la vitesse change, seuls les éléments
// qui affichent la vitesse sont redessinés.
import { reactive, ref } from 'vue'
import { demoData, type DemoView } from './demo'

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
let ws: WebSocket | null = null
let retry: ReturnType<typeof setTimeout> | undefined

function clear(): void {
  for (const k of Object.keys(tm)) delete tm[k]
}

// Dernier état reçu du service, tenu à jour même pendant la démo (non observé : simple copie) : il permet de
// fermer la démo dès que le jeu est lancé, et de repartir de l'état réel en la quittant.
const live: Record<string, Value> = {}
let liveSource = ''
const inGame = () => live['game.mode'] === 'pu' || live['game.mode'] === 'ac' // en partie (pas au menu)

export function connect(): void {
  const sock = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`)
  link.value = 'connecting'

  ws = sock
  sock.onopen = () => {
    link.value = 'online'
    delay = 500
  }
  sock.onmessage = (e) => {
    if (ws !== sock) return
    const msg = JSON.parse(e.data as string) as Msg
    if (msg.type === 'snapshot') {
      for (const k of Object.keys(live)) delete live[k]
      Object.assign(live, msg.data)
      liveSource = msg.source
    } else {
      Object.assign(live, msg.set)
      for (const k of msg.del) delete live[k]
    }
    if (demo.value) {
      if (inGame()) exitDemo() // le jeu est lancé : fin de la démo, place au direct
      return
    }
    if (msg.type === 'snapshot') {
      clear()
      Object.assign(tm, msg.data)
      source.value = msg.source
    } else {
      Object.assign(tm, msg.set)
      for (const k of msg.del) delete tm[k]
    }
  }
  sock.onclose = () => {
    if (ws !== sock) return
    ws = null
    link.value = 'offline'
    for (const k of Object.keys(live)) delete live[k]
    if (!demo.value) clear() // en démo, l'affichage d'exemple reste
    retry = setTimeout(connect, delay)
    delay = Math.min(delay * 2, 5000) // 0,5 s, 1 s, 2 s… plafonné à 5 s
  }
}

/**
 * Change un réglage commun du service (service/src/config.ts), ex. { leakRate: 120 }. Appliqué tout de suite ici
 * (clé cfg.* de l'état) pour que le champ réagisse sans attendre ; le service le renvoie ensuite à tous les écrans.
 * En mode démo, seul l'affichage change.
 */
export function sendConfig(key: 'leakRate' | 'leakDuration', value: number): void {
  tm[key === 'leakRate' ? 'cfg.leak_rate' : 'cfg.leak_duration'] = value
  if (!demo.value && ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'config', [key]: value }))
}

// ---- Mode démo ----------------------------------------------------------------------
// Voir les écrans sans jouer : l'affichage est figé sur des valeurs d'exemple (demo.ts). Pas de simulation, juste
// les panneaux. Seulement hors partie (jeu fermé ou au menu) : la connexion au service reste ouverte en
// arrière-plan, et la démo se ferme d'elle-même dès que le jeu passe en partie (univers persistant, Arena Commander).
export const demo = ref(false)
export const demoView = ref<DemoView>('ship')

export function showDemo(view: DemoView): void {
  if (inGame()) return // en partie : le direct a la priorité
  if (!demo.value) {
    demo.value = true
    source.value = 'demo'
  }
  demoView.value = view
  clear()
  Object.assign(tm, demoData(view))
}

export function exitDemo(): void {
  demo.value = false
  clear()
  Object.assign(tm, live) // reprise immédiate sur l'état réel (la connexion n'a jamais été coupée)
  source.value = liveSource
}
