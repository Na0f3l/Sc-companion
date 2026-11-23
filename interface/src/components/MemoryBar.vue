<script setup lang="ts">
// Bande mémoire fixée en bas de l'écran (50 px) : mémoire de Star Citizen, variation sur 5 s,
// courbe des 5 dernières minutes, CPU / GPU en petit. La flèche déplie le détail.
import { computed, ref } from 'vue'
import { has, num, str } from '@/telemetry'
import Sparkline from './Sparkline.vue'

const open = ref(false)

const running = computed(() => has('sc.private_mb'))
const scGb = computed(() => num('sc.private_mb') / 1024)
const delta = computed(() => num('sc.delta5_mb'))
const commit = computed(() => num('sys.commit_pct'))
const leak = computed(() => str('sc.leak'))

// Seuils de l'outil PowerShell (reglages.json) : avertissement 65 %, critique 75 % d'engagement système
const WARN = 65
const CRIT = 75
const tone = computed(() => (leak.value === 'leak' || commit.value >= CRIT ? 'crit' : commit.value >= WARN || leak.value === 'rising' ? 'warn' : 'ok'))

const LEAK_LABEL: Record<string, string> = {
  startup: 'GAME LOADING',
  stable: 'STABLE',
  rising: 'RISING FAST',
  leak: 'LEAK',
  recovering: 'RECOVERING',
}
const fmtDelta = (mb: number) => `${mb >= 0 ? '+' : '−'}${Math.abs(mb) >= 1000 ? (Math.abs(mb) / 1024).toFixed(1) + ' GB' : Math.round(Math.abs(mb)) + ' MB'}`
const gb = (v: number) => v.toFixed(1)
</script>

<template>
  <footer class="membar" :class="[`is-${tone}`, { open }]">
    <!-- détail, déplié au-dessus de la bande -->
    <div v-if="open" class="detail">
      <div><span class="k">System commit</span><span class="v">{{ gb(num('sys.commit_gb')) }} / {{ gb(num('sys.commit_limit_gb')) }} GB · {{ Math.round(commit) }}%</span></div>
      <div><span class="k">RAM available</span><span class="v">{{ gb(num('sys.ram_avail_gb')) }} / {{ gb(num('sys.ram_total_gb')) }} GB</span></div>
      <div v-if="running"><span class="k">SC growth 15 s / 30 s</span><span class="v">{{ Math.round(num('sc.slope15')) }} / {{ Math.round(num('sc.slope30')) }} MB/s</span></div>
      <div v-if="leak === 'leak' || leak === 'recovering'"><span class="k">Leak growth</span><span class="v">{{ fmtDelta(num('sc.leak_growth_mb')) }}</span></div>
      <div v-if="has('sys.vram_used_gb')"><span class="k">VRAM</span><span class="v">{{ gb(num('sys.vram_used_gb')) }} GB used</span></div>
      <div><span class="k">Thresholds</span><span class="v">warn {{ WARN }}% · crit {{ CRIT }}% · leak 100 MB/s for 45 s</span></div>
    </div>

    <div class="band">
      <div class="main">
        <span class="lbl">SC RAM</span>
        <span class="big">{{ running ? gb(scGb) : '—' }}<small v-if="running">GB</small></span>
        <span v-if="running" class="delta" :class="{ up: delta > 50, down: delta < -50 }">{{ fmtDelta(delta) }}<small>/5s</small></span>
      </div>

      <Sparkline class="spark" :value="running ? scGb : commit" :size="300" :color="tone === 'crit' ? 'var(--red)' : tone === 'warn' ? 'var(--amber)' : 'var(--cyan)'" fill />

      <div class="side">
        <span class="state">{{ running ? LEAK_LABEL[leak] ?? '' : 'GAME OFF' }}</span>
        <button type="button" class="arrow" :aria-expanded="open" aria-label="Details" @click="open = !open">{{ open ? '▾' : '▴' }}</button>
      </div>

      <div class="small">
        <span>SYS {{ Math.round(commit) }}%</span>
        <span v-if="has('sys.cpu_pct')">CPU {{ Math.round(num('sys.cpu_pct')) }}%</span>
        <span v-if="has('sys.gpu_pct')">GPU {{ Math.round(num('sys.gpu_pct')) }}%<template v-if="has('sys.gpu_temp')"> · {{ num('sys.gpu_temp') }}°C</template></span>
      </div>
    </div>
  </footer>
</template>

<style scoped lang="scss">
.membar {
  --c: var(--cyan);
  position: fixed;
  right: 0;
  bottom: 0;
  left: 0;
  z-index: 50;
  border-top: 1px solid var(--line);
  background: var(--panel);
  padding-bottom: env(safe-area-inset-bottom, 0);

  &.is-warn {
    --c: var(--amber);
  }

  &.is-crit {
    --c: var(--red);
  }
}

// Bande de 50 px : ligne principale (valeur, courbe, état) + ligne fine CPU / GPU
.band {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  grid-template-rows: 32px 16px;
  align-items: center;
  column-gap: 14px;
  height: 50px;
  padding: 1px max(16px, env(safe-area-inset-right)) 1px max(16px, env(safe-area-inset-left));
}

.main {
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.lbl {
  @include label;
  font-size: 9px;
}

.big {
  @include numeric;
  color: var(--c);
  font-size: 22px;
  font-weight: 600;

  small {
    margin-left: 2px;
    font-size: 11px;
    color: var(--muted);
  }
}

.delta {
  @include numeric;
  color: var(--muted);
  font-size: 12px;

  small {
    margin-left: 2px;
    font-size: 9px;
  }

  &.up {
    color: var(--amber);
  }

  &.down {
    color: var(--cyan);
  }
}

.spark {
  --spark-h: 30px;
  min-width: 60px;
}

.side {
  display: flex;
  align-items: center;
  gap: 8px;
}

.state {
  @include numeric;
  color: var(--c);
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.1em;
}

.arrow {
  width: 24px;
  height: 22px;
  border: 1px solid var(--line);
  background: transparent;
  color: var(--cyan);
  font-size: 12px;
  line-height: 1;
  cursor: pointer;

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 1px;
  }
}

.small {
  @include numeric;
  grid-column: 1 / -1;
  display: flex;
  gap: 14px;
  color: var(--muted);
  font-size: 10px;
  letter-spacing: 0.06em;
}

.detail {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr));
  gap: 6px 20px;
  padding: 10px max(16px, env(safe-area-inset-right)) 8px max(16px, env(safe-area-inset-left));
  border-bottom: 1px solid var(--line);

  > div {
    display: flex;
    justify-content: space-between;
    gap: 10px;
    font-size: 12px;
  }

  .k {
    @include label;
    font-size: 10px;
  }

  .v {
    @include numeric;
    color: var(--text);
  }
}
</style>
