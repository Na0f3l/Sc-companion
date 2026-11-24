// Données statiques des vaisseaux (clé = class_name, comme dans la télémétrie), en deux fichiers :
//  - ships.json      : l'essentiel (vitesses, G…), chargé par l'interface au démarrage (alerte crash, barre de vitesse) ;
//  - ships-info.json : la fiche détaillée (rôle, dimensions, coque, blindage…), chargée à l'ouverture de la fiche.
//
// Sources :
//  - API du Star Citizen Wiki (https://api.star-citizen.wiki) : nom, constructeur, vitesses, rotations, carburant,
//    fiche. Valeurs tirées des fichiers du jeu ;
//  - SPViewer (https://www.spviewer.eu), données communautaires : accélérations en G mesurées en jeu.
//
// Deux emplacements :
//  - interface/public/data : copie livrée avec l'interface (et le mode démo), régénérée par `npm run ships` ici ;
//  - service/data : copie mise à jour depuis l'interface (bouton « Update ship data »), prioritaire quand elle existe.
// Au démarrage, le service compare la version des données à la version courante du jeu sur le wiki
// (/api/game-versions, ~1,5 Ko) ; l'interface propose la mise à jour si elles diffèrent.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import type http from 'node:http'

const WIKI = 'https://api.star-citizen.wiki/api/vehicles'
const WIKI_VERSIONS = 'https://api.star-citizen.wiki/api/game-versions'
const SPV = 'https://api.spviewer.eu/spvapi/data/community/public/vehicles'

const HERE = path.dirname(fileURLToPath(import.meta.url))
export const DEFAULT_DIR = path.resolve(HERE, '../../interface/public/data')
const BUILT_DIR = path.resolve(HERE, '../../interface/dist/data') // copie de DEFAULT_DIR faite par le build
export const USER_DIR = path.resolve(HERE, '../data')
const FILES = ['ships.json', 'ships-info.json']

type Num = number | null | undefined

interface WikiVehicle {
  class_name: string
  name: string
  version?: string
  manufacturer?: { name?: string; code?: string }
  speed?: { scm: Num; max: Num; boost_forward: Num; boost_backward: Num; scm_to_zero: Num; max_to_zero: Num }
  agility?: { pitch: Num; yaw: Num; roll: Num }
  fuel?: { capacity: Num }
  quantum?: { quantum_fuel_capacity: Num }
  // fiche détaillée
  role?: string
  sizes?: { length: Num; beam: Num; height: Num }
  mass_total?: Num
  cargo_capacity?: Num
  max_medical_tier?: Num
  health?: Num
  armor?: { health?: Num; damage_physical?: Num; damage_energy?: Num; damage_distortion?: Num }
}

interface Accel {
  Up: number
  Down: number
  Main: number
  Retro: number
  Strafe: number
}
interface SpvVehicle {
  class_name: string
  patch: string
  data?: { FlightCharacteristics?: { AccelerationG?: Accel & { Boosted?: Accel } } }
}

/** ships.json (les champs absents sont omis). */
export interface Ship {
  name: string
  maker?: string
  scm?: number // m/s
  nav?: number // m/s
  boost?: number // m/s, boost avant en SCM
  boostBack?: number
  stopScm?: number // s, de SCM à 0
  stopNav?: number // s, de NAV à 0
  rot?: [number, number, number] // °/s : pitch, yaw, roll
  hFuel?: number
  qFuel?: number
  /** G : [avant, arrière, haut, bas, latéral], puis les mêmes en boost (SPViewer) */
  g?: number[]
  gBoost?: number[]
  gPatch?: string
}

/** ships-info.json : seulement ce qui ne dépend pas des composants équipés (champs absents omis). */
export interface ShipDetail {
  role?: string
  dims?: [number, number, number] // m : longueur, largeur, hauteur
  mass?: number // kg
  cargo?: number // SCU
  medTier?: number
  hull?: number // HP
  armor?: number // HP
  armorDmg?: [number, number, number] // dégâts subis par le blindage : physique, énergie, distorsion (1 = plein)
}

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url, { headers: { Accept: 'application/json' }, signal: AbortSignal.timeout(30000) })
  if (!res.ok) throw new Error(`${url} → HTTP ${res.status}`)
  return (await res.json()) as T
}

const num = (v: Num): number | undefined => (typeof v === 'number' && v > 0 ? v : undefined)
const round = (v: Num, d = 0): number | undefined => (typeof v === 'number' && v > 0 ? +v.toFixed(d) : undefined)
const accel = (a: Accel): number[] => [a.Main, a.Retro, a.Up, a.Down, a.Strafe]
const sortKeys = <T>(o: Record<string, T>) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b)))

/** Télécharge les deux sources et construit les deux fichiers. */
export async function generate(log: (msg: string) => void = () => {}) {
  // Wiki : 50 véhicules par page au maximum
  const wiki: WikiVehicle[] = []
  for (let page = 1; ; page++) {
    const j = await getJson<{ data: WikiVehicle[]; meta: { last_page: number } }>(`${WIKI}?page%5Bsize%5D=50&page%5Bnumber%5D=${page}`)
    wiki.push(...j.data)
    log(`wiki page ${page}/${j.meta.last_page}`)
    if (page >= j.meta.last_page) break
  }
  const spv = (await getJson<{ data: { vehicles: SpvVehicle[] } }>(SPV)).data.vehicles

  const ships: Record<string, Ship> = {}
  const details: Record<string, ShipDetail> = {}
  for (const v of wiki) {
    if (v.class_name.endsWith('_Display')) continue // maquettes exposées en concession
    details[v.class_name] = {
      role: v.role || undefined,
      dims: num(v.sizes?.length) ? [v.sizes!.length as number, v.sizes!.beam as number, v.sizes!.height as number] : undefined,
      mass: round(v.mass_total),
      cargo: round(v.cargo_capacity),
      medTier: round(v.max_medical_tier),
      hull: round(v.health),
      armor: round(v.armor?.health),
      armorDmg:
        typeof v.armor?.damage_physical === 'number'
          ? ([v.armor.damage_physical, v.armor.damage_energy ?? 1, v.armor.damage_distortion ?? 1].map((x) => +(x as number).toFixed(2)) as [number, number, number])
          : undefined,
    }
    const sp = v.speed
    const a = v.agility
    ships[v.class_name] = {
      name: v.name,
      maker: v.manufacturer?.name,
      scm: num(sp?.scm),
      nav: num(sp?.max),
      boost: num(sp?.boost_forward),
      boostBack: num(sp?.boost_backward),
      stopScm: num(sp?.scm_to_zero),
      stopNav: num(sp?.max_to_zero),
      rot: num(a?.pitch) ? [a!.pitch as number, a!.yaw as number, a!.roll as number] : undefined,
      hFuel: num(v.fuel?.capacity),
      qFuel: num(v.quantum?.quantum_fuel_capacity),
    }
  }

  let withG = 0
  const noWiki: string[] = []
  for (const v of spv) {
    const g = v.data?.FlightCharacteristics?.AccelerationG
    if (!g) continue
    const s = (ships[v.class_name] ??= { name: v.class_name.replaceAll('_', ' ') })
    if (!s.maker) noWiki.push(v.class_name)
    s.g = accel(g)
    if (g.Boosted) s.gBoost = accel(g.Boosted)
    s.gPatch = v.patch
    withG++
  }

  const generated = new Date().toISOString().slice(0, 10)
  const version = wiki[0]?.version ?? null
  const sorted = sortKeys(ships)
  log(`${Object.keys(sorted).length} véhicules (${Object.values(sorted).filter((s) => s.scm).length} avec vitesses, ${withG} avec G)`)
  if (noWiki.length) log(`Absents du wiki (G seuls) : ${noWiki.join(', ')}`)
  return {
    'ships.json': {
      generated,
      version,
      sources: ['Star Citizen Wiki API (api.star-citizen.wiki)', 'SPViewer community data (spviewer.eu)'],
      ships: sorted,
    },
    'ships-info.json': { generated, version, ships: sortKeys(details) },
  }
}

/** Écrit les deux fichiers (fichier temporaire puis renommage : jamais de fichier à moitié écrit servi). */
export function write(dir: string, data: Awaited<ReturnType<typeof generate>>): void {
  fs.mkdirSync(dir, { recursive: true })
  for (const name of FILES) {
    const tmp = path.join(dir, `${name}.tmp`)
    fs.writeFileSync(tmp, JSON.stringify(data[name as keyof typeof data]) + '\n')
    fs.renameSync(tmp, path.join(dir, name))
  }
}

/** En-tête d'un ships.json (null si absent ou illisible). */
function readHead(dir: string): { generated: string; version: string | null } | null {
  try {
    const j = JSON.parse(fs.readFileSync(path.join(dir, 'ships.json'), 'utf8')) as { generated: string; version: string | null }
    return { generated: j.generated, version: j.version }
  } catch {
    return null
  }
}

/**
 * Dossier servi : la copie la plus récente (date de génération) entre la mise à jour (service/data) et celle
 * de l'interface compilée (ou ses sources). Choisi au démarrage et après chaque mise à jour, pas à chaque requête.
 */
function pickDir(): { dir: string; version: string | null } {
  let best = { dir: DEFAULT_DIR, version: null as string | null, generated: '' }
  for (const dir of [USER_DIR, BUILT_DIR, DEFAULT_DIR]) {
    const h = readHead(dir)
    if (h && h.generated > best.generated) best = { dir, ...h }
  }
  return best
}
let served = pickDir()
const dataDir = () => served.dir

// ---- État et mise à jour, pour l'interface ----
const status = { version: served.version, latest: null as string | null, updating: false, error: null as string | null }

/** Version courante du jeu selon le wiki (un seul appel, ~1,5 Ko). Silencieux hors ligne. */
export async function checkLatest(): Promise<void> {
  try {
    const j = await getJson<{ data: { code: string; channel: string; is_default: boolean }[] }>(WIKI_VERSIONS)
    status.latest = (j.data.find((v) => v.is_default) ?? j.data.find((v) => v.channel === 'live'))?.code ?? null
    if (status.latest && status.latest !== status.version) console.log(`Ship data ${status.version} → update available (${status.latest})`)
  } catch {
    /* pas de réseau : pas de proposition de mise à jour */
  }
}

let running: Promise<void> | null = null
/** Régénère les données dans service/data (une seule mise à jour à la fois). */
export function update(): Promise<void> {
  running ??= (async () => {
    status.updating = true
    status.error = null
    try {
      write(USER_DIR, await generate((m) => console.log(`Ship data: ${m}`)))
      served = pickDir()
      status.version = served.version
    } catch (e) {
      status.error = e instanceof Error ? e.message : String(e)
      console.log(`Ship data update failed: ${status.error}`)
    } finally {
      status.updating = false
      running = null
    }
  })()
  return running
}

function json(res: http.ServerResponse, body: unknown): void {
  res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
  res.end(JSON.stringify(body))
}

/**
 * Routes /data/… : GET ships.json / ships-info.json (copie la plus récente), GET status, POST update
 * (répond une fois la mise à jour finie, ~10 à 20 s). Renvoie false si la requête n'en est pas une.
 */
export function serveData(req: http.IncomingMessage, res: http.ServerResponse): boolean {
  const url = (req.url ?? '').split('?')[0]
  if (url === '/data/status' && req.method === 'GET') {
    json(res, status)
    return true
  }
  if (url === '/data/update' && req.method === 'POST') {
    void update().then(() => json(res, status))
    return true
  }
  const name = url.slice('/data/'.length)
  if (url.startsWith('/data/') && FILES.includes(name) && req.method === 'GET') {
    const file = path.join(dataDir(), name)
    if (!fs.existsSync(file)) return false
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-cache' })
    fs.createReadStream(file).pipe(res)
    return true
  }
  return false
}

// `npm run ships` (depuis service/) : régénère la copie livrée avec l'interface (interface/public/data)
if (import.meta.main) {
  write(DEFAULT_DIR, await generate(console.log))
  console.log(`→ ${DEFAULT_DIR} (puis npm run build dans interface/)`)
}
