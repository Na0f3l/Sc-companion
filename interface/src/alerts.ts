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
import { computed, shallowRef, watch } from 'vue'
import { ACT, FLI, NO_VALUE, VEH, annunciator, bool, has, num, str } from './telemetry'
import { playAlert } from './sound'
import { type AlertGroup, alertEnabled, componentAlertEnabled } from './settings'
import { flash } from './hit'

export type AlertLevel = 'critical' | 'warning'

export interface AlertItem {
  id: string
  level: AlertLevel
  message: string
}

export interface AlertRule extends AlertItem {
  group: AlertGroup // case du menu qui l'active / la désactive
  active: () => boolean
}

export const DISPLAY_MS = 1500 // durée d'affichage d'une alerte (3 battements de 0,5 s, voir AlertOverlay)

// Alertes de test : déclenchées depuis le menu « Test » de l'en-tête, affichées une fois.
// Mêmes messages et niveaux que les vraies alertes, pour juger du rendu et du son.
export const TESTS = {
  medium: { label: 'Medium alert', item: { id: 'test-medium', level: 'warning', message: 'Obstacle nearby' } },
  high: { label: 'High alert', item: { id: 'test-high', level: 'critical', message: 'Crash imminent' } },
  ram: { label: 'RAM alert', item: { id: 'test-ram', level: 'critical', message: 'RAM leak detected' } },
} satisfies Record<string, { label: string; item: AlertItem }>
export type TestKind = keyof typeof TESTS
export function triggerTest(kind: TestKind): void {
  pushAlert({ ...TESTS[kind].item })
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
 * Préavis avant impact selon la vitesse : plus on va vite, plus on prévient tôt.
 *   < 800 m/s : 10 s · de 800 à 1000 m/s : de 10 à 20 s · ≥ 1000 m/s : 20 s
 * Limite : il faut que le radar voie déjà le sol (altitude radar reçue) au moment du préavis.
 */
export function impactLeadTime(speed: number): number {
  if (speed >= 1000) return 20
  if (speed > 800) return 10 + ((speed - 800) / 200) * 10
  return 10
}

/**
 * Crash imminent : impact au sol prévu dans moins que le préavis (10 à 20 s selon la vitesse).
 * - descente d'au moins 5 m/s (en dessous, c'est une approche, pas une chute) ;
 * - train sorti = atterrissage voulu : seuil beaucoup plus strict (impact < 3 s à plus de 10 m/s,
 *   c'est-à-dire un posé violent), pour ne pas sonner à chaque atterrissage ;
 * - hystérésis : l'alerte retombe quand l'impact n'est plus prévu avant préavis + 2 s.
 */
function groundImpact(): () => boolean {
  let on = false
  return () => {
    const tti = timeToImpact()
    const sink = -num(`${FLI}vertical_speed_indicator`)
    if (tti === null || bool(`${VEH}flight.state.is_landed`)) return (on = false)
    const [limit, minSink] = gearDown() ? [3, 10] : [impactLeadTime(num(`${FLI}speed`)), 5]
    on = on ? tti < limit + 2 && sink > minSink / 2 : tti < limit && sink > minSink
    return on
  }
}

/**
 * Collision : voyant PROX du vaisseau au rouge, sauf en manœuvre de décollage / atterrissage :
 * train sorti, ou vitesse sous `minSpeed` (le voyant s'allume normalement près des hangars et des pads).
 */
const proximity = (minSpeed: number) =>
  annunciator('prox') === 'major' && !gearDown() && num(`${FLI}speed`) >= minSpeed
// L'alerte orange « obstacle » ne s'affiche qu'au-dessus de cette vitesse : un posé sportif
// mais maîtrisé (en station notamment) reste silencieux.
const OBSTACLE_MIN_SPEED = 60 // m/s

// Au-dessus de cette vitesse, un crash ou une collision devient une alerte importante (rouge + son)
const FAST = 100 // m/s
const fast = () => num(`${FLI}speed`) > FAST
const ground = groundImpact() // une seule instance : son état (hystérésis) est partagé par les deux niveaux

// Niveaux :
//  - critical : alerte importante, rouge, avec son
//  - warning  : alerte secondaire, orange, son discret
// L'ordre fixe la priorité quand plusieurs alertes arrivent ensemble.
const RULES: AlertRule[] = [
  { id: 'ground-fast', group: 'crash', level: 'critical', message: 'Crash imminent', active: () => ground() && fast() },
  { id: 'collision-fast', group: 'collision', level: 'critical', message: 'Collision imminent', active: () => proximity(OBSTACLE_MIN_SPEED) && fast() },
  { id: 'ground-slow', group: 'crash', level: 'warning', message: 'Ground proximity', active: () => ground() && !fast() },
  { id: 'collision-slow', group: 'collision', level: 'warning', message: 'Obstacle nearby', active: () => proximity(OBSTACLE_MIN_SPEED) && !fast() },
  { id: 'health', group: 'health', level: 'critical', message: 'Critical health', active: lowVital('health') },
  { id: 'thirst', group: 'thirst', level: 'warning', message: 'Dehydrated', active: lowVital('thirst') },
  { id: 'hunger', group: 'hunger', level: 'warning', message: 'Starving', active: lowVital('hunger') },
  // voyant MISL en rouge : un missile est verrouillé sur le vaisseau
  // Mémoire (mêmes seuils que l'outil PowerShell) : fuite détectée par le service, engagement système
  { id: 'ram-leak', group: 'ramLeak', level: 'critical', message: 'RAM leak detected', active: () => str('sc.leak') === 'leak' },
  { id: 'mem-crit', group: 'memory', level: 'critical', message: 'Memory critical', active: above('sys.commit_pct', 75, 72) },
  { id: 'mem-high', group: 'memory', level: 'warning', message: 'Memory high', active: above('sys.commit_pct', 65, 62) },
  { id: 'missile', group: 'missile', level: 'critical', message: 'Missile lock', active: () => annunciator('misl') === 'major' },
]

// r.active() est appelé même pour une alerte désactivée : les règles à hystérésis gardent leur état à jour
const activeAlerts = computed(() => RULES.filter((r) => r.active() && alertEnabled(r.group)))

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
      if (alertEnabled('bodyTemp')) pushAlert({ id: `body-hot-${hot}`, level: crit ? 'critical' : 'warning', message: `${crit ? 'Hyperthermia' : 'Body temp high'} · ${hot}°C` })
    }

    const cold = Math.floor(t) + 1 // plus bas entier strictement passé en dessous
    if (cold <= COLD_WARN && cold < coldDone) {
      coldDone = cold
      const crit = cold <= COLD_CRIT
      if (alertEnabled('bodyTemp')) pushAlert({ id: `body-cold-${cold}`, level: crit ? 'critical' : 'warning', message: `${crit ? 'Hypothermia' : 'Body temp low'} · ${cold}°C` })
    }
  },
)

// ---- Composants endommagés ------------------------------------------------------------
//
// Le jeu n'envoie rien quand le vaisseau se fait tirer dessus (ni boucliers, ni coque, ni voyant HIT :
// vérifié en test réel le 2026-11-23). Les dégâts se voient seulement par leurs conséquences : le voyant
// d'un composant qui passe à l'orange (mineur) puis au rouge (majeur), ex. THR orange après des tirs sur la coque.
// Alerte quand un voyant s'aggrave ET que le composant est alimenté depuis au moins 3 s : rallumer les
// boucliers fait passer SHLD au rouge un instant, ce n'est pas un dégât.
const COMPONENTS = [
  { ann: 'pwr', power: 'powerplants', name: 'Power plant' },
  { ann: 'thr', power: 'engines', name: 'Thrusters' },
  { ann: 'wpn', power: 'weapons', name: 'Weapons' },
  { ann: 'cool', power: 'coolers', name: 'Coolers' },
  { ann: 'radr', power: 'sensors', name: 'Radar' },
  { ann: 'shld', power: 'shield_generators', name: 'Shields' },
] as const
const SEVERITY = { off: 0, nominal: 0, minor: 1, major: 2 } as const
const POWER_SETTLE_MS = 3000

for (const c of COMPONENTS) {
  let poweredSince = 0
  watch(
    () => bool(`${VEH}power.${c.power}`),
    (on) => (poweredSince = on ? performance.now() : 0),
    { immediate: true },
  )
  watch(
    () => SEVERITY[annunciator(c.ann)],
    (now, before) => {
      if (now <= before || !poweredSince || performance.now() - poweredSince < POWER_SETTLE_MS) return
      if (!componentAlertEnabled(c.ann)) return
      const major = now === 2
      pushAlert({ id: `comp-${c.ann}-${now}`, level: major ? 'critical' : 'warning', message: `${c.name} ${major ? 'critical' : 'damaged'}` })
      if (alertEnabled('hit')) flash()
    },
  )
}

/** Teinte de toute l'interface pendant l'affichage d'une alerte. */
export const alertLevel = computed<AlertLevel | null>(() => shownAlert.value?.level ?? null)
