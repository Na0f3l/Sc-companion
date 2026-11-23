// Flash « touché » : l'interface vire au rouge 0,2 s quand on prend des dégâts.
//
// Sources surveillées (une seule suffit) :
//  - personnage : la santé baisse d'au moins 0,5 point ;
//  - vaisseau   : le voyant HIT passe au minor / major, ou monte d'un niveau (minor → major) ;
//                 c'est le voyant du jeu qui s'allume quand le vaisseau est attaqué, boucliers compris ;
//  - vaisseau   : le niveau de bouclier ou la santé de coque baisse (prévus par le schéma mais
//                 jamais envoyés en LIVE 4.10 : prêt si le jeu se met à les envoyer).
//
// Le flash pose un attribut data-hit sur <html> ; les couleurs sont dans styles/base.scss.
// Sous un feu nourri, au plus un flash toutes les 0,4 s pour qu'il reste visible (rouge / normal / rouge…).
import { watch } from 'vue'
import { ACT, VEH, annunciator, has, num } from './telemetry'

const FLASH_MS = 200
const MIN_GAP_MS = 400
let last = 0
let timer: ReturnType<typeof setTimeout> | undefined

export function flash(): void {
  const now = performance.now()
  if (now - last < MIN_GAP_MS) return
  last = now
  const root = document.documentElement
  root.dataset.hit = '1'
  clearTimeout(timer)
  timer = setTimeout(() => delete root.dataset.hit, FLASH_MS)
}

// Valeur numérique qui baisse d'au moins `min` → flash. Absente = rien (le jeu ne l'envoie pas,
// ou on change de contexte : pas de faux flash en sortant d'un vaisseau ou au chargement).
function onDrop(key: string, min: number): void {
  watch(
    () => (has(key) ? num(key) : null),
    (now, before) => {
      if (now !== null && before !== null && before !== undefined && before - now >= min) flash()
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
    if (now > before) flash()
  },
)
