// Système d'alertes.
//
// Une alerte = une règle : un identifiant, un niveau, un message et une condition calculée
// à partir de la télémétrie. Pour en ajouter une, il suffit d'ajouter une ligne dans RULES.
//
// Aucune interaction : quand une condition DEVIENT vraie, l'alerte s'affiche 1,5 s puis disparaît seule.
// Si plusieurs se déclenchent en même temps, elles passent l'une après l'autre.
// Une alerte qui reste vraie ne se réaffiche pas ; si elle redevient fausse puis vraie, oui.
//
// Pour les situations « par paliers » (température du corps), on émet aussi des alertes ponctuelles
// avec pushAlert(), voir plus bas.
import { computed, ref, shallowRef, watch } from 'vue'
import { ACT, FLI, NO_VALUE, VEH, bool, has, num, str } from './telemetry'
import { playAlert } from './sound'

export type AlertLevel = 'critical' | 'warning'

export interface AlertItem {
  id: string
  level: AlertLevel
  message: string
}

export interface AlertRule extends AlertItem {
  active: () => boolean
}

export const DISPLAY_MS = 1500 // durée d'affichage d'une alerte (3 battements de 0,5 s, voir AlertOverlay)

// Alerte de test : déclenchée par le bouton de l'en-tête, retombe d'elle-même
const testAlert = ref(false)
export function triggerTest(): void {
  testAlert.value = true
  setTimeout(() => (testAlert.value = false), DISPLAY_MS + 200)
}

// Seuil bas avec hystérésis : vrai sous `on`, ne redevient faux qu'au-dessus de `off`.
// Évite une alerte en boucle quand la valeur oscille autour du seuil.
// Faux si le champ n'est pas reçu (jeu fermé, hors ligne) : une valeur absente n'est pas « 0 % ».
function lowVital(name: string, on = 0.25, off = 0.3): () => boolean {
  let low = false
  return () => {
    const k = `${ACT}vitals.${name}.current`
    if (!has(k)) return (low = false)
    const ratio = num(k) / (num(`${ACT}vitals.${name}.max`, 100) || 100)
    low = low ? ratio < off : ratio < on
    return low
  }
}

// Seuil haut avec hystérésis : vrai au-dessus de `on`, ne redevient faux qu'en dessous de `off`.
// Faux si la valeur n'est pas reçue.
function above(key: string, on: number, off: number): () => boolean {
  let high = false
  return () => {
    if (!has(key)) return (high = false)
    const v = num(key)
    high = high ? v > off : v > on
    return high
  }
}

// ---- Vol ----
const gearDown = () => /DEPLOY/.test(str(`${VEH}flight.state.gear`)) // sorti ou en cours de sortie

/**
 * Temps avant impact au sol (s), ou null si non calculable.
 * altitude radar (hauteur sous le vaisseau) ÷ vitesse de descente.
 * La vitesse verticale est négative en descente (vérifié sur capture).
 * L'altitude radar vaut 3,4e38 hors de portée : pas de prédiction possible.
 */
export function timeToImpact(): number | null {
  const altKey = `${FLI}radar_altitude`
  if (!has(altKey)) return null
  const alt = num(altKey)
  const vsi = num(`${FLI}vertical_speed_indicator`) // absent = 0
  if (alt > NO_VALUE || vsi >= 0) return null
  return alt / -vsi
}

/**
 * Crash imminent : impact au sol prévu dans moins de 10 s.
 * - descente d'au moins 5 m/s (en dessous, c'est une approche, pas une chute) ;
 * - train sorti = atterrissage voulu : seuil beaucoup plus strict (impact < 3 s à plus de 10 m/s,
 *   c'est-à-dire un posé violent), pour ne pas sonner à chaque atterrissage ;
 * - hystérésis : l'alerte retombe quand l'impact n'est plus prévu avant 12 s.
 */
function groundImpact(): () => boolean {
  let on = false
  return () => {
    const tti = timeToImpact()
    const sink = -num(`${FLI}vertical_speed_indicator`)
    if (tti === null || bool(`${VEH}flight.state.is_landed`)) return (on = false)
    const [limit, minSink] = gearDown() ? [3, 10] : [10, 5]
    on = on ? tti < limit + 2 && sink > minSink / 2 : tti < limit && sink > minSink
    return on
  }
}

/**
 * Collision : voyant PROX du vaisseau au rouge, sauf en manœuvre de décollage / atterrissage
 * (train sorti ou moins de 30 m/s), où il s'allume normalement près du sol et des hangars.
 */
const proximity = () =>
  str(`${VEH}annunciators.prox`) === 'ANNUNCIATOR_STATE_MAJOR_ON' && !gearDown() && num(`${FLI}speed`) >= 30

// Au-dessus de cette vitesse, un crash ou une collision devient une alerte importante (rouge + son)
const FAST = 100 // m/s
const fast = () => num(`${FLI}speed`) > FAST
const ground = groundImpact() // une seule instance : son état (hystérésis) est partagé par les deux niveaux

// Niveaux :
//  - critical : alerte importante, rouge, avec son
//  - warning  : alerte secondaire, orange, sans son
// L'ordre fixe la priorité quand plusieurs alertes arrivent ensemble.
const RULES: AlertRule[] = [
  { id: 'test', level: 'critical', message: 'Crash imminent', active: () => testAlert.value },
  { id: 'ground-fast', level: 'critical', message: 'Crash imminent', active: () => ground() && fast() },
  { id: 'collision-fast', level: 'critical', message: 'Collision imminent', active: () => proximity() && fast() },
  { id: 'ground-slow', level: 'warning', message: 'Ground proximity', active: () => ground() && !fast() },
  { id: 'collision-slow', level: 'warning', message: 'Obstacle nearby', active: () => proximity() && !fast() },
  { id: 'health', level: 'critical', message: 'Critical health', active: lowVital('health') },
  { id: 'thirst', level: 'warning', message: 'Dehydrated', active: lowVital('thirst') },
  { id: 'hunger', level: 'warning', message: 'Starving', active: lowVital('hunger') },
  // voyant MISL en rouge : un missile est verrouillé sur le vaisseau
  // Mémoire (mêmes seuils que l'outil PowerShell) : fuite détectée par le service, engagement système
  { id: 'ram-leak', level: 'critical', message: 'RAM leak detected', active: () => str('sc.leak') === 'leak' },
  { id: 'mem-crit', level: 'critical', message: 'Memory critical', active: above('sys.commit_pct', 75, 72) },
  { id: 'mem-high', level: 'warning', message: 'Memory high', active: above('sys.commit_pct', 65, 62) },
  { id: 'missile', level: 'critical', message: 'Missile lock', active: () => str(`${VEH}annunciators.misl`) === 'ANNUNCIATOR_STATE_MAJOR_ON' },
]

const activeAlerts = computed(() => RULES.filter((r) => r.active()))

// ---- File d'affichage ----
const queue: AlertItem[] = []
/** Alerte affichée en ce moment (null = rien). shallowRef : on garde l'objet tel quel (comparaisons par identité). */
export const shownAlert = shallowRef<AlertItem | null>(null)

/** Alerte ponctuelle : affichée une fois (après celles déjà en attente). */
export function pushAlert(item: AlertItem): void {
  queue.push(item)
  if (!shownAlert.value) showNext()
}

function showNext(): void {
  shownAlert.value = queue.shift() ?? null
  if (shownAlert.value) {
    playAlert(shownAlert.value.level)
    setTimeout(showNext, DISPLAY_MS)
  }
}

// Détection des fronts montants : une règle présente maintenant et absente juste avant
watch(
  activeAlerts,
  (now, before = []) => {
    for (const rule of now) {
      if (!before.includes(rule) && !queue.includes(rule) && shownAlert.value !== rule) queue.push(rule)
    }
    if (!shownAlert.value) showNext()
  },
  { immediate: true },
)

// ---- Température du corps : alertes par paliers ------------------------------------
//
// Chaud : 39 °C franchi en montant → orange ; puis 40, 41, 42… → rouge à chaque degré entier franchi.
// Froid : 35 °C franchi en descendant → orange ; puis 34, 33, 32… → rouge.
// Seule l'aggravation alerte : revenir de 42 à 41 ne déclenche rien.
// Un palier se « réarme » quand on est repassé 0,5 °C du bon côté (évite les alertes en boucle
// quand la valeur oscille autour d'un entier) : 42 → 41,4 → 42 réalerte, 42 → 41,8 → 42 non.
const HOT_WARN = 39
const HOT_CRIT = 40
const COLD_WARN = 35
const COLD_CRIT = 34
let hotDone = -Infinity // plus haut palier chaud déjà signalé
let coldDone = Infinity // plus bas palier froid déjà signalé

watch(
  () => (has(`${ACT}vitals.body_temperature.current`) ? num(`${ACT}vitals.body_temperature.current`) : null),
  (t) => {
    if (t === null) return
    // réarmement des paliers dépassés dans le bon sens
    hotDone = Math.min(hotDone, Math.floor(t + 0.5))
    coldDone = Math.max(coldDone, Math.ceil(t - 0.5))

    const hot = Math.ceil(t) - 1 // plus haut entier strictement dépassé
    if (hot >= HOT_WARN && hot > hotDone) {
      hotDone = hot
      const crit = hot >= HOT_CRIT
      pushAlert({ id: `body-hot-${hot}`, level: crit ? 'critical' : 'warning', message: `${crit ? 'Hyperthermia' : 'Body temp high'} · ${hot}°C` })
    }

    const cold = Math.floor(t) + 1 // plus bas entier strictement passé en dessous
    if (cold <= COLD_WARN && cold < coldDone) {
      coldDone = cold
      const crit = cold <= COLD_CRIT
      pushAlert({ id: `body-cold-${cold}`, level: crit ? 'critical' : 'warning', message: `${crit ? 'Hypothermia' : 'Body temp low'} · ${cold}°C` })
    }
  },
)

/** Teinte de toute l'interface pendant l'affichage d'une alerte. */
export const alertLevel = computed<AlertLevel | null>(() => shownAlert.value?.level ?? null)
