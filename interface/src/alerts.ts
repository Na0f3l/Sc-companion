// Système d'alertes.
//
// Une alerte = une règle : un identifiant, un niveau, un message et une condition calculée
// à partir de la télémétrie. Pour en ajouter une, il suffit d'ajouter une ligne dans RULES.
//
// Aucune interaction : quand une condition DEVIENT vraie, l'alerte s'affiche 1,5 s puis disparaît seule.
// Si plusieurs se déclenchent en même temps, elles passent l'une après l'autre.
// Une alerte qui reste vraie ne se réaffiche pas ; si elle redevient fausse puis vraie, oui.
import { computed, ref, watch } from 'vue'
import { ACT, FLI, NO_VALUE, VEH, bool, has, num, str } from './telemetry'
import { playAlert } from './sound'

export type AlertLevel = 'critical' | 'warning'

export interface AlertRule {
  id: string
  level: AlertLevel
  message: string
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

const RULES: AlertRule[] = [
  { id: 'test', level: 'critical', message: 'Crash imminent', active: () => testAlert.value },
  { id: 'ground', level: 'critical', message: 'Crash imminent', active: groundImpact() },
  { id: 'collision', level: 'critical', message: 'Collision imminente', active: proximity },
  { id: 'health', level: 'critical', message: 'Santé critique', active: lowVital('health') },
  { id: 'thirst', level: 'warning', message: 'Déshydratation', active: lowVital('thirst') },
  { id: 'hunger', level: 'warning', message: 'Sous-alimentation', active: lowVital('hunger') },
  // voyant MISL en rouge : un missile est verrouillé sur le vaisseau
  { id: 'missile', level: 'critical', message: 'Missile verrouillé', active: () => str(`${VEH}annunciators.misl`) === 'ANNUNCIATOR_STATE_MAJOR_ON' },
]

const activeAlerts = computed(() => RULES.filter((r) => r.active()))

// ---- File d'affichage ----
const queue: AlertRule[] = []
/** Alerte affichée en ce moment (null = rien). */
export const shownAlert = ref<AlertRule | null>(null)

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

/** Teinte de toute l'interface pendant l'affichage d'une alerte. */
export const alertLevel = computed<AlertLevel | null>(() => shownAlert.value?.level ?? null)
