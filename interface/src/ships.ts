// Données statiques par vaisseau (clé = class_name de la télémétrie), servies par le service
// (service/src/shipdata.ts : copie à jour, ou celle livrée dans public/data).
// Chargées au démarrage (~70 Ko) ; rechargées après une mise à jour (bouton « Update ship data »).
// shallowRef : tout ce qui lit shipInfo() se recalcule tout seul quand les données arrivent.
import { ref, shallowRef } from 'vue'

export interface Ship {
  name: string
  maker?: string
  scm?: number // m/s
  nav?: number // m/s
  boost?: number // m/s, boost avant en SCM
  boostBack?: number
  stopScm?: number // s, de SCM à 0
  stopNav?: number // s, de NAV à 0
  rot?: number[] // °/s : pitch, yaw, roll
  hFuel?: number
  qFuel?: number
  /** G : [avant, arrière, haut, bas, latéral] (SPViewer) */
  g?: number[]
  gBoost?: number[]
  gPatch?: string
}

const SHIPS = shallowRef<Record<string, Ship>>({})
/** Version du jeu des données (wiki), ex. « 4.10.3-LIVE.13165946 ». */
export const shipsVersion = ref<string | null>(null)
/** Change à chaque rechargement : la fiche détaillée (ShipInfo) se recharge aussi. */
export const shipsStamp = ref(0)

/** Adresse d'un fichier de données (relative : marche aussi en hébergement statique, mode démo). */
export const dataUrl = (name: string): string => `${import.meta.env.BASE_URL}data/${name}`

export async function loadShips(): Promise<void> {
  try {
    const j = (await (await fetch(dataUrl('ships.json'), { cache: 'no-cache' })).json()) as { version: string | null; ships: Record<string, Ship> }
    SHIPS.value = j.ships
    shipsVersion.value = j.version
    shipsStamp.value++
  } catch {
    /* données indisponibles : vitesses apprises, nom brut du vaisseau */
  }
}
void loadShips()

/**
 * Clé des données pour un class_name : lui-même s'il est connu, sinon le modèle de base en retirant les
 * suffixes un à un (DRAK_Vulture_Teach → DRAK_Vulture : éditions spéciales absentes des sources).
 */
export function shipKey(className: string): string | undefined {
  let k = className
  for (;;) {
    if (SHIPS.value[k]) return k
    const i = k.lastIndexOf('_')
    if (i <= 0) return undefined
    k = k.slice(0, i)
  }
}

/** Données du vaisseau (ou de son modèle de base), ou undefined s'il est inconnu (nouveau vaisseau). */
export function shipInfo(className: string): Ship | undefined {
  const k = shipKey(className)
  return k ? SHIPS.value[k] : undefined
}

/**
 * Vaisseaux dont le nom contient tous les mots tapés (nom ou constructeur, sans casse), noms commençant par la
 * saisie d'abord. Un seul résultat par nom : les variantes internes au même nom (« _BIS2950 », « _GS »…) sont
 * écartées au profit du class_name le plus court, le vaisseau de base.
 */
export function searchShips(query: string, max = 8): { key: string; name: string; maker?: string }[] {
  const q = query.trim().toLowerCase()
  if (!q) return []
  const words = q.split(/\s+/)
  const byName = new Map<string, string>()
  for (const [key, s] of Object.entries(SHIPS.value)) {
    const hay = `${s.name} ${s.maker ?? ''}`.toLowerCase()
    if (!words.every((w) => hay.includes(w))) continue
    const prev = byName.get(s.name)
    if (!prev || key.length < prev.length) byName.set(s.name, key)
  }
  const starts = (n: string) => (n.toLowerCase().startsWith(q) ? 0 : 1)
  return [...byName]
    .sort(([a], [b]) => starts(a) - starts(b) || a.localeCompare(b))
    .slice(0, max)
    .map(([name, key]) => ({ key, name, maker: SHIPS.value[key]!.maker }))
}

/** Nom affiché : nom du jeu si connu, sinon le class_name rendu lisible. */
export function shipName(className: string): string {
  if (SHIPS.value[className]) return SHIPS.value[className].name
  const base = shipInfo(className)
  // variante inconnue : nom du modèle de base + le suffixe (« Vulture Teach »)
  const k = shipKey(className)
  return base && k ? `${base.name} ${className.slice(k.length + 1).replaceAll('_', ' ')}` : className.replaceAll('_', ' ')
}
