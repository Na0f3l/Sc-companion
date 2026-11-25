// Réglages de l'utilisateur, mémorisés dans le navigateur (par appareil : PC et téléphone ont chacun les leurs).
// Pour ajouter un réglage : un champ dans DEFAULTS, puis une ligne dans le menu (components/AppMenu.vue).
import { reactive, watch } from 'vue'

/** Groupes d'alertes activables / désactivables dans le menu. */
export const ALERT_GROUPS = [
  { key: 'hit', label: 'Hit flash', silent: true }, // flash seul, sans son
  { key: 'crash', label: 'Crash / ground proximity' },
  { key: 'collision', label: 'Collision / proximity' },
  { key: 'components', label: 'Component damaged' },
  { key: 'radarLock', label: 'Radar lock' },
  { key: 'missile', label: 'Missile lock / launch' },
  { key: 'health', label: 'Critical health' },
  { key: 'hunger', label: 'Hunger' },
  { key: 'thirst', label: 'Thirst' },
  { key: 'bodyTemp', label: 'Body temperature' },
  { key: 'ramLeak', label: 'RAM leak' },
  { key: 'memory', label: 'Memory high / critical' },
] as const
export type AlertGroup = (typeof ALERT_GROUPS)[number]['key']

/** Composants surveillés par l'alerte « Component damaged », activables un par un (clé = voyant du jeu). */
export const COMPONENT_ALERTS = [
  { key: 'pwr', label: 'Power plant' },
  { key: 'thr', label: 'Thrusters' },
  { key: 'wpn', label: 'Weapons' },
  { key: 'cool', label: 'Coolers' },
  { key: 'shld', label: 'Shields' },
] as const
export type ComponentKey = (typeof COMPONENT_ALERTS)[number]['key']

interface Settings {
  alerts: Record<AlertGroup, boolean>
  sound: Record<AlertGroup, boolean> // son de chaque alerte, indépendant de son affichage
  components: Record<ComponentKey, boolean>
  keepAwake: boolean // garder l'écran allumé (wakelock.ts)
  acePilot: boolean // alertes de vol bien plus tolérantes à la prise de risque (crash.ts, alerts.ts)
  ram: RamSettings // seuils des alertes mémoire (panneau de la bande RAM, MemoryBar.vue)
  migrations: string[] // changements de valeur par défaut déjà appliqués à ces réglages (voir load)
}

/** Seuils des alertes mémoire. Engagement système en % de la limite ; jeu en Go (0 = pas d'alerte). */
export interface RamSettings {
  warnPct: number
  critPct: number
  gameGb: number
}
export const RAM_DEFAULTS: RamSettings = { warnPct: 65, critPct: 75, gameGb: 0 }

const DEFAULTS: Settings = {
  alerts: Object.fromEntries(ALERT_GROUPS.map((g) => [g.key, true])) as Record<AlertGroup, boolean>,
  sound: Object.fromEntries(ALERT_GROUPS.map((g) => [g.key, true])) as Record<AlertGroup, boolean>,
  // propulseurs décochés : le jeu les signale « endommagés » à chaque saut quantique (bug du jeu, 2026-11-25)
  components: Object.fromEntries(COMPONENT_ALERTS.map((c) => [c.key, c.key !== 'thr'])) as Record<ComponentKey, boolean>,
  // activé d'office sur écran tactile (téléphone, tablette) ; sur PC l'écran sert déjà au jeu
  keepAwake: window.matchMedia('(pointer: coarse)').matches,
  acePilot: false,
  ram: { ...RAM_DEFAULTS },
  migrations: [],
}

// Nouvelles valeurs par défaut à appliquer UNE fois aux réglages déjà enregistrés (l'utilisateur peut ensuite
// les changer à nouveau) : sans ça, un réglage déjà mémorisé garde son ancienne valeur.
const MIGRATIONS: Record<string, (s: Settings) => void> = {
  'thr-off': (s) => (s.components.thr = false), // propulseurs : faux « endommagés » en saut quantique
}

const KEY = 'sc-companion.settings'

// Fusion avec les valeurs par défaut : un réglage ajouté plus tard prend sa valeur par défaut
function load(): Settings {
  try {
    const raw = localStorage.getItem(KEY)
    const saved = JSON.parse(raw ?? '{}') as Partial<Settings>
    const s: Settings = {
      ...DEFAULTS,
      ...saved,
      alerts: { ...DEFAULTS.alerts, ...saved.alerts },
      sound: { ...DEFAULTS.sound, ...saved.sound },
      components: { ...DEFAULTS.components, ...saved.components },
      ram: { ...DEFAULTS.ram, ...saved.ram },
      migrations: [...(saved.migrations ?? [])],
    }
    for (const [name, apply] of Object.entries(MIGRATIONS)) {
      if (s.migrations.includes(name)) continue
      if (raw) apply(s) // réglages neufs : les valeurs par défaut sont déjà les bonnes
      s.migrations.push(name)
    }
    return s
  } catch {
    return structuredClone(DEFAULTS)
  }
}

export const settings = reactive(load())

watch(
  settings,
  (s) => {
    try {
      localStorage.setItem(KEY, JSON.stringify(s))
    } catch {
      /* stockage indisponible : réglages gardés le temps de la session */
    }
  },
  { deep: true },
)

export const alertEnabled = (g: AlertGroup): boolean => settings.alerts[g]
export const alertSoundEnabled = (g: AlertGroup): boolean => settings.sound[g]
export const componentAlertEnabled = (c: ComponentKey): boolean => settings.alerts.components && settings.components[c]
