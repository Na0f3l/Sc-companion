// Alerte crash au sol : distance d'arrêt du vaisseau comparée à la hauteur au-dessus du sol.
//
// Relevé sur capture (Constellation Mk V, 2026-11-24) :
//  - l'altitude radar n'est réelle que sous ~500 m (premières valeurs vues : 435 et 489 m) ;
//  - au-delà, le jeu renvoie à la place l'altitude (au-dessus du niveau zéro de la planète), à 1-3 m près :
//    ce n'est PAS la hauteur au-dessus du sol (sol réel à 980 et 1450 m d'altitude sur la capture) ;
//  - l'ancien calcul (altitude radar ÷ vitesse de descente) prenait donc l'altitude pour la hauteur et
//    prévenait 2 à 3 s avant l'impact.
//
// Calcul :
//  - distance d'arrêt = vitesse de descente × temps de réaction + v² / (2 × décélération) ;
//  - décélération = poussée verticale du vaisseau (G « Up » de SPViewer, voir ships.ts) moins la gravité,
//    comptée à 1 g (la plupart des planètes) : un Gladius freine à ~8,9 g, une Mk V à ~1 g seulement ;
//  - radar valide : « Crash imminent » (rouge) quand la distance d'arrêt dépasse la hauteur ;
//  - radar hors de portée : « Descent too fast » (orange) quand la distance d'arrêt dépasse la hauteur estimée :
//    altitude − sol le plus haut possible, soit le sol vu au dernier passage sous 500 m + 300 m de relief,
//    soit TERRAIN_MAX si on ne l'a pas encore vu. Jamais moins que la portée du radar (450 m).
//    Rejoué sur les captures Mk V : orange 15 et 22 s avant l'impact, rouge à l'apparition du sol.
// Train sorti ou vaisseau posé : aucune alerte (atterrissage voulu).
import { computed } from 'vue'
import { FLI, NO_VALUE, VEH, bool, has, num, str } from './telemetry'
import { shipInfo } from './ships'
import { settings } from './settings'

const G = 9.81
const PLANET_G = 1 // gravité supposée (prudent : les lunes sont plus faibles)
const DEFAULT_UP_G = 3 // vaisseau inconnu de ships.json
const RADAR_MAX = 600 // m : au-dessus, une altitude radar égale à l'altitude est la valeur de repli du jeu
const RADAR_RANGE = 450 // m : hauteur à laquelle le sol apparaît au radar (prudent)
const MIN_SINK = 10 // m/s : en dessous, approche ou manœuvre près du sol, pas une chute
const SKIM_SPEED = 100 // m/s : rase-mottes rapide, alerte quand le sol est à moins de skimLead s

/**
 * Réglages selon le profil. « Ace pilot » (case du menu) : alertes bien plus tolérantes à la prise de risque.
 *  - reaction : réaction du pilote + montée en poussée (annulée si le pilote freine déjà, voir trackBraking) ;
 *  - boost : décélération calculée avec le boost (G « Up » boostés) ;
 *  - terrainMax : altitude du sol supposée tant qu'on ne l'a pas vu (à ajuster selon les planètes) ;
 *  - terrainMargin : relief possible au-dessus du sol vu en dernier ;
 *  - skimLead : préavis de l'alerte rase-mottes (s) ;
 *  - blindSink : « Descent too fast » même quand le sol n'a jamais été vu (hauteur supposée via terrainMax).
 * Réglé après essais en Mk V et Gladius (2026-11-24) : normal un peu plus prudent, Ace bien plus tolérant.
 */
const PROFILES = {
  normal: { reaction: 2, boost: false, terrainMax: 3000, terrainMargin: 400, skimLead: 2.5, blindSink: true },
  ace: { reaction: 0.3, boost: true, terrainMax: 1000, terrainMargin: 50, skimLead: 0.8, blindSink: false },
}
const profile = () => (settings.acePilot ? PROFILES.ace : PROFILES.normal)

// Train sorti ou en cours de sortie. Attention : tous les états contiennent « DEPLOYMENT »
// (VEHICLE_COMPONENT_DEPLOYMENT_STATE_RETRACTED…) : on teste la fin du nom.
export const gearDown = () => /_(DEPLOYED|DEPLOYING)$/.test(str(`${VEH}flight.state.gear`))

/** Hauteur réelle au-dessus du sol (radar), ou null hors de portée / hors planète. */
export function radarHeight(): number | null {
  const k = `${FLI}radar_altitude`
  if (!has(k)) return null
  const r = num(k)
  if (r > NO_VALUE) return null
  if (r > RADAR_MAX && has(`${FLI}altitude`) && Math.abs(r - num(`${FLI}altitude`)) < 10) return null
  return r
}

/** Décélération verticale disponible (m/s²) : poussée « Up » du vaisseau moins la gravité. */
export function brakeAccel(): number {
  const ship = shipInfo(str(`${VEH}class_name`))
  const up = (profile().boost ? ship?.gBoost?.[2] : undefined) ?? ship?.g?.[2] ?? DEFAULT_UP_G
  return Math.max(0.3, up - PLANET_G) * G
}

/** Distance (m) pour annuler une vitesse de descente `sink` (m/s), réaction comprise sauf si on freine déjà. */
export function stopDistance(sink: number): number {
  const reaction = braking ? 0 : profile().reaction
  return sink * reaction + (sink * sink) / (2 * brakeAccel())
}

const sinkRate = () => -num(`${FLI}vertical_speed_indicator`) // positive en descente

/** Temps avant impact (s) au rythme actuel, radar valide et en descente seulement. */
export function timeToImpact(): number | null {
  const h = radarHeight()
  const sink = sinkRate()
  return h === null || sink <= 0 ? null : h / sink
}

// Altitude du sol vue au dernier passage à portée du radar (oubliée hors atmosphère : autre planète)
let groundAlt: number | null = null
// Vitesse de rapprochement du sol (m/s, lissée) : la hauteur radar qui baisse, ce qui inclut le relief qui
// monte devant le vaisseau (colline survolée vite), pas seulement la descente
let prevH: { h: number; t: number } | null = null
let closing = 0
// Freinage en cours : la descente ralentit nettement (décélération lissée > 30 % du maximum du vaisseau).
// Le pilote a déjà réagi : pas de temps de réaction dans la distance d'arrêt (évite les alertes pendant
// une descente rapide mais maîtrisée).
let prevSink: { v: number; t: number } | null = null
let decel = 0
let braking = false
function trackBraking(): void {
  const t = performance.now()
  const v = sinkRate()
  const dt = prevSink ? (t - prevSink.t) / 1000 : 0
  if (prevSink && dt > 0.05 && dt < 1) decel = decel * 0.7 + ((prevSink.v - v) / dt) * 0.3
  else if (!prevSink || dt >= 1) decel = 0
  if (!prevSink || dt > 0.05) prevSink = { v, t }
  braking = decel > 0.3 * brakeAccel()
}
// Dans l'atmosphère : la densité n'est pas nulle dans l'espace (0,01 relevé le 2026-11-25), d'où un vrai seuil
const inAtmosphere = () => num(`${FLI}atmospheric_density`) >= 0.05

function track(): void {
  trackBraking()
  if (!inAtmosphere()) groundAlt = null
  const h = radarHeight()
  if (h !== null && has(`${FLI}altitude`)) groundAlt = num(`${FLI}altitude`) - h
  const t = performance.now()
  if (h === null) {
    prevH = null
    closing = 0
    return
  }
  const dt = prevH ? (t - prevH.t) / 1000 : 0
  if (prevH && dt > 0.05 && dt < 1) closing = closing * 0.7 + ((prevH.h - h) / dt) * 0.3
  if (!prevH || dt > 0.05) prevH = { h, t }
}

export type CrashLevel = 'crash' | 'sink' | null

/**
 * Niveau d'alerte, avec hystérésis (retombe quand la marge dépasse 25 % ou la descente ralentit de moitié).
 * Une seule instance (crash) : l'état est partagé par les deux règles d'alertes et l'affichage.
 */
function crashLevel(): () => CrashLevel {
  let level: CrashLevel = null
  return () => {
    track()
    const sink = sinkRate()
    if (gearDown() || bool(`${VEH}flight.state.is_landed`) || !has(`${FLI}vertical_speed_indicator`)) return (level = null)
    const minSink = level ? MIN_SINK / 2 : MIN_SINK
    const k = level ? 1.25 : 1 // hystérésis : il faut 25 % de marge pour que l'alerte retombe
    const need = stopDistance(sink) * k
    const h = radarHeight()
    let next: CrashLevel = null
    if (sink > minSink) {
      if (h !== null) next = need > h ? 'crash' : null
      else if (inAtmosphere() && (groundAlt !== null || profile().blindSink)) {
        const ground = groundAlt !== null ? groundAlt + profile().terrainMargin : profile().terrainMax
        const room = Math.max(num(`${FLI}altitude`) - ground, RADAR_RANGE)
        next = need > room ? 'sink' : null
      }
    }
    // une fois rouge, on ne redescend pas en orange pendant la même chute (le radar peut décrocher un instant)
    level = level === 'crash' && next === 'sink' ? 'crash' : next
    return level
  }
}
// computed : évalué une seule fois par changement de télémétrie (l'hystérésis dépend de l'appel précédent)
export const crash = computed(crashLevel())

/**
 * Rase-mottes : vitesse de descente faible (sous le seuil de l'alerte crash) mais vaisseau rapide (> 100 m/s) :
 * « Pull up » (orange) quand le sol sera atteint dans moins de skimLead s au rythme de rapprochement actuel
 * (descente, ou relief qui monte). Radar valide uniquement.
 */
export const skim = computed(() => {
  if (crash.value) return false // l'alerte crash est déjà là (et met à jour le rapprochement)
  const h = radarHeight()
  if (h === null || gearDown() || bool(`${VEH}flight.state.is_landed`) || num(`${FLI}speed`) < SKIM_SPEED) return false
  const c = Math.max(sinkRate(), closing)
  return c > 3 && h / c < profile().skimLead
})
