<script setup lang="ts">
// Texte sur une ligne : s'il dépasse la place disponible, il est coupé et défile en continu vers la gauche.
// Le texte est doublé : quand la première copie est sortie, la seconde est exactement à sa place,
// on revient au départ sans saut visible (boucle infinie). Courte pause à chaque tour, texte au début.
// Mesure faite seulement quand une taille change (boîte ou texte, ResizeObserver) ; l'animation ne touche que transform.
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps<{ text: string }>()

// marges de chaque copie quand ça défile (mêmes valeurs que .loop .copy) :
// à gauche pour sortir le début du fondu, à droite pour l'écart avant la copie suivante
const PAD_L = 10
const PAD_R = 30
const SPEED = 30 // px/s

const box = ref<HTMLElement>()
const first = ref<HTMLElement>()
const width = ref(0) // largeur du texte seul
const scroll = ref(false)

function measure(): void {
  if (!box.value || !first.value) return
  width.value = first.value.offsetWidth - (scroll.value ? PAD_L + PAD_R : 0)
  scroll.value = width.value > box.value.clientWidth
}

let ro: ResizeObserver | undefined
onMounted(() => {
  ro = new ResizeObserver(measure)
  ro.observe(box.value!)
  ro.observe(first.value!) // le texte change de largeur au chargement de la police
  measure()
})
onBeforeUnmount(() => ro?.disconnect())
watch(() => props.text, () => requestAnimationFrame(measure))

// un tour = une copie et ses marges ; le mouvement occupe 85 % du tour (15 % de pause)
const duration = () => `${(width.value + PAD_L + PAD_R) / SPEED / 0.85}s`
</script>

<template>
  <span ref="box" class="marquee" :class="{ loop: scroll }" :title="scroll ? text : undefined">
    <span class="in" :style="scroll ? { '--dur': duration() } : undefined">
      <span ref="first" class="copy">{{ text }}</span>
      <span v-if="scroll" class="copy" aria-hidden="true">{{ text }}</span>
    </span>
  </span>
</template>

<style scoped lang="scss">
.marquee {
  display: block;
  min-width: 80px; // toujours quelques lettres visibles, le reste défile
  max-width: var(--marquee-max, 200px); // au-delà, le texte est coupé et défile
  overflow: hidden;
  white-space: nowrap;

  // bords estompés seulement quand le texte défile
  &.loop {
    mask-image: linear-gradient(90deg, transparent, #000 6px, #000 calc(100% - 6px), transparent);
  }
}

.in,
.copy {
  display: inline-block;
}

// mêmes valeurs que PAD_L / PAD_R dans le script
.loop .copy {
  padding: 0 30px 0 10px;
}

// -50 % = exactement une copie (les deux sont identiques) : la boucle est sans raccord
.loop .in {
  animation: slide var(--dur) linear infinite;
}

@keyframes slide {
  0%,
  15% {
    transform: translateX(0);
  }

  100% {
    transform: translateX(-50%);
  }
}
</style>
