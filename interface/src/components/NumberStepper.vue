<script setup lang="ts">
// Champ numérique du HUD : valeur au clavier + petites flèches ▴ ▾ (les flèches natives du navigateur sont masquées).
// Garder une flèche enfoncée fait défiler la valeur (souris ou doigt). La valeur reste entre min et max.
import { onUnmounted, ref, watch } from 'vue'

const props = withDefaults(defineProps<{ min?: number; max?: number; step?: number; unit?: string; label: string }>(), {
  min: 0,
  max: 100,
  step: 1,
  unit: '',
})
const model = defineModel<number>({ required: true })

const clamp = (v: number) => Math.min(props.max, Math.max(props.min, Math.round(v / props.step) * props.step))

// texte tapé, appliqué seulement s'il est valide (champ vide ou « - » en cours de frappe : on attend)
const text = ref(String(model.value))
watch(model, (v) => (text.value = String(v)))
// (pas de v-model : sur un champ number, Vue convertirait le texte en nombre)
function onInput(raw: string): void {
  text.value = raw
  const v = Number(raw)
  if (text.value.trim() !== '' && Number.isFinite(v) && v >= props.min && v <= props.max) model.value = clamp(v)
}
function onBlur(): void {
  const v = Number(text.value)
  model.value = clamp(Number.isFinite(v) && text.value.trim() !== '' ? v : model.value)
  text.value = String(model.value)
}

const bump = (dir: 1 | -1) => (model.value = clamp(model.value + dir * props.step))

// maintien : un pas tout de suite, puis répétition après 400 ms, toutes les 80 ms
let hold = 0
function press(dir: 1 | -1): void {
  bump(dir)
  stop()
  hold = window.setTimeout(function again() {
    bump(dir)
    hold = window.setTimeout(again, 80)
  }, 400)
}
function stop(): void {
  clearTimeout(hold)
}
onUnmounted(stop)
</script>

<template>
  <div class="stepper">
    <input
      :value="text"
      type="number"
      inputmode="decimal"
      :min="min"
      :max="max"
      :step="step"
      :aria-label="label"
      @input="onInput(($event.target as HTMLInputElement).value)"
      @blur="onBlur"
      @keydown.up.prevent="bump(1)"
      @keydown.down.prevent="bump(-1)"
    />
    <span v-if="unit" class="unit">{{ unit }}</span>
    <div class="arrows">
      <button type="button" tabindex="-1" :aria-label="`${label} +`" :disabled="model >= max" @pointerdown.prevent="press(1)" @pointerup="stop" @pointerleave="stop" @pointercancel="stop">▴</button>
      <button type="button" tabindex="-1" :aria-label="`${label} −`" :disabled="model <= min" @pointerdown.prevent="press(-1)" @pointerup="stop" @pointerleave="stop" @pointercancel="stop">▾</button>
    </div>
  </div>
</template>

<style scoped lang="scss">
.stepper {
  display: inline-flex;
  align-items: stretch;
  height: 26px;
  border: 1px solid var(--line);
  background: var(--bg);

  &:focus-within {
    border-color: var(--cyan);
  }
}

// le champ prend la place libre : si la case est étirée (colonne alignée sur un champ plus large),
// les flèches restent collées au bord droit et le chiffre reste près de son unité
input {
  @include numeric;
  flex: 1 1 auto;
  width: 4.2em;
  padding: 0 4px 0 8px;
  border: 0;
  background: transparent;
  color: var(--cyan);
  font-size: 14px;
  font-weight: 600;
  text-align: right;
  outline: none;
  appearance: textfield;
  -moz-appearance: textfield;

  &::-webkit-inner-spin-button,
  &::-webkit-outer-spin-button {
    margin: 0;
    appearance: none;
  }
}

.unit {
  @include label;
  align-self: center;
  padding-right: 6px;
  font-size: 10px;
}

.arrows {
  display: flex;
  flex-direction: column;
  border-left: 1px solid var(--line);

  button {
    flex: 1;
    width: 20px;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--cyan);
    font-size: 9px;
    line-height: 1;
    cursor: pointer;
    touch-action: manipulation;
    user-select: none;

    & + button {
      border-top: 1px solid var(--line);
    }

    &:hover:not(:disabled) {
      background: var(--off);
    }

    &:active:not(:disabled) {
      color: var(--amber);
    }

    &:disabled {
      color: var(--cyan-dim);
      cursor: default;
    }
  }
}
</style>
