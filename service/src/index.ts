// Service SC Companion.
//
//   npm run replay                       rejoue telemetrie/captures
//   node src/index.ts --replay <fichier|dossier> [--port 2950]
//
// Accès : le PC toujours ; un autre appareil après avoir scanné le QR code de Mobile connect (jeton, access.ts).
// HTTP  GET /        → interface compilée (interface/dist), à ouvrir sur PC ou téléphone
//       GET /health  → état du service et sa mémoire (pour surveiller l'empreinte)
//       GET /lan     → adresses du PC sur le réseau local, avec le jeton (QR code « Mobile connect » de l'interface)
//       GET /history → mémoire de SC sur les 2 dernières heures (courbe zoomable de la bande RAM)
//       GET /sessions            → sessions de jeu enregistrées (résumés, la plus récente d'abord)
//       GET /sessions/<id>       → une session complète (mesures + événements)
//       POST /sessions/<id>/save | /unsave  → la garder indéfiniment ou la rendre à la rotation (5 gardées)
//       DELETE /sessions/<id>    → la supprimer (pas celle en cours)
//       /data/…      → données des vaisseaux et leur mise à jour (shipdata.ts)
// WS    /ws          → { type: 'snapshot', data } à la connexion, puis { type: 'patch', set, del } à 5 Hz max
//                    ← { type: 'config', leakRate?, leakDuration? } : réglages communs (config.ts), renvoyés en cfg.*
//                    ← { type: 'gameDir', action: 'browse' | 'auto' } : dossier du jeu (fenêtre de choix sur le PC,
//                      ou retour à la détection automatique), renvoyé en cfg.game_dir*
//                    ← { type: 'grpcEnv', action: 'enable' } : allume la télémétrie du jeu (grpcenv.ts), renvoyé en svc.grpc_env
import http from 'node:http'
import os from 'node:os'
import { WebSocketServer, type WebSocket } from 'ws'
import { diff, flatten, type Flat } from './flat.ts'
import { createReplaySource } from './sources/replay.ts'
import { createLazyLiveSource } from './sources/lazy.ts'
import type { Source } from './sources/source.ts'
import { createSystemMonitor } from './system.ts'
import { createGameLogReader } from './gamelog.ts'
import { configFlat, setGameDir, updateConfig } from './config.ts'
import { createSessionRecorder } from './sessions.ts'
import { gameDir, setForcedGameDir, setRunningGameDir } from './paths.ts'
import { pickGameFile } from './picker.ts'
import { TOKEN, allowed, checkAccess } from './access.ts'
import { enableGrpcEnv, grpcEnvEnabled } from './grpcenv.ts'
import { createTray, openUrl } from './tray.ts'
import { hasInterface, serveStatic } from './static.ts'
import { checkLatest, serveData } from './shipdata.ts'

const args = process.argv.slice(2)
const opt = (name: string): string | undefined => {
  const i = args.indexOf(`--${name}`)
  return i >= 0 ? args[i + 1] : undefined
}

const PORT = Number(opt('port') ?? 2950)
const TICK_MS = 200 // 5 envois par seconde au maximum

// Par défaut : le jeu en direct. --replay <fichier|dossier> pour rejouer des captures.
const replay = opt('replay')
setForcedGameDir(opt('game-dir'))
const source: Source = replay ? createReplaySource(replay) : createLazyLiveSource(gameDir, opt('addr'))
// Mesures et lecture du Game.log : en permanence (une mesure / 2 s), écran ouvert ou non, pour enregistrer
// les sessions de jeu. La télémétrie du jeu (source) est ouverte tant que le jeu tourne (ou qu'un écran est
// connecté) : sans écran, une seule trame décodée toutes les 2 s (siège, solde) ; la diffusion attend un écran.
const sessions = createSessionRecorder()
let gameRunning = false
const system = createSystemMonitor((s) => {
  sessions.onSample(s)
  gameRunning = s.scMb !== null
  setRunningGameDir(s.scDir) // dossier du jeu qui tourne : Game.log et schéma de télémétrie de ce jeu-là
  // infobulle de l'icône : état du jeu (texte changé seulement quand il change, au dixième de Go près)
  tray?.setTip(
    s.scMb === null
      ? 'SC Companion · game not running'
      : `SC Companion · Star Citizen ${(s.scMb / 1024).toFixed(1)} GB${sessions.current() ? ' · recording' : ''}`,
  )
  if (replay) return // captures rejouées : seulement avec un écran, comme avant
  if (gameRunning) source.start()
  else if (!clients.size) source.stop()
  if (!timer) { // pas d'écran : le diffuseur ne lit pas la télémétrie, on le fait ici
    const frame = source.latest()
    if (frame) observe(flatten(frame))
  }
}) // mémoire SC / système, CPU, GPU, fuite
const gameLog = createGameLogReader(gameDir, (e) => sessions.onEvent(e)) // mode de jeu, blessures, événements

// ---- Diffusion ------------------------------------------------------------------
let state: Flat = {} // dernier état envoyé aux écrans
let lastFrame: unknown = null // dernière trame du jeu traitée…
let frameFlat: Flat = {} // …et sa version à plat
let timer: NodeJS.Timeout | null = null
let seat: { on: boolean; cls: string } | null = null // aux commandes ? (null = pas encore de télémétrie)
let balance: number | null = null // solde aUEC (télémétrie)

// Télémétrie → siège du vaisseau (le Game.log ne note que la sortie), solde (argent gagné / dépensé de la
// session) et vie (coma / ranimé, gamelog.ts). Appelé avec une trame reçue : sans trame, on ne conclut rien.
function observe(fl: Flat): void {
  // le jeu n'envoie pas les valeurs nulles : vie absente mais maximum présent = vie à 0 (coma)
  const hp = fl['actor.vitals.health.current'] ?? (fl['actor.vitals.health.max'] !== undefined ? 0 : undefined)
  if (typeof hp === 'number') gameLog.setHealth(hp)
  const loco = fl['actor.state.locomotion']
  const cls = fl['vehicle.state.class_name']
  const seated = typeof loco === 'string' && loco.endsWith('SEATED') && typeof cls === 'string' && cls !== ''
  if (seat && seated !== seat.on) gameLog.seatEvent(seated, seated ? (cls as string) : seat.cls)
  seat = { on: seated, cls: seated ? (cls as string) : (seat?.cls ?? '') }
  const uec = Number(fl['actor.state.uec_balance'])
  if (fl['actor.state.uec_balance'] !== undefined && Number.isFinite(uec) && uec !== balance) {
    balance = uec
    sessions.onBalance(Date.now(), uec)
  }
}
const clients = new Set<WebSocket>()

function tick(): void {
  // Télémétrie du jeu (absente si le jeu ne tourne pas) + mesures système, dans le même état à plat.
  const frame = source.latest()
  if (frame !== lastFrame) { // même trame qu'au tick précédent : pas besoin de la remettre à plat
    lastFrame = frame
    frameFlat = frame ? flatten(frame) : {}
  }
  // Blessures : le log ne note pas la guérison. Une blessure baisse la santé max (ex. 95,16 au lieu de 100) ;
  // quand la santé max revient à 100, on considère que tout est soigné.
  const healthMax = frameFlat['actor.vitals.health.max']
  if (typeof healthMax === 'number' && healthMax >= 99.9) gameLog.clearInjuries()
  if (frame) observe(frameFlat)
  const live = sessions.current()
  // état du flux de télémétrie (live, game not found, stream ended…) : distinguer « chargement » et « jeu sans télémétrie »
  // + variable GRPC_CLIENT_SERVER_ENABLED présente sur le PC (grpcenv.ts)
  const tele = { 'svc.telemetry': source.status?.() ?? source.name, 'svc.grpc_env': grpcEnvEnabled() }
  const next = { ...frameFlat, ...system.flat(), ...gameLog.flat(), ...configFlat(), ...tele, ...(live ? { 'session.live': live } : {}) }
  const patch = diff(state, next)
  state = next
  if (!patch) return
  const msg = JSON.stringify({ type: 'patch', ...patch }) // sérialisé une seule fois pour tous les écrans
  for (const ws of clients) if (ws.readyState === ws.OPEN) ws.send(msg)
}

function onFirstClient(): void {
  source.start()
  system.setGpu(true) // la charge GPU ne sert qu'à l'affichage
  tick()
  timer = setInterval(tick, TICK_MS)
  console.log('Client connected: broadcasting started')
}

function onLastClientGone(): void {
  if (timer) clearInterval(timer)
  timer = null
  if (!gameRunning || replay) source.stop() // jeu lancé : la télémétrie reste ouverte (siège, solde)
  system.setGpu(false)
  state = {}
  console.log('No clients left: broadcasting paused')
}


// ---- Serveurs -------------------------------------------------------------------
// Adresses IPv4 du PC joignables depuis le téléphone : réseau privé d'abord (192.168 puis 10 puis 172.16-31,
// ce dernier étant souvent un adaptateur virtuel Hyper-V / WSL), sans boucle locale ni 169.254 (pas de DHCP).
function lanUrls(): string[] {
  const rank = (ip: string): number =>
    ip.startsWith('192.168.') ? 0 : ip.startsWith('10.') ? 1 : /^172.(1[6-9]|2d|3[01])./.test(ip) ? 2 : 3
  return Object.values(os.networkInterfaces())
    .flat()
    .filter((a) => a && a.family === 'IPv4' && !a.internal && !a.address.startsWith('169.254.'))
    .map((a) => a!.address)
    .sort((a, b) => rank(a) - rank(b))
    .map((ip) => `http://${ip}:${PORT}`)
}

// ---- Sessions (HTTP) -------------------------------------------------------------
function json(res: http.ServerResponse, code: number, body: unknown): void {
  res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' })
  res.end(JSON.stringify(body))
}

function serveSessions(req: http.IncomingMessage, res: http.ServerResponse): boolean {
  const m = req.url?.match(/^\/sessions(?:\/([\w-]+)(?:\/(save|unsave))?)?\/?$/)
  if (!m) return false
  const [, id, action] = m
  if (!id && req.method === 'GET') json(res, 200, sessions.list())
  else if (id && !action && req.method === 'GET') {
    const data = sessions.get(id)
    if (data) json(res, 200, data)
    else json(res, 404, { error: 'not found' })
  } else if (id && action && req.method === 'POST') json(res, sessions.setSaved(id, action === 'save') ? 200 : 404, {})
  else if (id && !action && req.method === 'DELETE') {
    const r = sessions.remove(id)
    json(res, r === 'ok' ? 200 : r === 'live' ? 409 : 404, { result: r })
  } else json(res, 405, { error: 'method not allowed' })
  return true
}

const server = http.createServer((req, res) => {
  if (!checkAccess(req, res)) return // autre appareil sans le jeton du QR code
  if (req.url === '/health') {
    const mem = process.memoryUsage()
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({
      source: source.name,
      status: source.status?.() ?? null,
      clients: clients.size,
      keys: Object.keys(state).length,
      rssMo: +(mem.rss / 2 ** 20).toFixed(1),
      heapMo: +(mem.heapUsed / 2 ** 20).toFixed(1),
    }))
    return
  }
  if (req.url === '/history') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    res.end(JSON.stringify(system.history()))
    return
  }
  if (serveSessions(req, res)) return
  if (req.url === '/lan') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    res.end(JSON.stringify({ port: PORT, urls: lanUrls().map((u) => `${u}/?k=${TOKEN}`) }))
    return
  }
  if (serveData(req, res)) return // données vaisseaux (avant l'interface : la copie à jour est prioritaire)
  if (serveStatic(req, res)) return // interface compilée
  res.writeHead(404).end()
})

const wss = new WebSocketServer({ server, path: '/ws', perMessageDeflate: false, verifyClient: ({ req }: { req: http.IncomingMessage }) => allowed(req) }) // compression inutile en local : du CPU pour rien

wss.on('connection', (ws) => {
  clients.add(ws)
  if (clients.size === 1) onFirstClient()
  ws.send(JSON.stringify({ type: 'snapshot', source: source.name, data: state }))
  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(String(raw)) as { type?: string; action?: string }
      if (msg.type === 'config') updateConfig(msg as Record<string, unknown>) // diffusé à tous au tick suivant
      else if (msg.type === 'gameDir' && msg.action === 'auto') setGameDir('')
      else if (msg.type === 'gameDir' && msg.action === 'browse') void pickGameFile(gameDir()).then((p) => p && setGameDir(p))
      else if (msg.type === 'grpcEnv' && msg.action === 'enable') enableGrpcEnv()
    } catch {
      /* message illisible : ignoré */
    }
  })
  ws.on('close', () => {
    clients.delete(ws)
    if (clients.size === 0) onLastClientGone()
  })
})

// Arrêt (Ctrl+C, fermeture, « Quit » de l'icône) : écrire les mesures en attente (la session reste ouverte,
// reprise au prochain démarrage) et retirer l'icône
function shutdown(): void {
  sessions.flush()
  tray?.remove()
  process.exit(0)
}
for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK'] as const) process.on(sig, shutdown)

// Icône dans la zone de notification (tray.ts) ; --no-tray pour s'en passer
let tray: ReturnType<typeof createTray> | null = null
function startTray(): void {
  if (process.platform !== 'win32' || args.includes('--no-tray')) return
  const url = (q = '') => `http://localhost:${PORT}/${q}`
  try {
    tray = createTray({
      open: () => openUrl(url()),
      sessions: () => openUrl(url('?sessions')),
      mobile: () => openUrl(url('?mobile')),
      quit: shutdown,
    })
  } catch (e) {
    console.error('Tray icon unavailable:', (e as Error).message)
  }
}

// Port déjà pris : SC Companion tourne déjà (on le dit et on s'arrête, sans rien toucher), ou un autre programme
// l'utilise. Les mesures ne démarrent qu'une fois le port obtenu : un second service lancé par erreur ne doit
// pas toucher aux sessions du premier (il clôturerait celle en cours).
async function onListenError(e: NodeJS.ErrnoException): Promise<void> {
  if (e.code !== 'EADDRINUSE') throw e
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/health`, { signal: AbortSignal.timeout(2000) })
    if (res.ok && 'clients' in ((await res.json()) as object)) {
      console.log(`SC Companion is already running: http://localhost:${PORT}`)
      process.exit(0)
    }
  } catch {
    /* pas SC Companion */
  }
  console.error(`Port ${PORT} is already used by another program. Start with --port <number> (e.g. --port ${PORT + 1}).`)
  process.exit(1)
}
server.on('error', (e) => void onListenError(e))
wss.on('error', () => {}) // même erreur, relayée par le serveur WebSocket : déjà traitée ci-dessus

server.listen(PORT, () => {
  // Démarrage des mesures ; le système d'abord : la session doit être ouverte avant que le Game.log n'envoie
  // ses événements
  system.start()
  gameLog.start()
  startTray()
  void checkLatest() // nouvelle version du jeu sur le wiki ? (un appel, en arrière-plan)
  console.log(`SC Companion service : http://localhost:${PORT}  (ws /ws, health /health)`)
  if (!hasInterface()) console.log('Interface not built yet: run "npm run build" in interface/')
})
