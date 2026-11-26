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
import { ACT, FLI, VEH, annunciator, annunciatorFlashing, bool, has, num, str } from './telemetry'
import { playAlert } from './sound'
import { type AlertGroup, alertEnabled, alertSoundEnabled, componentAlertEnabled, settings } from './settings'
import { flash } from './hit'
import { crash, gearDown, skim } from './crash'

export type AlertLevel = 'critical' | 'warning' | 'info'

export interface AlertItem {
  id: string
  level: AlertLevel
  message: string
  /** groupe du menu : décide si l'alerte sonne (sans groupe, les tests, elle sonne toujours) */
  group?: AlertGroup
}

export interface AlertRule extends AlertItem {
  group: AlertGroup // case du menu qui l'active / la désactive
  active: () => boolean
  /** Réaffichée toutes les repeatMs tant qu'elle reste vraie (danger qui dure : crash) ; sinon une seule fois */
  repeatMs?: number
}

// durée d'affichage d'une alerte : 1,5 s (3 battements de 0,5 s pour le rouge, voir AlertOverlay) ;
// les vertes (bonne nouvelle) sont brèves
export const DISPLAY_MS: Record<AlertLevel, number> = { critical: 1500, warning: 1500, info: 900 }

// Alertes de test : déclenchées depuis le menu « Test » de l'en-tête, affichées une fois.
// Mêmes messages et niveaux que les vraies alertes, pour juger du rendu et du son.
export const TESTS = {
  info: { label: 'Info alert', item: { id: 'test-info', level: 'info', message: 'Radar unlocked' } },
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
// Faux si la jauge n'est pas reçue du tout (jeu fermé, hors ligne). Mais le jeu omet les valeurs nulles :
// valeur absente avec son maximum présent = 0 %.
// Ne s'allume qu'en DESCENDANT sous le seuil : une valeur qui remonte en restant dessous (ranimé après un coma,
// on mange / boit un peu) ne déclenche rien. La dernière valeur connue est gardée même si le champ disparaît
// un instant (chargement, réapparition).
function lowVital(name: string, on = 0.25, off = 0.3): () => boolean {
  let low = false
  let prev: number | null = null
  return () => {
    const k = `${ACT}vitals.${name}.current`
    // le jeu n'envoie pas les valeurs nulles : valeur absente mais maximum présent = 0 (ex. vie à 0 dans le coma)
    if (!has(k) && !has(`${ACT}vitals.${name}.max`)) return (low = false)
    // santé sur 100 comme dans le jeu (la vie max baisse avec les blessures) ; faim et soif sur leur maximum
    const ratio = num(k) / (name === 'health' ? 100 : num(`${ACT}vitals.${name}.max`, 100) || 100)
    const falling = prev === null || ratio < prev
    low = low ? ratio < off : ratio < on && falling
    prev = ratio
    return low
  }
}

// Seuil haut avec hystérésis : vrai au-dessus de on(), ne redevient faux qu'en dessous de on() − margin.
// Seuil relu à chaque appel : un réglage modifié s'applique tout de suite. Faux si la valeur n'est pas reçue
// ou si le seuil vaut 0 (alerte coupée). scale : conversion d'unité (Mo → Go).
function above(key: string, on: () => number, margin: number, scale = 1): () => boolean {
  let high = false
  return () => {
    const limit = on()
    if (!has(key) || limit <= 0) return (high = false)
    const v = num(key) * scale
    high = high ? v > limit - margin : v > limit
    return high
  }
}

// ---- Vol ----

/**
 * Collision : voyant PROX du vaisseau au rouge, sauf en manœuvre de décollage / atterrissage :
 * train sorti, ou vitesse sous `minSpeed` (le voyant s'allume normalement près des hangars et des pads).
 */
const proximity = (minSpeed: number) =>
  annunciator('prox') === 'major' && !gearDown() && num(`${FLI}speed`) >= minSpeed
// PROX rouge (dès 60 m/s, train rentré) : « Collision imminent » (rouge), Ace pilot compris (choix de l'utilisateur,
// 2026-11-25). Le voyant orange seul s'allume tout le temps près du sol : ignoré. Un posé (train sorti, moins de
// 60 m/s, posé) reste silencieux. Pendant une alerte crash, le sol est déjà signalé : pas de doublon PROX.
const OBSTACLE_MIN_SPEED = 60 // m/s
const proxQuiet = () => bool(`${VEH}flight.state.is_landed`) || crash.value !== null

// Niveaux :
//  - critical : alerte importante, rouge, avec son
//  - warning  : alerte secondaire, orange, son discret
//  - info     : bonne nouvelle, verte, brève, sans clignotement (ponctuelles, via pushAlert)
// L'ordre fixe la priorité quand plusieurs alertes arrivent ensemble.
const RULES: AlertRule[] = [
  // Crash au sol : distance d'arrêt du vaisseau contre hauteur au-dessus du sol (voir crash.ts)
  { id: 'crash', group: 'crash', level: 'critical', message: 'Crash imminent', active: () => crash.value === 'crash', repeatMs: 3000 },
  { id: 'collision', group: 'collision', level: 'critical', message: 'Collision imminent', active: () => proximity(OBSTACLE_MIN_SPEED) && !proxQuiet() },
  { id: 'sink', group: 'crash', level: 'warning', message: 'Descent too fast', active: () => crash.value === 'sink', repeatMs: 6000 },
  { id: 'skim', group: 'crash', level: 'warning', message: 'Pull up', active: () => skim.value, repeatMs: 3000 },
  { id: 'health', group: 'health', level: 'critical', message: 'Critical health', active: lowVital('health') },
  { id: 'thirst', group: 'thirst', level: 'warning', message: 'Dehydrated', active: lowVital('thirst') },
  { id: 'hunger', group: 'hunger', level: 'warning', message: 'Starving', active: lowVital('hunger') },
  // voyant MISL en rouge : un missile est verrouillé sur le vaisseau
  // Mémoire : fuite détectée par le service ; engagement système et mémoire du jeu, seuils réglables dans le
  // panneau de la bande RAM (par défaut ceux de l'outil PowerShell : 65 % / 75 %, alerte jeu coupée)
  { id: 'ram-leak', group: 'ramLeak', level: 'critical', message: 'RAM leak detected', active: () => str('sc.leak') === 'leak' },
  { id: 'mem-crit', group: 'memory', level: 'critical', message: 'Memory critical', active: above('sys.commit_pct', () => settings.ram.critPct, 3) },
  { id: 'mem-high', group: 'memory', level: 'warning', message: 'Memory high', active: above('sys.commit_pct', () => settings.ram.warnPct, 3) },
  { id: 'game-ram', group: 'memory', level: 'warning', message: 'Game RAM high', active: above('sc.private_mb', () => settings.ram.gameGb, 0.5, 1 / 1024) },
  // Menaces, relevées en test réel (2026-11-24) : RADR orange ou rouge = verrouillé au radar (le rouge,
  // verrouillage plus menaçant, n'est PAS un radar endommagé) ; MISL rouge fixe = missile verrouillé ;
  // MISL rouge clignotant = missile lancé. Le RADR n'est donc jamais traité comme un dégât de composant.
  // RADR orange ou rouge : toujours une alerte orange (choix de l'utilisateur : un verrouillage ne mérite pas le rouge)
  { id: 'radar-lock', group: 'radarLock', level: 'warning', message: 'Radar lock', active: () => annunciator('radr') !== 'off' && annunciator('radr') !== 'nominal' },
  { id: 'missile-lock', group: 'missile', level: 'warning', message: 'Missile lock', active: () => annunciator('misl') === 'major' && !annunciatorFlashing('misl') },
  { id: 'missile-launch', group: 'missile', level: 'critical', message: 'Missile incoming', active: () => annunciator('misl') === 'major' && annunciatorFlashing('misl') },
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

const lastShown = new Map<string, number>() // id → instant du dernier affichage (pour repeatMs)

function showNext(): void {
  // une alerte de règle qui n'est plus vraie quand vient son tour est abandonnée (danger passé pendant l'attente) ;
  // les alertes ponctuelles (pushAlert) passent toujours
  while (queue.length && RULES.includes(queue[0] as AlertRule) && !activeAlerts.value.includes(queue[0] as AlertRule)) queue.shift()
  shownAlert.value = queue.shift() ?? null
  if (shownAlert.value) {
    lastShown.set(shownAlert.value.id, performance.now())
    const g = shownAlert.value.group
    if (!g || alertSoundEnabled(g)) playAlert(shownAlert.value.level)
    setTimeout(showNext, DISPLAY_MS[shownAlert.value.level])
  }
}

// Répétition : une alerte « repeatMs » toujours vraie revient dans la file quand son délai est écoulé
let repeatTimer: ReturnType<typeof setInterval> | undefined
function repeatTick(): void {
  const t = performance.now()
  for (const rule of activeAlerts.value) {
    if (!rule.repeatMs || queue.includes(rule) || shownAlert.value === rule) continue
    if (settings.acePilot && rule.level === 'warning') continue // Ace pilot : les orange ne se répètent pas
    if (t - (lastShown.get(rule.id) ?? 0) >= rule.repeatMs) queue.push(rule)
  }
  if (!shownAlert.value) showNext()
}

// Détection des fronts montants : une règle présente maintenant et absente juste avant.
// Délai de grâce : une règle affichée il y a moins de COOLDOWN_MS ne revient pas sur un nouveau front
// (le voyant PROX, par exemple, clignote entre orange et rouge en rase-mottes).
const COOLDOWN_MS = 8000
watch(
  activeAlerts,
  (now, before = []) => {
    const t = performance.now()
    for (const rule of now) {
      if (before.includes(rule) || queue.includes(rule) || shownAlert.value === rule) continue
      if (t - (lastShown.get(rule.id) ?? -Infinity) < COOLDOWN_MS) continue
      queue.push(rule)
    }
    if (!shownAlert.value) showNext()
    // minuterie seulement tant qu'une alerte à répétition est active : rien ne tourne le reste du temps
    const repeating = now.some((r) => r.repeatMs)
    if (repeating && !repeatTimer) repeatTimer = setInterval(repeatTick, 500)
    else if (!repeating && repeatTimer) {
      clearInterval(repeatTimer)
      repeatTimer = undefined
    }
  },
  { immediate: true },
)

// ---- Fin de verrouillage radar ---------------------------------------------------------
// RADR orange / rouge → normal : plus personne ne nous verrouille → alerte verte « Radar unlocked ».
// Seulement vers « normal » : un voyant qui s'éteint (vaisseau coupé, jeu fermé) n'est pas un délock.
watch(
  () => annunciator('radr'),
  (now, before) => {
    if (now === 'nominal' && (before === 'minor' || before === 'major') && alertEnabled('radarLock'))
      pushAlert({ id: 'radar-unlocked', group: 'radarLock', level: 'info', message: 'Radar unlocked' })
  },
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
      if (alertEnabled('bodyTemp')) pushAlert({ id: `body-hot-${hot}`, group: 'bodyTemp', level: crit ? 'critical' : 'warning', message: `${crit ? 'Hyperthermia' : 'Body temp high'} · ${hot}°C` })
    }

    const cold = Math.floor(t) + 1 // plus bas entier strictement passé en dessous
    if (cold <= COLD_WARN && cold < coldDone) {
      coldDone = cold
      const crit = cold <= COLD_CRIT
      if (alertEnabled('bodyTemp')) pushAlert({ id: `body-cold-${cold}`, group: 'bodyTemp', level: crit ? 'critical' : 'warning', message: `${crit ? 'Hypothermia' : 'Body temp low'} · ${cold}°C` })
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
      pushAlert({ id: `comp-${c.ann}-${now}`, group: 'components', level: major ? 'critical' : 'warning', message: `${c.name} ${major ? 'critical' : 'damaged'}` })
      if (alertEnabled('hit')) flash()
    },
  )
}

/** Teinte de toute l'interface pendant l'affichage d'une alerte. */
export const alertLevel = computed<AlertLevel | null>(() => shownAlert.value?.level ?? null)
