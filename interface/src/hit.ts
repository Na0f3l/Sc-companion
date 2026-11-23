// Flash « touché » : l'interface passe au rouge d'un coup puis revient à la normale en 0,2 s.
//
// Sources surveillées (une seule suffit) :
//  - personnage : la santé baisse d'au moins 0,5 point ;
//  - vaisseau   : le voyant HIT passe au minor / major, ou monte d'un niveau (minor → major) ;
//                 c'est le voyant du jeu qui s'allume quand le vaisseau est attaqué, boucliers compris ;
//  - vaisseau   : le niveau de bouclier ou la santé de coque baisse (prévus par le schéma mais
//                 jamais envoyés en LIVE 4.10 : prêt si le jeu se met à les envoyer).
//
// Le flash pose un attribut data-hit sur <html> ; les couleurs sont dans styles/base.scss.
// Sous un feu nourri, au plus un flash toutes les 0,3 s pour qu'il reste visible.
import { watch } from 'vue'
import { ACT, VEH, annunciator, has, num } from './telemetry'
import { alertEnabled } from './settings'

const FLASH_MS = 200
const MIN_GAP_MS = 300
let last = 0
let timer: ReturnType<typeof setTimeout> | undefined

// Voile rouge plein écran, par-dessus l'interface recolorée : quasi opaque d'un coup, puis s'efface vite.
// Créé une seule fois ; seule son opacité est animée (carte graphique, aucun recalcul de la page).
const VEIL_OPACITY = 0.7
const VEIL_MS = 250
let veil: HTMLDivElement | null = null
function veilFlash(): void {
  if (!veil) {
    veil = document.createElement('div')
    Object.assign(veil.style, {
      position: 'fixed',
      inset: '0',
      zIndex: '200',
      pointerEvents: 'none', // ne bloque jamais l'écran
      background: '#ff2a1f',
      opacity: '0',
    })
    document.body.appendChild(veil)
  }
  veil.getAnimations().forEach((a) => a.cancel())
  veil.animate([{ opacity: VEIL_OPACITY }, { opacity: 0 }], { duration: VEIL_MS, easing: 'cubic-bezier(0.2, 0, 0.6, 1)' })
}

export function flash(): void {
  const now = performance.now()
  if (now - last < MIN_GAP_MS) return
  last = now
  veilFlash()
  const root = document.documentElement
  clearTimeout(timer)
  // 1. rouge instantané (sans transition)
  delete root.dataset.hitFade
  root.dataset.hit = '1'
  // 2. l'image suivante : on retire le rouge AVEC transition → retour aux couleurs normales en 0,2 s
  //    (deux requestAnimationFrame : garantit que le rouge a bien été affiché une fois)
  requestAnimationFrame(() =>
    requestAnimationFrame(() => {
      root.dataset.hitFade = '1'
      delete root.dataset.hit
      timer = setTimeout(() => delete root.dataset.hitFade, FLASH_MS + 50)
    }),
  )
}

// Dégâts détectés : flash seulement si l'alerte est activée dans le menu (le test, lui, passe toujours)
function onHit(): void {
  if (alertEnabled('hit')) flash()
}

// Valeur numérique qui baisse d'au moins `min` → flash. Absente = rien (le jeu ne l'envoie pas,
// ou on change de contexte : pas de faux flash en sortant d'un vaisseau ou au chargement).
function onDrop(key: string, min: number): void {
  watch(
    () => (has(key) ? num(key) : null),
    (now, before) => {
      if (now !== null && before !== null && before !== undefined && before - now >= min) onHit()
    },
  )
}

onDrop(`${ACT}vitals.health.current`, 0.5)
onDrop(`${VEH}shields.level`, 0.5)
onDrop(`${VEH}health`, 0.5)

const RANK = { off: 0, nominal: 0, minor: 1, major: 2 } as const
watch(
  () => RANK[annunciator('hit')],
  (now, before) => {
    if (now > before) onHit()
  },
)
