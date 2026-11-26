<script setup lang="ts">
// Écrans affichés quand le personnage est aux commandes d'un vaisseau.
import { computed, watch } from 'vue'
import { ACT, FLI, NO_VALUE, VEH, WPN, annunciator, bool, has, num, str } from '@/telemetry'
import MfdPanel from '@/components/MfdPanel.vue'
import SegBar from '@/components/SegBar.vue'
import VBar, { type Zone } from '@/components/VBar.vue'
import HeadingTape from '@/components/HeadingTape.vue'
import Annunciators from '@/components/Annunciators.vue'
import Diagnostics from '@/components/Diagnostics.vue'
import VitalRings from '@/components/VitalRings.vue'
import GMeter from '@/components/GMeter.vue'
import { crash, radarHeight, timeToImpact } from '@/crash'
import { type Mode, learnSpeed, speedMax } from '@/speedmax'

const fr = new Intl.NumberFormat('en-US')

// ---- Instruments ----
// hauteur radar réelle seulement : au-delà de ~500 m le jeu renvoie l'altitude à la place (voir crash.ts)
const alt = computed(radarHeight)
const seaAlt = computed(() => {
  const a = num(`${FLI}altitude`, NO_VALUE * 2)
  return has(`${FLI}altitude`) && a < NO_VALUE ? a : null
})
const tti = computed(timeToImpact)

// Vitesse : négative en marche arrière (à confirmer en jeu : la jauge passe alors en bleu)
const speed = computed(() => num(`${FLI}speed`))
// Zones relevées sur le HUD du jeu (barre pleine) : 25 % vert, 50 % jaune, 25 % rouge
const SPEED_ZONES: Zone[] = [
  { to: 0.25, color: '#57e389' },
  { to: 0.75, color: '#f2c23b' },
  { to: 1, color: '#ff5b4f' },
]
// Boost : les 25 derniers % en rouge (pas de nouveau boost possible), le reste en cyan
// Mode de vol. Le champ prévu (master_mode) n'est pas envoyé en LIVE 4.10 : on le déduit du voyant
// QDRV, allumé seulement quand le quantum est disponible, c'est-à-dire en NAV. Si le jeu envoie
// un jour master_mode, il est utilisé en priorité. Aucun sous-mode (QT, missile, minage) dans le schéma.
const MODE: Record<string, string> = { NAVIGATION: 'NAV', SCM: 'SCM', STEALTH: 'STEALTH' }
const mode = computed<{ label: string; guessed: boolean } | null>(() => {
  const real = str(`${VEH}master_mode.mode`).replace('VEHICLE_MASTER_MODE_', '')
  if (MODE[real]) return { label: MODE[real], guessed: false }
  if (!bool(`${VEH}power.powerplants`)) return null // vaisseau éteint
  return { label: annunciator('qdrv') === 'off' ? 'SCM' : 'NAV', guessed: true }
})

// Échelle de la barre de vitesse : vitesse max du vaisseau dans ce mode (connue, apprise ou par défaut, voir speedmax.ts)
const shipClass = computed(() => str(`${VEH}class_name`))
const speedMode = computed<Mode>(() => (mode.value?.label === 'NAV' ? 'NAV' : 'SCM'))
const maxSpeed = computed(() => speedMax(shipClass.value, speedMode.value))
watch(speed, (v) => learnSpeed(shipClass.value, speedMode.value, Math.abs(v)))

const BOOST_ZONES: Zone[] = [
  { to: 0.25, color: '#ff5b4f' },
  { to: 1, color: '#63e4dd' },
]
// Proche d'une planète : le jeu donne une altitude, ou le sol est à portée du radar. Dans l'espace, l'altitude
// vaut « pas de mesure » ; la densité de l'atmosphère, elle, n'y est pas nulle (0,01 relevé le 2026-11-25) :
// elle ne compte qu'au-delà d'un vrai seuil. Hors de là, cap / altitude / vitesse verticale n'ont pas de sens
// (le HUD du jeu les masque aussi).
const nearPlanet = computed(() => seaAlt.value !== null || alt.value !== null || num(`${FLI}atmospheric_density`) >= 0.05)
const gMax = computed(() => num(`${FLI}g_meter.max`, 1) || 1)
const gCur = computed(() => num(`${FLI}g_meter.current`))

// ---- Leurres (le détail des armes est dans Diagnostics) ----
const countermeasures = computed(() => {
  const out = { DECOY: 0, NOISE: 0 } as Record<string, number>
  for (let i = 0; has(`${WPN}countermeasures.${i}.type`); i++) {
    out[str(`${WPN}countermeasures.${i}.type`).replace('COUNTERMEASURE_TYPE_', '')] = num(`${WPN}countermeasures.${i}.amount`)
  }
  return out
})

// ---- États du vaisseau, abrégés comme sur le HUD du jeu (affichés seulement quand actifs) ----
// seul « active » compte : « enabled » veut dire disponible (vérifié sur capture : ESP enabled mais inactif)
const ifcsOn = (k: string) => bool(`${VEH}flight.settings.${k}.active`)
// danger : pastille rouge pleine, pour ce qu'on ne doit pas oublier
//  - CRUISE actif : vitesse automatique, dangereuse si on l'oublie (repasser en couplé relance le vaisseau)
type Flag = { label: string; title: string; danger?: boolean }
// ESP coupé : ne devrait jamais l'être, mais le jeu le coupe parfois tout seul → bande rouge en bas du panneau.
// Signalé seulement vaisseau alimenté et en mode combat (SCM) : en NAV l'ESP est coupé par le quantum et ne sert à rien.
// Pas de condition sur « enabled » : ESP coupé en jeu, le jeu passe enabled ET active à faux (vérifié en direct).
// Moteurs coupés (jauge H-Fuel à 0, constaté en jeu) : le jeu coupe aussi l'ESP → rien à signaler.
const enginesOn = () => num(FLI + 'hydrogen_fuel') > 0
// Jauges de carburant : le jeu tronque (99,6 % → 99 %), pas d'arrondi. À réutiliser pour Q-Fuel quand il sera envoyé.
const fuelPct = (v: number) => Math.floor(Math.min(1, Math.max(0, v)) * 100 + 1e-6)
const espLost = () => mode.value?.label !== 'NAV' && bool(VEH + 'power.powerplants') && enginesOn() && !ifcsOn('ifcs_esp')
// Compensateur de gravité : censé être toujours actif → rien quand il l'est, bande rouge quand il est coupé
// (vaisseau alimenté, tous modes : il compte aussi en NAV près d'une planète).
const gravLost = () => bool(VEH + 'power.powerplants') && !ifcsOn('ifcs_gravity_compensation')
// Bandes d'avertissement en bas du panneau de vol
const warnings = computed(() => [
  ...(espLost() ? ['Warning · ESP inactive'] : []),
  ...(gravLost() ? ['Warning · Grav. comp. inactive'] : []),
])
const flags = computed(() => {
  const out: Flag[] = []
  if (ifcsOn('ifcs_coupled')) out.push({ label: 'CPLD', title: 'Coupled' })
  if (ifcsOn('ifcs_esp')) out.push({ label: 'ESP', title: 'Enhanced stick precision' })
  if (bool(VEH + 'lights_enabled')) out.push({ label: 'LIGHT', title: 'Lights' })
  if (ifcsOn('ifcs_speed_limiter')) out.push({ label: 'LIM', title: 'Speed limiter' })
  if (ifcsOn('ifcs_cruise_mode')) out.push({ label: 'CRUISE', title: 'Cruise control is ON', danger: true })
  return out
})

// Train : icône rouge sorti, orange clignotante en mouvement, rien quand il est rentré (comme en jeu)
const gear = computed(() => str(`${VEH}flight.state.gear`).replace('VEHICLE_COMPONENT_DEPLOYMENT_STATE_', ''))

// ---- Pilote ----
const ROLE: Record<string, string> = { PILOT: 'Pilot', COPILOT: 'Copilot', TURRET: 'Turret' }
const role = computed(() => {
  const r = str(`${ACT}state.crew_role`).replace('ACTOR_CREW_ROLE_', '')
  return ROLE[r] ?? (r || '—')
})
</script>

<template>
  <section class="screens flight">
    <MfdPanel title="Flight instruments" source="flight.instruments" tab="FLIGHT">
      <!-- comme le HUD du jeu : états du vaisseau à gauche, vitesse / boost au centre, leurres à droite -->
      <div class="top">
        <div class="hud">
          <svg
            v-if="gear && gear !== 'RETRACTED'"
            viewBox="0 0 24 24"
            class="gear"
            :class="{ moving: gear.endsWith('ING') }"
            role="img"
            :aria-label="'Landing gear ' + gear.toLowerCase()"
          >
            <title>Landing gear {{ gear.toLowerCase() }}</title>
            <path d="M8 3v6M5 3h6M15 4v10M12 11l3 3 3-3" />
            <circle cx="8" cy="14" r="4" />
            <circle cx="8" cy="14" r="1.2" />
          </svg>
          <span v-for="f in flags" :key="f.label" class="flag" :class="{ danger: f.danger }" :title="f.title">{{ f.label }}</span>
        </div>
        <!-- mode de vol à part : centré au-dessus des deux barres (place gardée quand il est absent) -->
        <div class="speed">
          <span class="badge" :class="[mode?.label.toLowerCase(), { masked: !mode }]" :title="mode?.guessed ? 'Deduced from the quantum drive indicator' : ''">
            {{ mode?.label ?? 'SCM' }}
          </span>
          <div class="pair">
            <VBar
              :value="Math.abs(speed) / maxSpeed.value"
              :title="`Full bar = ${maxSpeed.value} m/s (${maxSpeed.source})`"
              :zones="SPEED_ZONES"
              :reverse="speed < 0"
              :reading="Math.round(Math.abs(speed)).toString()"
              label="m/s"
            />
            <VBar
              :value="num(FLI + 'boost.reserves')"
              :zones="BOOST_ZONES"
              :reading="`${Math.round(num(FLI + 'boost.reserves') * 100)}%`"
              label="Boost"
            >
              <span class="chip" :class="{ hot: bool(FLI + 'boost.engaged') }">AB</span>
            </VBar>
          </div>
        </div>
        <!-- leurres restants : le jeu n'envoie que le stock, pas la taille de salve choisie -->
        <div class="cm">
          <span>Decoy</span><b>{{ countermeasures.DECOY }}</b>
          <span>Noise</span><b>{{ countermeasures.NOISE }}</b>
        </div>
      </div>
      <!-- .masked : invisible mais garde sa place, donc rien ne bouge quand ça apparaît / disparaît -->
      <HeadingTape :heading="num(FLI + 'heading')" :class="{ masked: !nearPlanet }" />
      <div class="cols" :class="{ masked: !nearPlanet }">
        <div class="stack">
          <span class="lbl">Heading</span>
          <span class="num mid">{{ String(Math.round(num(FLI + 'heading')) % 360).padStart(3, '0') }}°</span>
        </div>
        <div class="stack">
          <!-- sol à portée du radar (~500 m) : hauteur réelle ; sinon l'altitude (celle que le HUD du jeu
               affiche aussi comme altitude radar), qui n'est PAS la hauteur au-dessus du sol -->
          <span class="lbl">{{ alt !== null ? 'Radar alt.' : 'Altitude' }}</span>
          <span class="num mid">
            <template v-if="alt !== null">{{ fr.format(Math.round(alt)) }}<span class="unit">m</span></template>
            <template v-else-if="seaAlt !== null">{{ fr.format(Math.round(seaAlt)) }}<span class="unit">m</span></template>
            <template v-else>—</template>
          </span>
        </div>
        <div class="stack">
          <span class="lbl">Vert. speed</span>
          <span class="num mid">{{ num(FLI + 'vertical_speed_indicator').toFixed(1) }}<span class="unit">m/s</span></span>
        </div>
        <!-- temps avant impact au sol, affiché seulement en descente sous 30 s -->
        <div class="stack">
          <span class="lbl">Impact</span>
          <span class="num mid" :class="{ danger: crash === 'crash' }">
            <template v-if="tti !== null && tti < 30">{{ tti.toFixed(0) }}<span class="unit">s</span></template>
            <!-- sol hors de portée radar mais descente trop rapide pour s'arrêter à temps (voir crash.ts) -->
            <span v-else-if="crash === 'sink'" class="sinking">SINK</span>
            <template v-else>—</template>
          </span>
        </div>
      </div>
      <!-- bande d'avertissement collée au bas du panneau, juste au-dessus de l'onglet FLIGHT -->
      <div v-if="warnings.length" class="warns" role="status">
        <div v-for="w in warnings" :key="w" class="esp-warn">{{ w }}</div>
      </div>
    </MfdPanel>

    <MfdPanel class="prop" title="Propulsion" source="fuel · boost · g_meter" tab="PROPULSION">
      <div class="bars">
        <div class="bar">
          <span class="num">{{ fuelPct(num(FLI + 'hydrogen_fuel')) }} %</span>
          <SegBar :value="num(FLI + 'hydrogen_fuel')" :segments="12" vertical />
          <span class="lbl">H-Fuel</span>
        </div>
        <!-- Q-Fuel : prévu dans le schéma mais pas encore envoyé par le jeu (LIVE 4.10) → s'active seul dès qu'il arrive -->
        <div v-if="has(FLI + 'quantum_fuel')" class="bar">
          <span class="num">{{ fuelPct(num(FLI + 'quantum_fuel')) }} %</span>
          <SegBar :value="num(FLI + 'quantum_fuel')" :segments="12" vertical />
          <span class="lbl">Q-Fuel</span>
        </div>
        <div v-else class="bar off">
          <span class="num">— %</span>
          <SegBar :value="0" :segments="12" vertical alert="none" />
          <span class="lbl">Q-Fuel</span>
          <span class="soon">coming soon</span>
        </div>
      </div>
      <GMeter :g="gCur" :limit="gMax" :speed="Math.abs(speed)" />
    </MfdPanel>




    <!-- 3e colonne : voyants et pilote l'un au-dessus de l'autre -->
    <div class="side">
      <MfdPanel title="Annunciators" source="annunciators" tab="WARNINGS">
        <Annunciators />
      </MfdPanel>
      <MfdPanel class="crew" title="Pilot" source="actor.vitals" tab="CREW">
        <VitalRings compact />
        <!-- coeur, O2 et siège sur une seule ligne : le panneau reste court -->
        <div class="pilot">
          <div class="stack">
            <span class="lbl">Heart</span>
            <span class="num">{{ Math.round(num(ACT + 'vitals.heart_rate')) }}<span class="unit">bpm</span></span>
          </div>
          <div class="stack">
            <span class="lbl">Oxygen</span>
            <span class="num">{{ Math.round(num(ACT + 'vitals.oxygen.current') * 100) }}<span class="unit">%</span></span>
          </div>
          <div class="stack">
            <span class="lbl">Seat</span>
            <span class="state">{{ role }}</span>
          </div>
        </div>
      </MfdPanel>
    </div>

    <!-- composants sur toute la largeur, en 3 colonnes -->
    <MfdPanel class="full" title="Diagnostics" source="power · annunciators · weapons" tab="DIAGNOSTICS">
      <Diagnostics />
    </MfdPanel>

    <MfdPanel class="full ghost" title="Hull · shields · quantum" source="vehicle.health · shields · quantum_fuel" tab="DAMAGE">
      <span class="q">NOT RECEIVED</span>
      <p>These fields exist in the schema but the game does not send them yet (LIVE 4.10).</p>
    </MfdPanel>
  </section>
</template>

<style scoped lang="scss">
// Masqué sans libérer la place (visibility, pas display) ; fondu d'opacité à l'apparition / disparition
.masked {
  opacity: 0;
  visibility: hidden;
}

.top {
  --vbar-h: 108px; // barres plus courtes : moins de hauteur pour la rangée du haut
  --mode-h: 22px; // hauteur du badge NAV / SCM au-dessus des barres
  --mode-gap: 8px;
  display: grid;
  // vitesse / boost centrés ; les colonnes latérales ne descendent jamais sous la largeur de leur contenu
  grid-template-columns: minmax(max-content, 1fr) auto minmax(max-content, 1fr);
  align-items: start;
  gap: 10px;
}

.speed {
  display: grid;
  justify-items: center;
  gap: var(--mode-gap);

  // badge de hauteur fixe : les colonnes latérales savent exactement où commencent les tubes
  .badge {
    height: var(--mode-h);
    line-height: calc(var(--mode-h) - 2px);
    padding-block: 0;
  }
}

// deux barres de même largeur : le milieu du bloc tombe pile entre les deux tubes
// (sinon « 100% » et la pastille AB élargissent la barre de boost et décalent le centre)
.pair {
  display: flex;
  align-items: flex-start; // pas d'étirement : valeurs et libellés des deux barres sur la même ligne
  gap: 4px;

  > * {
    width: 52px;
  }
}

// États (gauche) et leurres (droite) : même hauteur que les tubes, décalés de la hauteur du badge,
// contenu centré → centrés verticalement sur les tubes, quels que soient les textes en dessous.
.hud,
.cm {
  height: var(--vbar-h);
  margin-top: calc(var(--mode-h) + var(--mode-gap));
}

// Disposition, choisie par viewport.ts (classe cols-N sur <html>, voir son tableau) :
//  - 3 colonnes : Flight | Propulsion | (Annunciators au-dessus de Pilot) ;
//  - 2 colonnes : Flight | Propulsion, puis Annunciators | Pilot côte à côte sur toute la largeur ;
//  - 1 colonne  : tout empilé.
// Diagnostics toujours sur toute la largeur. Le nombre de colonnes de .flight vient de base.scss (.screens).
.flight > .full {
  grid-column: 1 / -1;
}

.side {
  display: grid;
  // Pilot à sa hauteur utile, Annunciators prend le reste : la colonne s'aligne sur Flight / Propulsion
  // sans imposer deux moitiés égales (qui allongeaient toute la rangée et laissaient du vide dans Pilot)
  grid-template-rows: 1fr auto;
  gap: 14px;
  min-width: 0;
}
// 2 et 1 colonnes : règles dans styles/base.scss (un sélecteur sur <html> ne passe pas dans un style scoped)

.side > :first-child :deep(.body) {
  align-content: center; // voyants centrés dans la place restante
}

// Écran pilote le plus court possible, écarts minimaux. :deep(.body) = le contenu de MfdPanel.
.crew :deep(.body) {
  align-content: start;
  gap: 10px; // entre les jauges et la ligne coeur / O2 / siège
}

// Propulsion : jauges carburant et G-meter regroupés au centre (pas étirés sur la hauteur de la rangée)
.prop :deep(.body) {
  align-content: center;
  gap: 10px;
}

// trois valeurs côte à côte, libellé collé à la valeur
.pilot {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;

  .stack {
    gap: 0;
  }

  // libellé collé à sa valeur
  .lbl {
    line-height: 1;
  }

  .num,
  .state {
    font-size: 14px;
    line-height: 1.15;
  }
}

// pleine largeur, collée à l'onglet du bas (annule le padding du panneau)
.warns {
  display: grid;
  gap: 1px;
  margin: auto -14px -12px; // -12px : annule l'écart entre le contenu et l'onglet (MfdPanel)
}

.esp-warn {
  padding: 6px 14px;
  background: var(--red);
  color: #fff;
  font: 600 12px var(--font-num);
  letter-spacing: 0.18em;
  text-align: center;
  text-transform: uppercase;
}

// leurres : libellé + stock, comme sur le HUD du jeu ; grille → libellés et chiffres alignés en colonnes
.cm {
  display: grid;
  grid-template-columns: auto auto;
  align-content: center;
  justify-content: start;
  gap: 6px 8px;

  span {
    color: var(--cyan);
    font: 600 11px var(--font-num);
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }

  b {
    @include numeric;
    color: var(--text);
    font-size: 14px;
    text-align: right;
  }
}

// colonne d'états : badges encadrés comme sur le HUD du jeu, tous de la même largeur
.hud {
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: flex-end; // collés à la barre de vitesse
  gap: 6px;
}

.flag {
  min-width: 54px;
  padding: 2px 6px 2px calc(6px + 0.14em); // compense l'espace ajouté après la dernière lettre
  border: 1px solid var(--cyan-dim);
  border-radius: 3px;
  color: var(--cyan);
  font: 600 12px var(--font-num);
  letter-spacing: 0.14em;
  text-align: center;

  // rouge plein : se voit même en Arena Commander (interface déjà rouge)
  &.danger {
    border-color: var(--red);
    background: var(--red);
    color: #fff;
  }
}

.gear {
  width: 22px;
  height: 22px;
  fill: none;
  stroke: var(--red);
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;

  &.moving {
    stroke: var(--amber);
    animation: blink 0.5s steps(2) infinite;
  }
}

@keyframes blink {
  50% {
    opacity: 0.35;
  }
}

.badge {
  display: inline-block;
  padding: 2px 8px 2px calc(8px + 0.14em); // compense l'espace ajouté après la dernière lettre
  border: 1px solid var(--cyan-dim);
  color: var(--cyan);
  font: 600 12px var(--font-num);
  letter-spacing: 0.14em;

  &.nav {
    border-color: var(--amber);
    color: var(--amber);
  }
}

// H-Fuel / Q-Fuel alignés par le haut : la ligne « coming soon » sous Q-Fuel ne décale pas sa jauge
.bars {
  align-items: flex-start;
}

.off {
  opacity: 0.4;
}

.soon {
  @include label;
  font-size: 8px;
  letter-spacing: 0.08em;
}

.tape,
.cols {
  transition:
    opacity 0.3s,
    visibility 0.3s;
}

.danger {
  color: var(--red);
}

.ghost {
  opacity: 0.55;

  .q {
    color: var(--cyan-dim);
    font: 600 30px var(--font-num);
    letter-spacing: 0.1em;
  }

  p {
    margin: 0;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }
}

.sinking {
  color: var(--amber);
}

// ---- Téléphone : barres plus courtes, Propulsion sur deux colonnes, panneau « non reçu » masqué ----
@include phone {
  .top {
    --vbar-h: 90px;
    --mode-h: 20px;
    --mode-gap: 6px;
    gap: 6px;
  }

  .pair > * {
    width: 46px;
  }

  // barres H-Fuel / Q-Fuel à gauche, G-meter à droite
  .prop :deep(.body) {
    grid-template-columns: auto minmax(0, 1fr);
    align-items: center;
  }

  .prop .bars {
    gap: 8px;
  }

  .warns {
    margin: auto -10px -8px; // suit les marges réduites du panneau et l'écart avant l'onglet (MfdPanel)
  }

  .esp-warn {
    padding: 4px 10px;
    font-size: 11px;
  }

  .crew :deep(.body) {
    gap: 8px;
  }

  // ne montre que des champs que le jeu n'envoie pas : inutile sur un petit écran
  .ghost {
    display: none;
  }
}
</style>
