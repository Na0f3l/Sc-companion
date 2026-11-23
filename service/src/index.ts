// Service SC Companion.
//
//   npm run replay                       rejoue telemetrie/captures
//   node src/index.ts --replay <fichier|dossier> [--port 2950]
//
// HTTP  GET /health  → état du service et sa mémoire (pour surveiller l'empreinte)
// WS    /ws          → { type: 'snapshot', data } à la connexion, puis { type: 'patch', set, del } à 5 Hz max
import http from 'node:http'
import { WebSocketServer, type WebSocket } from 'ws'
import { diff, flatten, type Flat } from './flat.ts'
import { createReplaySource } from './sources/replay.ts'
import type { Source } from './sources/source.ts'

const args = process.argv.slice(2)
const opt = (name: string): string | undefined => {
  const i = args.indexOf(`--${name}`)
  return i >= 0 ? args[i + 1] : undefined
}

const PORT = Number(opt('port') ?? 2950)
const TICK_MS = 200 // 5 envois par seconde au maximum

const replay = opt('replay')
if (!replay) {
  console.error('Source manquante. Pour l’instant : --replay <capture.json | dossier>')
  process.exit(2)
}
const source: Source = createReplaySource(replay)

// ---- Diffusion ------------------------------------------------------------------
let state: Flat = {} // dernier état envoyé aux écrans
let timer: NodeJS.Timeout | null = null
const clients = new Set<WebSocket>()

function tick(): void {
  const frame = source.latest()
  if (!frame) return
  const next = flatten(frame)
  const patch = diff(state, next)
  state = next
  if (!patch) return
  const msg = JSON.stringify({ type: 'patch', ...patch }) // sérialisé une seule fois pour tous les écrans
  for (const ws of clients) if (ws.readyState === ws.OPEN) ws.send(msg)
}

function onFirstClient(): void {
  source.start()
  tick()
  timer = setInterval(tick, TICK_MS)
  console.log('Écran connecté : diffusion démarrée')
}

function onLastClientGone(): void {
  if (timer) clearInterval(timer)
  timer = null
  source.stop()
  state = {}
  console.log('Plus aucun écran : diffusion en pause')
}

// ---- Serveurs -------------------------------------------------------------------
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    const mem = process.memoryUsage()
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({
      source: source.name,
      clients: clients.size,
      keys: Object.keys(state).length,
      rssMo: +(mem.rss / 2 ** 20).toFixed(1),
      heapMo: +(mem.heapUsed / 2 ** 20).toFixed(1),
    }))
    return
  }
  res.writeHead(404).end()
})

const wss = new WebSocketServer({ server, path: '/ws', perMessageDeflate: false }) // compression inutile en local : du CPU pour rien

wss.on('connection', (ws) => {
  clients.add(ws)
  if (clients.size === 1) onFirstClient()
  ws.send(JSON.stringify({ type: 'snapshot', source: source.name, data: state }))
  ws.on('close', () => {
    clients.delete(ws)
    if (clients.size === 0) onLastClientGone()
  })
})

server.listen(PORT, () => console.log(`SC Companion service : http://localhost:${PORT}  (ws /ws, santé /health)`))
