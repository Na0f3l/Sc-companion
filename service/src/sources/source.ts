// Une source de télémétrie : le rejeu d'une capture aujourd'hui, le jeu en direct demain.
//
// Principe : la source garde seulement la DERNIÈRE trame reçue (latest).
// C'est le diffuseur qui vient la lire à son rythme (5 fois/s) : on ne traite jamais les 17 trames/s du jeu.
export interface Source {
  readonly name: string
  start(): void // appelé quand le premier écran se connecte
  stop(): void // appelé quand le dernier écran se déconnecte : plus aucun travail
  latest(): unknown | null
  status?(): string // état lisible (« en direct », « jeu introuvable »…)
}
