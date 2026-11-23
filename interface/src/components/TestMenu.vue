<script setup lang="ts">
// Menu « Test » de l'en-tête : déclenche une alerte de test (medium / high / RAM) ou le flash « touché ».
// Se ferme au choix d'une option, à un clic ailleurs ou avec Échap.
import { onBeforeUnmount, ref, watch } from 'vue'
import { TESTS, type TestKind, shownAlert, triggerTest } from '@/alerts'
import { flash } from '@/hit'

const open = ref(false)
const root = ref<HTMLElement | null>(null)

function pick(kind: TestKind | 'hit'): void {
  open.value = false
  if (kind === 'hit') flash()
  else triggerTest(kind)
}

// Écouteurs posés seulement quand le menu est ouvert : rien ne tourne le reste du temps
function onDown(e: PointerEvent): void {
  if (!root.value?.contains(e.target as Node)) open.value = false
}
function onKey(e: KeyboardEvent): void {
  if (e.key === 'Escape') open.value = false
}
watch(open, (o) => {
  const fn = o ? window.addEventListener : window.removeEventListener
  fn('pointerdown', onDown as EventListener)
  fn('keydown', onKey as EventListener)
})
onBeforeUnmount(() => (open.value = false))

const KINDS = Object.keys(TESTS) as TestKind[]
</script>

<template>
  <div ref="root" class="menu">
    <button type="button" class="test" :aria-expanded="open" aria-haspopup="menu" @click="open = !open">
      Test <span class="caret" :class="{ up: open }">▾</span>
    </button>
    <ul v-if="open" class="list" role="menu">
      <li v-for="k in KINDS" :key="k" role="none">
        <button type="button" role="menuitem" :class="TESTS[k].item.level" :disabled="!!shownAlert" @click="pick(k)">
          <span class="sw" />{{ TESTS[k].label }}
        </button>
      </li>
      <li role="none">
        <button type="button" role="menuitem" class="hit" @click="pick('hit')"><span class="sw" />Hit flash</button>
      </li>
    </ul>
  </div>
</template>

<style scoped lang="scss">
.menu {
  position: relative;
}

// même apparence que les autres boutons de l'en-tête
.test {
  padding: 5px 10px;
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--muted);
  font: 500 11px var(--font-ui);
  letter-spacing: 0.08em;
  text-transform: uppercase;
  cursor: pointer;

  &:hover,
  &[aria-expanded='true'] {
    border-color: var(--cyan-dim);
    color: var(--cyan);
  }

  &:focus-visible {
    outline: 2px solid var(--amber);
    outline-offset: 2px;
  }
}

.caret {
  display: inline-block;
  margin-left: 4px;
  transition: transform 0.15s;

  &.up {
    transform: rotate(180deg);
  }
}

.list {
  position: absolute;
  z-index: 20;
  top: calc(100% + 4px);
  right: 0;
  min-width: 170px;
  margin: 0;
  padding: 4px;
  list-style: none;
  border: 1px solid var(--cyan-dim);
  background: var(--panel);
  @include bevel(8px);

  button {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 7px 8px;
    border: 0;
    background: none;
    color: var(--text);
    font: 500 12px var(--font-ui);
    letter-spacing: 0.06em;
    text-transform: uppercase;
    text-align: left;
    cursor: pointer;

    &:hover:not(:disabled),
    &:focus-visible {
      outline: none;
      background: rgb(99 228 221 / 8%);
      color: var(--cyan);
    }

    &:disabled {
      opacity: 0.45;
      cursor: default;
    }
  }
}

// pastille de couleur : niveau de l'alerte testée
.sw {
  flex: none;
  width: 8px;
  height: 8px;
  background: var(--cyan);
}

.warning .sw {
  background: var(--amber);
}

.critical .sw,
.hit .sw {
  background: var(--red);
}
</style>
