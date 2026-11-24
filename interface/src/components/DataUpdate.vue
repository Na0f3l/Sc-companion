<script setup lang="ts">
// Bouton « Update ship data » de l'en-tête, affiché seulement quand le wiki annonce une version du jeu
// plus récente que celle des données (le service vérifie au démarrage, voir service/src/shipdata.ts).
// Un clic : le service retélécharge le wiki et SPViewer (~10-20 s), puis l'interface recharge les données.
import { onMounted, ref } from 'vue'
import { demo } from '@/telemetry'
import { loadShips } from '@/ships'

interface Status {
  version: string | null
  latest: string | null
  updating: boolean
  error: string | null
}

const st = ref<Status | null>(null)
const busy = ref(false)
const failed = ref(false)

// « 4.10.3-LIVE.13165946 » → « 4.10.3 »
const short = (v: string | null) => v?.split('-')[0] ?? '?'

async function check(): Promise<void> {
  if (demo.value) return
  try {
    st.value = (await (await fetch('/data/status', { cache: 'no-store' })).json()) as Status
  } catch {
    st.value = null // service absent (hébergement statique) : pas de mise à jour possible
  }
}
// le service vérifie le wiki au démarrage, en arrière-plan : on redemande un peu plus tard s'il n'a pas encore répondu
onMounted(async () => {
  await check()
  if (st.value && !st.value.latest) setTimeout(check, 10000)
})

async function update(): Promise<void> {
  busy.value = true
  failed.value = false
  try {
    st.value = (await (await fetch('/data/update', { method: 'POST' })).json()) as Status
    failed.value = !!st.value.error
    if (!failed.value) await loadShips()
  } catch {
    failed.value = true
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <button
    v-if="st?.latest && st.latest !== st.version"
    type="button"
    class="test call"
    :disabled="busy"
    :title="failed ? `Update failed: ${st.error ?? 'service unreachable'}` : `Ship data is for ${short(st.version)}, the game is now ${short(st.latest)}`"
    @click="update"
  >
    {{ busy ? 'Updating ship data…' : failed ? 'Update failed · retry' : `Update ship data (${short(st.latest)})` }}
  </button>
</template>

<style scoped lang="scss">
// même apparence que les boutons de l'en-tête (mis en avant, comme « Exit preview »)
.test {
  padding: 5px 10px;
  border: 1px solid var(--amber);
  background: var(--panel);
  color: var(--amber);
  font: 500 11px var(--font-ui);
  letter-spacing: 0.08em;
  text-transform: uppercase;
  cursor: pointer;

  &:disabled {
    opacity: 0.6;
    cursor: progress;
  }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 1px;
  }
}
</style>
