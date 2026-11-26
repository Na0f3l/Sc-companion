// Source « en direct » chargée au premier besoin : gRPC et le schéma de télémétrie (~10 Mo) ne sont chargés qu'au
// premier start() (jeu lancé ou écran connecté), pas au démarrage du service. Mêmes méthodes que la vraie source.
// Si le dossier du jeu a changé depuis (LIVE → PTU, choix dans le menu), la source est recréée au start() suivant,
// avec le schéma de télémétrie de ce jeu-là.
import type { Source } from './source.ts'

type Live = Source & { status(): string; close(): void }

export function createLazyLiveSource(gameDir: () => string, addr?: string): Live {
  let real: Live | null = null
  let realDir = ''
  let failedDir = ''
  let loading = false
  let wanted = false // start() demandé pendant le chargement
  return {
    name: 'live',
    start() {
      wanted = true
      if (loading) return
      const dir = gameDir()
      if (real && dir !== realDir) {
        console.log(`Live: game folder changed to ${dir}, reloading the telemetry schema`)
        real.close()
        real = null
      }
      if (real) return real.start()
      if (dir === failedDir) return // schéma introuvable dans ce dossier : pas de nouvelle lecture de l'exe toutes les 2 s
      loading = true
      import('./live.ts')
        .then((m) => {
          real = m.createLiveSource(dir, addr)
          realDir = dir
          if (wanted) real.start()
        })
        .catch((e: Error) => {
          failedDir = dir
          console.error('Live telemetry unavailable:', e.message)
        })
        .finally(() => (loading = false))
    },
    stop() {
      wanted = false
      real?.stop()
    },
    close() {
      wanted = false
      real?.close()
      real = null
    },
    latest: () => real?.latest() ?? null,
    status: () => real?.status() ?? 'stopped',
  }
}
