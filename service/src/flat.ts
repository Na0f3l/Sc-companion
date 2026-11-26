// Mise à plat d'une trame et calcul des différences.
//
// { vehicle: { state: { flight: { instruments: { speed: 12.3 } } } } }
//   → { "vehicle.state.flight.instruments.speed": 12.3 }
//
// À plat, comparer deux états revient à comparer deux listes de clés : simple et rapide.
// Côté interface, chaque clé est observée séparément par Vue, donc seul ce qui change est redessiné.

export type Value = string | number | boolean
export type Flat = Record<string, Value>
export interface Patch {
  set: Flat
  del: string[]
}

// Tronqué à 2 décimales : en dessous, l'écran ne montre pas la différence,
// et ça évite d'envoyer des micro-variations (la faim baisse de 0,0007 par trame).
// Tronqué et non arrondi, comme le jeu : 4,78/4,8 de H-Fuel = 0,9958 → 0,99 (99 % en jeu), pas 1.
// Petite marge (1e-4 centième) pour les flottants juste sous un cran : 0,99999994 (plein) → 1.
// Les très grandes valeurs (3,4e38 = « pas de mesure » envoyé par le jeu) sont gardées telles quelles.
function round(v: number): number {
  if (Number.isInteger(v) || Math.abs(v) > 1e15) return v
  return Math.trunc(v * 100 + Math.sign(v) * 1e-4) / 100
}

export function flatten(obj: unknown, prefix = '', out: Flat = {}): Flat {
  if (obj === null || typeof obj !== 'object') return out
  for (const [k, v] of Object.entries(obj)) {
    if (v === null || v === undefined) continue
    const key = prefix ? `${prefix}.${k}` : k
    if (typeof v === 'object') flatten(v, key, out) // les tableaux aussi : clés 0, 1, 2…
    else if (typeof v === 'number') out[key] = round(v)
    else if (typeof v === 'string' || typeof v === 'boolean') out[key] = v
  }
  return out
}

// Ce qui a changé de prev à next. null si rien.
// Une clé absente de next est supprimée : le jeu omet les champs qui valent false / 0.
export function diff(prev: Flat, next: Flat): Patch | null {
  const set: Flat = {}
  const del: string[] = []
  let changed = false
  for (const k in next) {
    if (prev[k] !== next[k]) {
      set[k] = next[k]
      changed = true
    }
  }
  for (const k in prev) {
    if (!(k in next)) {
      del.push(k)
      changed = true
    }
  }
  return changed ? { set, del } : null
}
