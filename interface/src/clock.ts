// Horloge à la seconde partagée par toutes les courbes (Sparkline) et les repères de la bande RAM :
// tout avance au même instant, sans décalage entre deux minuteries. Une seule minuterie pour toute la page.
import { shallowRef } from 'vue'

export const TICK_MS = 1000

/** Heure (ms) du dernier battement */
export const tick = shallowRef(Date.now())

setInterval(() => (tick.value = Date.now()), TICK_MS)

/**
 * Fait glisser un élément d'une case vers la gauche pendant une seconde, entre deux battements.
 * Animation de transform : traitée par le compositeur du navigateur, sans redessiner l'élément.
 * `shift` : décalage final, en % de la largeur de l'élément.
 */
export function glide(el: Element | null | undefined, shift: number): void {
  el?.animate([{ transform: 'translateX(0)' }, { transform: `translateX(-${shift}%)` }], {
    duration: TICK_MS,
    easing: 'linear',
    fill: 'forwards',
  })
}
