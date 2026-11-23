// Source « en direct » : flux gRPC TelemetryStream du jeu (127.0.0.1:2942 par défaut). Lecture seule.
//
// - Le jeu envoie ~17 trames/s mais le diffuseur n'en lit que 5 : on garde la dernière trame
//   en OCTETS BRUTS et on ne la décode qu'au moment où elle est lue (≈ 70 % de décodage en moins).
// - Si le jeu n'est pas lancé ou que le flux coupe : nouvelle tentative toutes les 5 s,
//   uniquement tant qu'un écran est connecté.
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import grpc from '@grpc/grpc-js'
import protoLoader from '@grpc/proto-loader'
import type { Source } from './source.ts'

const PROTO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../telemetrie/proto/sc_telemetry.proto')
const SERVICE = 'sc.game.telemetry.v1.GameTelemetryService'
const RETRY_MS = 5000

export function createLiveSource(addr = '127.0.0.1:2942'): Source & { status(): string } {
  const def = protoLoader.loadSync(PROTO, { keepCase: true, enums: String, longs: String, defaults: false })
  // Décodeur fourni par le schéma (octets → objet), utilisé seulement à la lecture
  const stream = (def[SERVICE] as grpc.ServiceDefinition).TelemetryStream
  const decode = stream.responseDeserialize as (b: Buffer) => unknown
  // Client gRPC qui ne décode rien : il remet les octets tels quels
  const Client = grpc.makeGenericClientConstructor(
    { TelemetryStream: { ...stream, responseDeserialize: (b: Buffer) => b } },
    'GameTelemetryService',
  )
  const client = new Client(addr, grpc.credentials.createInsecure())

  let call: grpc.ClientReadableStream<Buffer> | null = null
  let retry: NodeJS.Timeout | null = null
  let lastRaw: Buffer | null = null // dernière trame reçue, non décodée
  let last: unknown = null // dernière trame décodée (cache)
  let decodedFrom: Buffer | null = null // trame brute correspondant au cache
  let running = false
  let status = 'stopped'

  function open(): void {
    if (!running) return
    status = 'connecting to game…'
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    call = (client as any).TelemetryStream({}) as grpc.ClientReadableStream<Buffer>
    call.on('data', (raw: Buffer) => {
      lastRaw = raw
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
    lastRaw = null
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
      lastRaw = null
      last = null
      status = 'stopped'
    },
    // décodage à la demande, et seulement si une nouvelle trame est arrivée depuis la dernière lecture
    latest() {
      if (!lastRaw) return null
      if (lastRaw !== decodedFrom) {
        last = decode(lastRaw)
        decodedFrom = lastRaw
      }
      return last
    },
  }
}
