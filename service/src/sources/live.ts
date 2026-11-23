// Source « en direct » : flux gRPC TelemetryStream du jeu (127.0.0.1:2942 par défaut). Lecture seule.
//
// - Ne garde que la dernière trame reçue (le diffuseur la lit à 5 Hz).
// - Si le jeu n'est pas lancé ou que le flux coupe : nouvelle tentative toutes les 5 s,
//   uniquement tant qu'un écran est connecté.
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import grpc from '@grpc/grpc-js'
import protoLoader from '@grpc/proto-loader'
import type { Source } from './source.ts'

const PROTO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../telemetrie/proto/sc_telemetry.proto')
const RETRY_MS = 5000

export function createLiveSource(addr = '127.0.0.1:2942'): Source & { status(): string } {
  const def = protoLoader.loadSync(PROTO, { keepCase: true, enums: String, longs: String, defaults: false })
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const pkg = (grpc.loadPackageDefinition(def) as any).sc.game.telemetry.v1
  const client = new pkg.GameTelemetryService(addr, grpc.credentials.createInsecure())

  let call: grpc.ClientReadableStream<unknown> | null = null
  let retry: NodeJS.Timeout | null = null
  let last: unknown = null
  let running = false
  let status = 'stopped'

  function open(): void {
    if (!running) return
    status = 'connecting to game…'
    call = client.TelemetryStream({}) as grpc.ClientReadableStream<unknown>
    call.on('data', (frame: unknown) => {
      last = frame
      status = 'live'
    })
    call.on('error', (err: grpc.ServiceError) => {
      if (err.code === grpc.status.CANCELLED) return
      status = err.code === grpc.status.UNAVAILABLE ? 'game not found' : `error ${grpc.status[err.code]}`
      schedule()
    })
    call.on('end', () => {
      status = 'stream ended'
      schedule()
    })
  }

  function schedule(): void {
    call = null
    last = null
    if (running && !retry) retry = setTimeout(() => ((retry = null), open()), RETRY_MS)
  }

  return {
    name: 'live',
    status: () => status,
    start() {
      if (running) return
      running = true
      open()
      console.log(`Live: listening to the game on ${addr}`)
    },
    stop() {
      running = false
      if (retry) clearTimeout(retry)
      retry = null
      call?.cancel()
      call = null
      last = null
      status = 'stopped'
    },
    latest: () => last,
  }
}
