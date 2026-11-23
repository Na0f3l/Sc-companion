// Système d'alertes.
//
// Une alerte = une règle : un identifiant, un niveau, un message et une condition calculée
// à partir de la télémétrie. Pour en ajouter une, il suffit d'ajouter une ligne dans RULES.
//
// Aucune interaction : quand une condition DEVIENT vraie, l'alerte s'affiche 3 s puis disparaît seule.
// Si plusieurs se déclenchent en même temps, elles passent l'une après l'autre.
// Une alerte qui reste vraie ne se réaffiche pas ; si elle redevient fausse puis vraie, oui.
import { computed, ref, watch } from 'vue'
import { VEH, str } from './telemetry'

export type AlertLevel = 'critical' | 'warning'

export interface AlertRule {
  id: string
  level: AlertLevel
  message: string
  active: () => boolean
}

export const DISPLAY_MS = 3000

// Alerte de test : déclenchée par le bouton de l'en-tête, retombe d'elle-même
const testAlert = ref(false)
export function triggerTest(): void {
  testAlert.value = true
  setTimeout(() => (testAlert.value = false), DISPLAY_MS + 200)
}

const RULES: AlertRule[] = [
  { id: 'test', level: 'critical', message: 'Crash imminent', active: () => testAlert.value },
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
  if (shownAlert.value) setTimeout(showNext, DISPLAY_MS)
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
