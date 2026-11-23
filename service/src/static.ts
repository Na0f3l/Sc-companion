// Sert l'interface compilée (interface/dist, produite par `npm run build` dans interface/).
//
// Pour jouer, c'est le service qui affiche l'interface : plus besoin du serveur de développement
// Vite (~500 Mo avec son processus npm). Fichiers lus à la demande ; les fichiers d'assets ont
// un nom avec empreinte (index-Abc123.js) et sont mis en cache longtemps par le navigateur.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import type http from 'node:http'

const DIST = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../interface/dist')

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.json': 'application/json',
}

export const hasInterface = (): boolean => fs.existsSync(path.join(DIST, 'index.html'))

/** Répond avec un fichier de l'interface ; renvoie false si la requête n'en est pas un. */
export function serveStatic(req: http.IncomingMessage, res: http.ServerResponse): boolean {
  if (req.method !== 'GET' && req.method !== 'HEAD') return false
  const url = decodeURIComponent((req.url ?? '/').split('?')[0])
  const rel = url === '/' ? 'index.html' : url.slice(1)
  const file = path.resolve(DIST, rel)
  if (!file.startsWith(DIST + path.sep)) return false // pas de sortie du dossier (../)
  let stat: fs.Stats
  try {
    stat = fs.statSync(file)
  } catch {
    return false
  }
  if (!stat.isFile()) return false
  const immutable = rel.startsWith('assets/')
  res.writeHead(200, {
    'content-type': TYPES[path.extname(file)] ?? 'application/octet-stream',
    'content-length': stat.size,
    'cache-control': immutable ? 'public, max-age=31536000, immutable' : 'no-cache',
  })
  if (req.method === 'HEAD') res.end()
  else fs.createReadStream(file).pipe(res)
  return true
}
