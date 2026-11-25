// Tracé d'une courbe dans le temps (chemins SVG), commun à la bande RAM (RamTimeline) et à l'analyse de session
// (SessionChart). Réduction : par case de temps, le minimum et le maximum seulement (les pics restent visibles
// quand on dézoome) ; la courbe s'interrompt là où il manque des mesures (jeu fermé).

export interface CurveOptions {
  T: readonly number[] // temps (ms), croissants
  V: readonly (number | null)[] // valeurs (null ou NaN = pas de mesure)
  from: number // ms : bord gauche du dessin
  to: number // ms : bord droit du dessin
  width: number // unités du dessin (viewBox)
  height: number
  buckets?: number
  gapMs?: number // plus long sans mesure : la courbe s'interrompt
  extendTo?: number // ms : prolonge la dernière valeur jusque-là (direct)
  min?: number // échelle fixe (sinon automatique sur les valeurs affichées)
  max?: number
}

export interface Curve {
  line: string
  area: string
  bridge: string // pointillés reliant les bords des vrais trous (pas de mesure : portion déduite, pas mesurée)
  lo: number // échelle utilisée
  hi: number
  y: (v: number) => number
}

const bad = (v: number | null | undefined): v is null | undefined => v === null || v === undefined || Number.isNaN(v)

/** Premier indice dont le temps est ≥ t (recherche dichotomique). */
export function lowerBound(T: readonly number[], t: number): number {
  let a = 0, b = T.length
  while (a < b) {
    const m = (a + b) >> 1
    if (T[m]! < t) a = m + 1
    else b = m
  }
  return a
}

export function buildCurve(o: CurveOptions): Curve {
  const { T, V, from, to, width, height } = o
  const buckets = o.buckets ?? 300
  const gap = o.gapMs ?? 6000
  const i0 = Math.max(0, lowerBound(T, from) - 1)
  const i1 = Math.min(T.length, lowerBound(T, to) + 1)

  const pts: [number, number][] = [] // NaN = coupure
  const step = (to - from) / buckets
  let bucket = -1, minI = -1, maxI = -1
  const gaps: [number, number, number, number][] = [] // [t, v] avant / après chaque vrai trou
  let prevRaw = -Infinity
  let prevV = NaN // temps de la mesure réelle précédente (les trous se jugent sur les mesures, pas sur les
  // points gardés : dézoomé, deux points gardés peuvent être espacés de plus de `gap` sans qu'il manque rien)
  const flush = () => {
    if (minI < 0) return
    const a = Math.min(minI, maxI), b = Math.max(minI, maxI)
    pts.push([T[a]!, V[a]!])
    if (b !== a) pts.push([T[b]!, V[b]!])
  }
  for (let i = i0; i < i1; i++) {
    const v = V[i]
    if (bad(v)) { flush(); minI = maxI = bucket = -1; pts.push([T[i]!, NaN]); continue }
    // vrai trou (jeu fermé, service arrêté) : la courbe s'interrompt, ses bords sont reliés en pointillés
    if (T[i]! - prevRaw > gap && prevRaw > -Infinity) {
      flush()
      minI = maxI = bucket = -1
      pts.push([T[i]! - 1, NaN])
      gaps.push([prevRaw, prevV, T[i]!, v])
    }
    prevRaw = T[i]!
    prevV = v
    const k = Math.floor((T[i]! - from) / step)
    if (k !== bucket) { flush(); bucket = k; minI = maxI = i; continue }
    if (v < V[minI]!) minI = i
    if (v > V[maxI]!) maxI = i
  }
  flush()
  const last = pts[pts.length - 1]
  if (o.extendTo !== undefined && last && !Number.isNaN(last[1])) pts.push([o.extendTo, last[1]])

  const vals = pts.map((p) => p[1]).filter((v) => !Number.isNaN(v))
  let lo = o.min, hi = o.max
  if (lo === undefined || hi === undefined) {
    const dMin = vals.length ? Math.min(...vals) : 0
    const dMax = vals.length ? Math.max(...vals) : 1
    const pad = Math.max((dMax - dMin) * 0.1, Math.abs(dMax) * 0.002, 1e-6)
    lo ??= dMin - pad
    hi ??= dMax + pad
  }
  const span = hi - lo || 1
  const x = (t: number) => (((t - from) / (to - from)) * width).toFixed(1)
  const y = (v: number) => height - 1 - Math.min(1, Math.max(0, (v - lo!) / span)) * (height - 2)

  // remplissage : chaque segment descend à la base sous son dernier point, puis se referme (Z) sur son début
  let line = '', area = '', lastX = '', open = false
  for (const [t, v] of pts) {
    if (Number.isNaN(v)) { // coupure (marquée ci-dessus, sur les mesures réelles)
      if (open) area += `L${lastX} ${height}Z`
      open = false
      continue
    }
    const px = x(t), py = y(v).toFixed(1)
    line += `${open ? 'L' : 'M'}${px} ${py}`
    area += open ? `L${px} ${py}` : `M${px} ${height}L${px} ${py}`
    lastX = px
    open = true
  }
  if (open) area += `L${lastX} ${height}Z`
  const bridge = gaps.map(([t0, v0, t1, v1]) => `M${x(t0)} ${y(v0).toFixed(1)}L${x(t1)} ${y(v1).toFixed(1)}`).join('')
  return { line, area, bridge, lo, hi, y }
}
