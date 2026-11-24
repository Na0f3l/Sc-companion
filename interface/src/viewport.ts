// Disposition des écrans : SEUL endroit qui décide du nombre de colonnes et de la réduction.
// Principe (choix de l'utilisateur) : garder un maximum d'infos visibles, en réduisant les modules
// plutôt qu'en les réorganisant. La page est mise en page sur une largeur de référence, puis réduite
// à la largeur réelle par la propriété CSS zoom sur <html> :
//
//   largeur réelle      colonnes   largeur de référence   réduction
//   ≥ 1000 px           3          (aucune)               100 %
//   600 → 999 px        3          1000 px                60 → 100 %
//   385 → 599 px        2          700 px                 55 → 85 %   (Annunciators | Pilot côte à côte)
//   < 385 px            1          480 px                 ≤ 80 %      (ne devrait quasiment jamais arriver)
//
// La classe cols-3 / cols-2 / cols-1 posée sur <html> pilote les grilles (base.scss, FlightView) :
// AUCUNE media query ne doit changer le nombre de colonnes, elles voient la largeur réelle et non la
// largeur de référence (c'était la cause du désordre : 2 colonnes à 900 px, 3 à 610, 2 à 590…).
// Pourquoi zoom et pas <meta name="viewport" content="width=…"> : le navigateur du téléphone ignore
// cette balise en plein écran.
const LAYOUTS = [
  { min: 600, cols: 3, ref: 1000 },
  { min: 385, cols: 2, ref: 700 },
  { min: 0, cols: 1, ref: 480 },
] as const

let zoom = 1
/** Facteur de réduction en cours (1 = aucun) : pour convertir des positions mesurées à l'écran. */
export const pageZoom = (): number => zoom

const root = document.documentElement

function apply(): void {
  // Vraie largeur mesurée SANS zoom : selon le navigateur, innerWidth tient compte du zoom de <html>,
  // et le zoom s'annulerait lui-même au calcul suivant.
  root.style.zoom = ''
  const w = window.innerWidth
  const layout = LAYOUTS.find((l) => w >= l.min)!
  zoom = Math.min(1, w / layout.ref)
  root.style.zoom = zoom < 1 ? String(zoom) : ''
  for (const l of LAYOUTS) root.classList.toggle(`cols-${l.cols}`, l === layout)
}

apply()
// resize : rotation, entrée / sortie du plein écran, barres du navigateur, fenêtre redimensionnée
window.addEventListener('resize', apply, { passive: true })
