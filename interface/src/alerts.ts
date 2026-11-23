// Système d'alertes.
//
// Une alerte = une règle : un identifiant, un niveau, un message et une condition calculée
// à partir de la télémétrie. Pour en ajouter une, il suffit d'ajouter une ligne dans RULES.
//
// Vue recalcule les conditions automatiquement quand les champs qu'elles lisent changent.
import { computed, reactive, ref, watch } from 'vue'
import { VEH, str } from './telemetry'

export type AlertLevel = 'critical' | 'warning'

export interface AlertRule {
  id: string
  level: AlertLevel
  message: string
  active: () => boolean
}

// Alerte de test, déclenchée à la main depuis l'en-tête
export const testAlert = ref(false)

const RULES: AlertRule[] = [
  { id: 'test', level: 'critical', message: 'Crash imminent', active: () => testAlert.value },
  // voyant MISL en rouge : un missile est verrouillé sur le vaisseau
  { id: 'missile', level: 'critical', message: 'Missile verrouillé', active: () => str(`${VEH}annunciators.misl`) === 'ANNUNCIATOR_STATE_MAJOR_ON' },
]

/** Alertes dont la condition est vraie, dans l'ordre de priorité de RULES. */
export const activeAlerts = computed(() => RULES.filter((r) => r.active()))

// Alertes masquées par l'utilisateur. Une alerte qui disparaît puis revient s'affiche de nouveau.
const acknowledged = reactive(new Set<string>())
watch(activeAlerts, (list) => {
  for (const id of acknowledged) if (!list.some((r) => r.id === id)) acknowledged.delete(id)
})

/** Alerte affichée en plein écran (la plus prioritaire non masquée). */
export const shownAlert = computed(() => activeAlerts.value.find((r) => !acknowledged.has(r.id)) ?? null)

/** Niveau global, pour teinter toute l'interface. */
export const alertLevel = computed<AlertLevel | null>(() => {
  if (activeAlerts.value.some((r) => r.level === 'critical')) return 'critical'
  return activeAlerts.value.length ? 'warning' : null
})

export function acknowledge(id: string): void {
  acknowledged.add(id)
}
