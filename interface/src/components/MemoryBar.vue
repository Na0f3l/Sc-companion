<script setup lang="ts">
// Bande mémoire fixée en bas de l'écran (50 px) : mémoire de Star Citizen, variation sur 5 s,
// courbe zoomable / déplaçable (5 min par défaut, 2 h au plus) avec, dessous, les événements du jeu (RamTimeline),
// CPU / GPU en petit.
// La flèche déplie le détail : mesures, puis réglage des seuils d'alerte (mémorisés par appareil, settings.ts).
import { computed, ref } from 'vue'
import { has, num, sendConfig, str } from '@/telemetry'
import NumberStepper from './NumberStepper.vue'
import { RAM_DEFAULTS, settings } from '@/settings'
import RamTimeline from './RamTimeline.vue'
import { canFullscreen, fullscreen, toggleFullscreen } from '@/wakelock'

const open = ref(false)

const running = computed(() => has('sc.private_mb'))
const scGb = computed(() => num('sc.private_mb') / 1024)
const delta = computed(() => num('sc.delta5_mb'))
const commit = computed(() => num('sys.commit_pct'))
const leak = computed(() => str('sc.leak'))

// Couleur de la bande : mêmes seuils que les alertes (réglables ci-dessous)
const ram = settings.ram
const gameHigh = computed(() => running.value && ram.gameGb > 0 && scGb.value > ram.gameGb)
const tone = computed(() =>
  leak.value === 'leak' || commit.value >= ram.critPct
    ? 'crit'
    : commit.value >= ram.warnPct || leak.value === 'rising' || gameHigh.value
      ? 'warn'
      : 'ok',
)
// Fuite : réglage commun à tous les écrans, gardé par le service (service/src/config.ts, mêmes valeurs par défaut)
const LEAK_DEFAULTS = { rate: 100, duration: 45 }
const leakRate = computed({ get: () => num('cfg.leak_rate', LEAK_DEFAULTS.rate), set: (v) => sendConfig('leakRate', v) })
const leakDuration = computed({ get: () => num('cfg.leak_duration', LEAK_DEFAULTS.duration), set: (v) => sendConfig('leakDuration', v) })

const isDefault = computed(
  () =>
    ram.warnPct === RAM_DEFAULTS.warnPct &&
    ram.critPct === RAM_DEFAULTS.critPct &&
    ram.gameGb === RAM_DEFAULTS.gameGb &&
    leakRate.value === LEAK_DEFAULTS.rate &&
    leakDuration.value === LEAK_DEFAULTS.duration,
)
function resetRam(): void {
  Object.assign(ram, RAM_DEFAULTS)
  leakRate.value = LEAK_DEFAULTS.rate
  leakDuration.value = LEAK_DEFAULTS.duration
}

const commitGb = computed(() => num('sys.commit_gb'))
const limitGb = computed(() => num('sys.commit_limit_gb'))
const ofLimit = (pct: number) => (limitGb.value * pct) / 100 // seuil en % → Go
const pctTone = computed(() => (commit.value >= ram.critPct ? 'crit' : commit.value >= ram.warnPct ? 'warn' : ''))
const leakTone = computed(() => (leak.value === 'leak' ? 'crit' : leak.value === 'rising' ? 'warn' : ''))

const LEAK_LABEL: Record<string, string> = {
  startup: 'GAME LOADING',
  stable: 'STABLE',
  rising: 'RISING FAST',
  leak: 'LEAK',
  recovering: 'RECOVERING',
}
const fmtDelta = (mb: number) => `${mb >= 0 ? '+' : '−'}${Math.abs(mb) >= 1000 ? (Math.abs(mb) / 1024).toFixed(1) + ' GB' : Math.round(Math.abs(mb)) + ' MB'}`
const gb = (v: number) => v.toFixed(1)
const fmtRate = (mbs: number) => `${mbs >= 0 ? '+' : '−'}${Math.round(Math.abs(mbs))} MB/s`
</script>

<template>
  <footer class="membar" :class="[`is-${tone}`, { open }]">
    <!-- détail, déplié au-dessus de la bande : 3 blocs (Windows, jeu, fuite), chacun avec sa valeur actuelle,
         une phrase qui dit pourquoi elle compte et ses seuils d'alerte (appliqués tout de suite, settings.ts) -->
    <div v-if="open" class="detail">
      <section class="blk">
        <h3>Windows memory <span class="now" :class="pctTone">{{ gb(commitGb) }} / {{ gb(limitGb) }} GB · {{ Math.round(commit) }}%</span></h3>
        <p class="why">Memory promised to all programs (RAM + page file). At 100 % Windows refuses more and the game crashes.</p>
        <div class="ctl">
          <label class="set">
            <span class="k warn">Warning at</span>
            <NumberStepper v-model="ram.warnPct" label="Windows memory warning" unit="%" :min="30" :max="ram.critPct - 1" />
            <span class="eq">= {{ Math.round(ofLimit(ram.warnPct)) }} GB</span>
          </label>
          <label class="set">
            <span class="k crit">Critical at</span>
            <NumberStepper v-model="ram.critPct" label="Windows memory critical" unit="%" :min="ram.warnPct + 1" :max="99" />
            <span class="eq">= {{ Math.round(ofLimit(ram.critPct)) }} GB</span>
          </label>
        </div>
        <p class="aside">Physical RAM free: {{ gb(num('sys.ram_avail_gb')) }} / {{ gb(num('sys.ram_total_gb')) }} GB<template v-if="has('sys.vram_used_gb')"> · GPU memory: {{ gb(num('sys.vram_used_gb')) }} GB</template></p>
      </section>

      <section class="blk">
        <h3>Star Citizen <span class="now" :class="{ warn: gameHigh }">{{ running ? `${gb(scGb)} GB` : 'not running' }}</span></h3>
        <p class="why">Memory used by the game alone. Above your physical RAM it spills to disk: stutters, then crash risk.</p>
        <div class="ctl">
          <label class="set">
            <span class="k warn">Warning above</span>
            <NumberStepper v-model="ram.gameGb" label="Star Citizen memory warning" unit="GB" :min="0" :max="128" />
            <span class="eq">{{ ram.gameGb ? '' : 'off (0 = off)' }}</span>
          </label>
        </div>
      </section>

      <section class="blk">
        <h3>Memory leak <span class="now" :class="leakTone">{{ running ? `${fmtRate(num('sc.slope15'))} now` : '—' }}</span></h3>
        <p class="why">How fast the game's memory grows. Loading screens spike briefly; a leak keeps climbing.</p>
        <div class="ctl">
          <label class="set">
            <span class="k crit">Critical above</span>
            <NumberStepper v-model="leakRate" label="Memory leak rate" unit="MB/s" :min="20" :max="1000" :step="10" />
            <span class="eq"></span>
          </label>
          <label class="set">
            <span class="k crit">Lasting</span>
            <NumberStepper v-model="leakDuration" label="Memory leak duration" unit="s" :min="10" :max="600" :step="5" />
            <span class="eq">ignored the first 3 min of a session</span>
          </label>
        </div>
        <p class="note">Shared by all your screens (PC and phone).</p>
        <p v-if="leak === 'leak' || leak === 'recovering'" class="aside">Grown {{ fmtDelta(num('sc.leak_growth_mb')) }} since the leak started</p>
      </section>

      <button type="button" class="reset" :disabled="isDefault" @click="resetRam">Reset defaults</button>
    </div>

    <div class="band">
      <div class="main">
        <span class="lbl">SC RAM</span>
        <span class="big">{{ running ? gb(scGb) : '—' }}<small v-if="running">GB</small></span>
        <span v-if="running" class="delta" :class="{ up: delta > 50, down: delta < -50 }">{{ fmtDelta(delta) }}<small>/5s</small></span>
      </div>

      <RamTimeline class="timeline" :value="running ? scGb : null" :color="tone === 'crit' ? 'var(--red)' : tone === 'warn' ? 'var(--amber)' : 'var(--cyan)'" />

      <div class="side">
        <span class="state">{{ running ? LEAK_LABEL[leak] ?? '' : 'GAME OFF' }}</span>
        <button type="button" class="arrow" :aria-expanded="open" aria-label="Details" @click="open = !open">{{ open ? '▾' : '▴' }}</button>
        <!-- plein écran, comme sur un lecteur vidéo : 4 coins vers l'extérieur (vers l'intérieur pour sortir) -->
        <button
          v-if="canFullscreen"
          type="button"
          class="arrow fs"
          :title="fullscreen ? 'Exit full screen' : 'Full screen'"
          :aria-label="fullscreen ? 'Exit full screen' : 'Full screen'"
          @click="toggleFullscreen"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path v-if="!fullscreen" d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5" />
            <path v-else d="M9 4v5H4M20 9h-5V4M15 20v-5h5M4 15h5v5" />
          </svg>
        </button>
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

// Bande de 50 px : ligne principale (valeur, courbe, état) + ligne fine : CPU / GPU à gauche, repères sous la courbe
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
  font-size: 11px; // à 9 px le R de « RAM » se lisait comme un H
  font-weight: 600;
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

// courbe + pictos : colonne du milieu, sur les deux lignes de la bande
.timeline {
  grid-row: 1 / 3;
  grid-column: 2;
  align-self: stretch;
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

// bouton plein écran : même cadre que la flèche du détail, picto dessiné
.fs {
  display: grid;
  place-items: center;
  padding: 0;

  svg {
    width: 14px;
    height: 14px;
    fill: none;
    stroke: currentColor;
    stroke-width: 2;
    stroke-linecap: square;
  }
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
  grid-row: 2;
  grid-column: 1;
  white-space: nowrap;
  display: flex;
  gap: 14px;
  color: var(--muted);
  font-size: 10px;
  letter-spacing: 0.06em;
}

// Détail : 3 blocs côte à côte sur PC, empilés si la place manque. Dans chaque bloc, un réglage = libellé,
// champ et équivalent collés ; l'espace sépare les réglages entre eux, pas un libellé de sa valeur.
.detail {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 280px), 1fr));
  gap: 10px 28px;
  padding: 10px max(16px, env(safe-area-inset-right)) 8px max(16px, env(safe-area-inset-left));
  border-bottom: 1px solid var(--line);
}

.blk {
  display: flex;
  flex-direction: column;
  gap: 5px;
  min-width: 0;

  h3 {
    @include label;
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 2px 10px;
    margin: 0;
    color: var(--cyan);
    font-size: 11px;
    font-weight: 600;
  }

  p {
    margin: 0;
  }
}

// valeur actuelle, juste après le titre du bloc
.now {
  @include numeric;
  color: var(--text);
  font-size: 13px;
  letter-spacing: 0.02em;
  text-transform: none;
}

.why {
  color: var(--muted);
  font-size: 11px;
  line-height: 1.35;
}

// réglages empilés : libellés dans une colonne, champs alignés dans la suivante, équivalent juste après
.ctl {
  display: grid;
  grid-template-columns: max-content max-content minmax(0, 1fr);
  align-items: center;
  gap: 5px 8px;
  margin-top: 2px;
}

.set {
  display: contents;
}

.k {
  @include label;
  font-size: 10px;
  font-weight: 600;
}

.eq {
  @include numeric;
  color: var(--muted);
  font-size: 11px;
}

// infos annexes (RAM physique, GPU…) : détachées des réglages au-dessus, elles n'en dépendent pas
.aside {
  @include numeric;
  margin-top: 6px !important;
  padding-top: 6px;
  border-top: 1px dashed var(--line);
  color: var(--muted);
  font-size: 11px;
}

.note {
  color: var(--muted);
  font-size: 10px;
  font-style: italic;
}

.warn {
  color: var(--amber);
}

.crit {
  color: var(--red);
}

.reset {
  @include label;
  grid-column: 1 / -1;
  justify-self: end;
  padding: 4px 10px;
  border: 1px solid var(--line);
  background: transparent;
  color: var(--cyan);
  font-size: 10px;
  cursor: pointer;

  &:hover:not(:disabled) {
    background: var(--off);
  }

  &:disabled {
    color: var(--cyan-dim);
    cursor: default;
  }
}
</style>
