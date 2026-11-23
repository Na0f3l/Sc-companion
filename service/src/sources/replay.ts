// Rejoue des captures de la sonde (telemetrie/captures/*.json) en boucle, au rythme d'origine.
//
// Aucun minuteur : à chaque lecture, on calcule quelle trame correspond au temps écoulé.
// Les fichiers sont enchaînés dans l'ordre (à pied, puis en vaisseau…) avec 1 s d'écart.
import fs from 'node:fs'
import path from 'node:path'
import type { Source } from './source.ts'

interface Captured {
  t: number
  frame: unknown
}

export function createReplaySource(target: string): Source {
  const files = fs.statSync(target).isDirectory()
    ? fs.readdirSync(target).filter((f) => f.endsWith('.json')).sort().map((f) => path.join(target, f))
    : [target]
  if (!files.length) throw new Error(`No .json capture in ${target}`)

  // Temps relatifs (ms depuis le début de la boucle) et trames, dans deux tableaux parallèles.
  const times: number[] = []
  const frames: unknown[] = []
  let offset = 0
  for (const file of files) {
    const list = JSON.parse(fs.readFileSync(file, 'utf8')) as Captured[]
    if (!list.length) continue
    const t0 = list[0].t
    for (const c of list) {
      times.push(offset + c.t - t0)
      frames.push(c.frame)
    }
    offset = times[times.length - 1] + 1000
  }
  const duration = offset
  console.log(`Replay: ${files.length} capture(s), ${frames.length} frames, ${(duration / 1000).toFixed(0)} s loop`)

  let startedAt = 0
  let running = false

  // Recherche dichotomique de la dernière trame dont le temps est <= now.
  function indexAt(now: number): number {
    let lo = 0
    let hi = times.length - 1
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if (times[mid] <= now) lo = mid
      else hi = mid - 1
    }
    return lo
  }

  return {
    name: 'replay',
    start() {
      if (!running) startedAt = Date.now()
      running = true
    },
    stop() {
      running = false
    },
    latest() {
      if (!running) return null
      return frames[indexAt((Date.now() - startedAt) % duration)]
    },
  }
}
