// Ouverture du panneau Sessions depuis n'importe où (bouton dossier de l'en-tête) : le panneau est monté une seule fois
// (App.vue) et s'enregistre ici.
let opener: (() => void) | null = null

export const registerSessionsPanel = (open: () => void): void => {
  opener = open
}
export const openSessions = (): void => opener?.()
