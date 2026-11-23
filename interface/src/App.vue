<script setup lang="ts">
// Page de test de l'étape 1 : les curseurs modifient un objet réactif, les barres se mettent à jour toutes seules.
import { reactive } from 'vue'
import MfdPanel from './components/MfdPanel.vue'
import SegBar from './components/SegBar.vue'

// reactive : Vue surveille chaque propriété ; toute modification met à jour ce qui l'affiche.
const v = reactive({ h2: 0.82, boost: 1, g: 0.25, health: 0.66 })
const sliders = ['h2', 'boost', 'g', 'health'] as const
</script>

<template>
  <main class="page">
    <h1>SC COMPANION <small>étape 1 · composants</small></h1>

    <div class="grid">
      <MfdPanel title="Propulsion" source="fuel · boost · g_meter" tab="PROPULSION">
        <div class="bars">
          <div class="bar">
            <span class="num">{{ Math.round(v.h2 * 100) }} %</span>
            <SegBar :value="v.h2" :segments="12" vertical />
            <span class="lbl">H₂</span>
          </div>
          <div class="bar">
            <span class="num">{{ Math.round(v.boost * 100) }} %</span>
            <SegBar :value="v.boost" :segments="12" vertical />
            <span class="lbl">Boost</span>
          </div>
          <div class="bar">
            <span class="num">{{ (v.g * 9.3).toFixed(1) }}</span>
            <SegBar :value="v.g" :segments="12" vertical alert="high" />
            <span class="lbl">Charge G</span>
          </div>
        </div>
      </MfdPanel>

      <MfdPanel title="Pilote" source="actor.vitals" tab="ÉQUIPAGE">
        <div class="row">
          <span class="lbl">Santé</span><span class="num big">{{ Math.round(v.health * 100) }}</span>
        </div>
        <SegBar :value="v.health" :segments="20" />
      </MfdPanel>

      <MfdPanel title="Test" tab="RÉGLAGES">
        <label v-for="key in sliders" :key="key" class="slider">
          <span class="lbl">{{ key }}</span>
          <!-- v-model.number : relie le curseur à la valeur, dans les deux sens -->
          <input v-model.number="v[key]" type="range" min="0" max="1" step="0.01" />
        </label>
      </MfdPanel>
    </div>
  </main>
</template>

<style scoped lang="scss">
.page {
  max-width: 1180px;
  margin: 0 auto;
  padding: 20px max(16px, env(safe-area-inset-right)) 32px max(16px, env(safe-area-inset-left));
}

h1 {
  @include numeric;
  margin: 0 0 18px;
  color: var(--cyan);
  font-size: 15px;
  letter-spacing: 0.18em;

  small {
    @include label;
    margin-left: 8px;
  }
}

.grid {
  display: grid;
  gap: 14px;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 270px), 1fr));
}

.bars {
  display: flex;
  justify-content: space-around;
  align-items: flex-end;
}

.bar {
  display: grid;
  justify-items: center;
  gap: 6px;
}

.row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
}

.lbl {
  @include label;
}

.num {
  @include numeric;
}

.big {
  font-size: 40px;
  font-weight: 600;
  color: var(--cyan);
}

.slider {
  display: grid;
  grid-template-columns: 70px 1fr;
  align-items: center;
  gap: 10px;

  input {
    accent-color: var(--cyan);
  }
}
</style>
