// Réglages de l'utilisateur, mémorisés dans le navigateur (par appareil : PC et téléphone ont chacun les leurs).
// Pour ajouter un réglage : un champ dans DEFAULTS, puis une ligne dans le menu (components/AppMenu.vue).
import { reactive, watch } from 'vue'

/** Groupes d'alertes activables / désactivables dans le menu. */
export const ALERT_GROUPS = [
  { key: 'hit', label: 'Hit flash' },
  { key: 'crash', label: 'Crash / ground proximity' },
  { key: 'collision', label: 'Collision / obstacle' },
  { key: 'components', label: 'Component damaged' },
  { key: 'missile', label: 'Missile lock' },
  { key: 'health', label: 'Critical health' },
  { key: 'hunger', label: 'Hunger' },
  { key: 'thirst', label: 'Thirst' },
  { key: 'bodyTemp', label: 'Body temperature' },
  { key: 'ramLeak', label: 'RAM leak' },
  { key: 'memory', label: 'Memory high / critical' },
] as const
export type AlertGroup = (typeof ALERT_GROUPS)[number]['key']

interface Settings {
  alerts: Record<AlertGroup, boolean>
}

const DEFAULTS: Settings = {
  alerts: Object.fromEntries(ALERT_GROUPS.map((g) => [g.key, true])) as Record<AlertGroup, boolean>,
}

const KEY = 'sc-companion.settings'

// Fusion avec les valeurs par défaut : un réglage ajouté plus tard prend sa valeur par défaut
function load(): Settings {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) ?? '{}') as Partial<Settings>
    return { ...DEFAULTS, ...saved, alerts: { ...DEFAULTS.alerts, ...saved.alerts } }
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
