// Réglages de l'utilisateur, mémorisés dans le navigateur (par appareil : PC et téléphone ont chacun les leurs).
// Pour ajouter un réglage : un champ dans DEFAULTS, puis une ligne dans le menu (components/AppMenu.vue).
import { reactive, watch } from 'vue'

/** Groupes d'alertes activables / désactivables dans le menu. */
export const ALERT_GROUPS = [
  { key: 'hit', label: 'Hit flash' },
  { key: 'crash', label: 'Crash / ground proximity' },
  { key: 'collision', label: 'Collision / obstacle' },
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
  { key: 'radr', label: 'Radar' },
  { key: 'shld', label: 'Shields' },
] as const
export type ComponentKey = (typeof COMPONENT_ALERTS)[number]['key']

interface Settings {
  alerts: Record<AlertGroup, boolean>
  components: Record<ComponentKey, boolean>
}

const DEFAULTS: Settings = {
  alerts: Object.fromEntries(ALERT_GROUPS.map((g) => [g.key, true])) as Record<AlertGroup, boolean>,
  components: Object.fromEntries(COMPONENT_ALERTS.map((c) => [c.key, true])) as Record<ComponentKey, boolean>,
}

const KEY = 'sc-companion.settings'

// Fusion avec les valeurs par défaut : un réglage ajouté plus tard prend sa valeur par défaut
function load(): Settings {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) ?? '{}') as Partial<Settings>
    return {
      ...DEFAULTS,
      ...saved,
      alerts: { ...DEFAULTS.alerts, ...saved.alerts },
      components: { ...DEFAULTS.components, ...saved.components },
    }
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
export const componentAlertEnabled = (c: ComponentKey): boolean => settings.alerts.components && settings.components[c]
