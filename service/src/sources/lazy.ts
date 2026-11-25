// Source « en direct » chargée au premier besoin : gRPC et le schéma de télémétrie (~10 Mo) ne sont chargés qu'au
// premier start() (jeu lancé ou écran connecté), pas au démarrage du service. Mêmes méthodes que la vraie source.
import type { Source } from './source.ts'

type Live = Source & { status(): string }

export function createLazyLiveSource(gameDir: () => string, addr?: string): Live {
  let real: Live | null = null
  let loading = false
  let wanted = false // start() demandé pendant le chargement
  return {
    name: 'live',
    start() {
      wanted = true
      if (real) return real.start()
      if (loading) return
      loading = true
      import('./live.ts')
        .then((m) => {
          real = m.createLiveSource(gameDir(), addr)
          if (wanted) real.start()
        })
        .catch((e: Error) => console.error('Live telemetry unavailable:', e.message))
    },
    stop() {
      wanted = false
      real?.stop()
    },
    latest: () => real?.latest() ?? null,
    status: () => real?.status() ?? 'stopped',
  }
}
