// Accès depuis le réseau local (téléphone, tablette) : sans rien à taper. Le PC lui-même a toujours accès ; un autre
// appareil doit avoir scanné le QR code de « Mobile connect », dont l'adresse contient un jeton (?k=…). À la
// première visite, le service le garde dans un cookie et renvoie à l'adresse sans jeton : les visites suivantes
// (favori, page rechargée) passent toutes seules.
//
// Protection volontairement légère : le service ne commande pas le jeu et ne connaît aucun identifiant. Le jeton
// évite seulement qu'un inconnu sur le même Wi-Fi (hôtel, colocation…) voie l'écran ou supprime les sessions.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import type http from 'node:http'
import { DATA_DIR } from './paths.ts'

const FILE = path.join(DATA_DIR, 'access-token')
const COOKIE = 'scc'

function loadToken(): string {
  try {
    const t = fs.readFileSync(FILE, 'utf8').trim()
    if (/^[\w-]{12,}$/.test(t)) return t
  } catch {
    /* premier lancement */
  }
  const t = crypto.randomBytes(12).toString('base64url') // 16 caractères
  try {
    fs.writeFileSync(FILE, t)
  } catch (e) {
    console.error('Could not save the access token:', (e as Error).message) // jeton valable jusqu'à l'arrêt
  }
  return t
}

/** Jeton à mettre dans l'adresse du QR code. */
export const TOKEN = loadToken()

/** Requête venue du PC lui-même (boucle locale, ou une de ses propres adresses). */
function isLocal(req: http.IncomingMessage): boolean {
  const from = req.socket.remoteAddress ?? ''
  return from === req.socket.localAddress || from === '127.0.0.1' || from === '::1' || from === '::ffff:127.0.0.1'
}

function cookieOk(req: http.IncomingMessage): boolean {
  return (req.headers.cookie ?? '').split(';').some((c) => c.trim() === `${COOKIE}=${TOKEN}`)
}

/** Connexion WebSocket autorisée ? (le navigateur envoie le cookie avec la demande de connexion) */
export const allowed = (req: http.IncomingMessage): boolean => isLocal(req) || cookieOk(req)

const DENIED = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SC Companion</title><body style="font:16px system-ui;background:#0b1418;color:#cfe;padding:24px;max-width:32em">
<h2>SC Companion</h2><p>To use this screen on another device, open <b>Menu › Mobile connect</b> on the PC and scan the QR code.</p>`

/**
 * Contrôle d'une requête HTTP : true si elle peut continuer. Sinon la réponse est déjà envoyée (cookie posé et
 * renvoi vers l'adresse sans jeton, ou page qui explique comment se connecter).
 */
export function checkAccess(req: http.IncomingMessage, res: http.ServerResponse): boolean {
  if (allowed(req)) return true
  const url = new URL(req.url ?? '/', 'http://x')
  if (url.searchParams.get('k') === TOKEN) {
    url.searchParams.delete('k')
    res.writeHead(302, {
      'set-cookie': `${COOKIE}=${TOKEN}; Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly`,
      location: url.pathname + url.search,
      'cache-control': 'no-store',
    })
    res.end()
    return false
  }
  res.writeHead(403, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
  res.end(DENIED)
  return false
}
