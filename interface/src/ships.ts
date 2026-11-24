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

/** Données du vaisseau, ou undefined s'il est inconnu (nouveau vaisseau, variante absente des sources). */
export function shipInfo(className: string): Ship | undefined {
  return SHIPS.value[className]
}

/** Nom affiché : nom du jeu si connu, sinon le class_name rendu lisible. */
export function shipName(className: string): string {
  return SHIPS.value[className]?.name ?? className.replaceAll('_', ' ')
}
