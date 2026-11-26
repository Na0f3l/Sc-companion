// Mini-jeu de l'écran d'attente : un vaisseau, un champ de rochers à fragmenter.
// Un seul <canvas> en fond, aucune bibliothèque. Coût : ~1-2 % CPU pendant l'attente, zéro en jeu
// (la boucle s'arrête quand l'écran d'attente disparaît, et le navigateur la suspend si l'onglet est caché).
// Les rochers, le vaisseau et les tirs rebondissent / s'arrêtent sur le radar et sur le bloc de texte.
// Sans joueur, un pilote automatique joue tout seul (mode démo). L'état de la partie survit au
// changement d'écran d'attente (menu → chargement), il est gardé ici au niveau du module.
import { reactive } from 'vue'

type V = { x: number; y: number }
type Rock = V & { vx: number; vy: number; r: number; size: 1 | 2 | 3; a: number; va: number; shape: number[]; grow: number }
type Shot = V & { vx: number; vy: number; life: number }
type Spark = V & { vx: number; vy: number; life: number; a: number; len: number }
type Circle = { x: number; y: number; r: number }
type Rect = { l: number; t: number; r: number; b: number }

const FPS = 30
const SHIP_R = 10
const TURN = 4.2 // rad/s
const SPIN_UP = 30 // rad/s² : pleine vitesse de rotation en ~0,14 s
const SPIN_STOP = 22 // rad/s² : s'arrête en ~0,2 s une fois la touche relâchée
const THRUST = 160 // px/s²
const VMAX = 208
const BOOST = 2.75 // Maj : poussée ×2,75 (même poussée boost qu’avant)…
const BOOST_VMAX = 420 // …et vitesse max relevée, qui retombe en douceur au relâchement
const SHOT_V = 540
// portée des tirs : ~55 % du plus petit côté du terrain (pas de tir qui fait le tour d'un téléphone), 180 à 460 px
const shotLife = () => Math.max(180, Math.min(460, 0.55 * Math.min(W, H))) / SHOT_V
const GROW = 1.2 // s : une nouvelle vague « approche » (grossit) avant d'être active
const SHOT_MAX = 6
const SHOT_GAP = 0.17
const AUTO_SHOT_GAP = 0.7 // pilote auto : tir posé, pas en rafale
const ROCK_R = { 1: 12, 2: 22, 3: 40 } as const
const POINTS = { 1: 100, 2: 50, 3: 20 } as const
const BEST_KEY = 'scc.rockfield.best'

// Ce que l'interface affiche (mis à jour seulement quand une valeur change)
export const hud = reactive({ playing: false, score: 0, lives: 3, best: Number(localStorage.getItem(BEST_KEY)) || 0, over: false })

// --- état de la partie (persiste entre deux montages) ---
const ship = { x: 0, y: 0, vx: 0, vy: 0, a: -Math.PI / 2, va: 0, alive: true, respawn: 0, shield: 0, thrusting: false, boosting: false }
let rocks: Rock[] = []
let shots: Shot[] = []
let sparks: Spark[] = []
let wave = 0
let cooldown = 0
let overTimer = 0
let idleTimer = 0 // secondes sans touche en partie → retour démo
let started = false
const keys = { left: false, right: false, up: false, fire: false, boost: false }
let touchAim: V | null = null

// --- contexte d'affichage ---
let W = 0
let H = 0
let circle: Circle | null = null
let rects: Rect[] = []
let colors = { ship: '#63e4dd', rock: '#23707a', shot: '#f2c23b', boom: '#ff5b4f' }

const rnd = (a: number, b: number) => a + Math.random() * (b - a)

function makeRock(x: number, y: number, size: 1 | 2 | 3): Rock {
  const sp = rnd(20, 50) * (1 + (3 - size) * 0.45) * (1 + Math.min(wave, 8) * 0.06)
  const dir = rnd(0, Math.PI * 2)
  return {
    x, y, size, r: ROCK_R[size],
    vx: Math.cos(dir) * sp, vy: Math.sin(dir) * sp,
    a: rnd(0, 6.28), va: rnd(-1, 1),
    shape: Array.from({ length: 9 + size }, () => rnd(0.72, 1.12)),
    grow: 1,
  }
}

// Place libre : loin du vaisseau et hors des obstacles
function freeSpot(margin: number): V {
  for (let i = 0; i < 40; i++) {
    const p = { x: rnd(0, W), y: rnd(0, H) }
    if (Math.hypot(p.x - ship.x, p.y - ship.y) < 180) continue
    if (blocked(p, margin)) continue
    return p
  }
  return { x: rnd(0, W), y: 0 }
}

function blocked(p: V, m: number) {
  if (circle && Math.hypot(p.x - circle.x, p.y - circle.y) < circle.r + m) return true
  for (const rect of rects) if (p.x > rect.l - m && p.x < rect.r + m && p.y > rect.t - m && p.y < rect.b + m) return true
  return false
}

function newWave() {
  wave++
  const n = Math.min(3 + wave, 9)
  for (let i = 0; i < n; i++) {
    const p = freeSpot(50)
    rocks.push({ ...makeRock(p.x, p.y, 3), grow: 0 })
  }
}

function placeShip() {
  // en bas au centre de préférence, sinon la place libre la plus proche
  const p = { x: W / 2, y: H * 0.8 }
  for (let i = 0; i < 30 && (blocked(p, 30) || rocks.some((k) => Math.hypot(k.x - p.x, k.y - p.y) < k.r + 60)); i++) {
    p.x = rnd(40, W - 40)
    p.y = rnd(40, H - 40)
  }
  Object.assign(ship, { x: p.x, y: p.y, vx: 0, vy: 0, a: -Math.PI / 2, va: 0, alive: true, shield: 2 })
}

function reset(playing: boolean) {
  rocks = []
  shots = []
  wave = 0
  hud.playing = playing
  hud.over = false
  hud.score = 0
  hud.lives = 3
  idleTimer = 0
  placeShip()
  newWave()
}

function boom(x: number, y: number, n: number, color = false) {
  for (let i = 0; i < n; i++) {
    const d = rnd(0, 6.28)
    const s = rnd(30, 140)
    sparks.push({ x, y, vx: Math.cos(d) * s, vy: Math.sin(d) * s, life: rnd(0.4, 0.9), a: rnd(0, 6.28), len: color ? rnd(4, 10) : rnd(2, 5) })
  }
}

function addScore(n: number) {
  if (!hud.playing) return
  hud.score += n
  if (hud.score > hud.best) {
    hud.best = hud.score
    localStorage.setItem(BEST_KEY, String(hud.best))
  }
}

function splitRock(i: number) {
  const k = rocks[i]!
  rocks.splice(i, 1)
  boom(k.x, k.y, 4 + k.size * 2)
  addScore(POINTS[k.size])
  if (k.size > 1) {
    const s = (k.size - 1) as 1 | 2
    rocks.push(makeRock(k.x, k.y, s), makeRock(k.x, k.y, s))
  }
}

function killShip() {
  ship.alive = false
  boom(ship.x, ship.y, 14, true)
  if (!hud.playing) {
    ship.respawn = 1.5
    return
  }
  hud.lives--
  if (hud.lives <= 0) {
    hud.over = true
    overTimer = 4
  } else ship.respawn = 2
}

// --- obstacles : rebond (réflexion de la vitesse sur la normale) ---
function bounce(o: { x: number; y: number; vx: number; vy: number }, r: number, damp: number): boolean {
  let hit = false
  if (circle) {
    const dx = o.x - circle.x
    const dy = o.y - circle.y
    const d = Math.hypot(dx, dy)
    if (d < circle.r + r && d > 0) {
      const nx = dx / d
      const ny = dy / d
      o.x = circle.x + nx * (circle.r + r)
      o.y = circle.y + ny * (circle.r + r)
      reflect(o, nx, ny, damp)
      hit = true
    }
  }
  for (const rect of rects) {
    const cx = Math.max(rect.l, Math.min(o.x, rect.r))
    const cy = Math.max(rect.t, Math.min(o.y, rect.b))
    let dx = o.x - cx
    let dy = o.y - cy
    let d = Math.hypot(dx, dy)
    if (d < r) {
      if (d === 0) {
        // centre à l'intérieur du bloc : sortie par le bord le plus proche
        const out = [o.x - rect.l, rect.r - o.x, o.y - rect.t, rect.b - o.y]
        const m = out.indexOf(Math.min(...out))
        dx = m === 0 ? -1 : m === 1 ? 1 : 0
        dy = m === 2 ? -1 : m === 3 ? 1 : 0
        o.x = m === 0 ? rect.l - r : m === 1 ? rect.r + r : o.x
        o.y = m === 2 ? rect.t - r : m === 3 ? rect.b + r : o.y
      } else {
        dx /= d
        dy /= d
        o.x = cx + dx * r
        o.y = cy + dy * r
      }
      reflect(o, dx, dy, damp)
      hit = true
    }
  }
  return hit
}

function reflect(o: { vx: number; vy: number }, nx: number, ny: number, damp: number) {
  const dot = o.vx * nx + o.vy * ny
  if (dot >= 0) return // déjà en train de s'éloigner
  o.vx = (o.vx - 2 * dot * nx) * damp
  o.vy = (o.vy - 2 * dot * ny) * damp
}

const wrap = (o: V, r: number) => {
  if (o.x < -r) o.x += W + 2 * r
  else if (o.x > W + r) o.x -= W + 2 * r
  if (o.y < -r) o.y += H + 2 * r
  else if (o.y > H + r) o.y -= H + 2 * r
}

const angleTo = (from: number, to: number) => Math.atan2(Math.sin(to - from), Math.cos(to - from))
// écart d’angle en tenant compte de l’inertie : on relâche avant la cible pour s’y arrêter (pilote auto, tactile)
const aimDiff = (want: number) => angleTo(ship.a, want) - (ship.va * Math.abs(ship.va)) / (2 * SPIN_STOP)

// --- pilote automatique (démo) : vise le rocher le plus proche, tire quand il est aligné ---
function autopilot(): typeof keys {
  const out = { left: false, right: false, up: false, fire: false, boost: false }
  let best: Rock | null = null
  let bd = Infinity
  for (const k of rocks) {
    const d = Math.hypot(k.x - ship.x, k.y - ship.y)
    if (d < bd) {
      bd = d
      best = k
    }
  }
  if (!best) return out
  const t = bd / SHOT_V // anticipation du déplacement
  const want = Math.atan2(best.y + best.vy * t - ship.y, best.x + best.vx * t - ship.x)
  const diff = aimDiff(want)
  out.left = diff < -0.06
  out.right = diff > 0.06
  out.fire = Math.abs(diff) < 0.18 && bd < 420
  // recule doucement si un rocher arrive trop près, avance un peu s'ils sont tous loin
  out.up = (bd > 380 && Math.hypot(ship.vx, ship.vy) < 60) || (bd < best.r + 50 && Math.abs(diff) > 2.4)
  return out
}

function touchControls(): typeof keys {
  const out = { left: false, right: false, up: false, fire: true, boost: false }
  if (!touchAim) return out
  const want = Math.atan2(touchAim.y - ship.y, touchAim.x - ship.x)
  const diff = aimDiff(want)
  out.left = diff < -0.08
  out.right = diff > 0.08
  out.up = Math.abs(diff) < 0.5 && Math.hypot(touchAim.x - ship.x, touchAim.y - ship.y) > 120
  return out
}

function step(dt: number) {
  // contrôles
  const playerInput = keys.left || keys.right || keys.up || keys.fire || keys.boost || touchAim
  if (hud.playing && !hud.over) {
    idleTimer = playerInput ? 0 : idleTimer + dt
    if (idleTimer > 45) reset(false) // joueur parti : retour à la démo
  }
  const c = !hud.playing ? autopilot() : touchAim ? touchControls() : keys

  // vaisseau
  if (ship.alive) {
    // rotation avec un peu d'inertie : montée rapide jusqu'à TURN, arrêt en douceur au relâchement
    const want = ((c.right ? 1 : 0) - (c.left ? 1 : 0)) * TURN
    const acc = (want === 0 ? SPIN_STOP : SPIN_UP) * dt
    ship.va += Math.max(-acc, Math.min(acc, want - ship.va))
    ship.a += ship.va * dt
    // Maj seule pousse aussi : le boost n'a pas besoin de la flèche
    ship.boosting = c.boost
    ship.thrusting = c.up || c.boost
    if (ship.thrusting) {
      const f = THRUST * (c.boost ? BOOST : 1) * dt
      ship.vx += Math.cos(ship.a) * f
      ship.vy += Math.sin(ship.a) * f
    }
    // vol découplé : aucun frottement, le vecteur est gardé tant qu'on ne pousse pas dans un autre sens
    const v = Math.hypot(ship.vx, ship.vy)
    // au-delà de la limite (boost relâché), la vitesse redescend en douceur au lieu d'être coupée net
    const cap = c.boost ? BOOST_VMAX : Math.max(VMAX, v - 400 * dt)
    if (v > cap) {
      ship.vx *= cap / v
      ship.vy *= cap / v
    }
    ship.x += ship.vx * dt
    ship.y += ship.vy * dt
    wrap(ship, SHIP_R)
    bounce(ship, SHIP_R, 0.5)
    if (ship.shield > 0) ship.shield -= dt

    cooldown -= dt
    if (c.fire && cooldown <= 0 && shots.length < SHOT_MAX) {
      cooldown = hud.playing ? SHOT_GAP : AUTO_SHOT_GAP
      shots.push({
        x: ship.x + Math.cos(ship.a) * SHIP_R,
        y: ship.y + Math.sin(ship.a) * SHIP_R,
        vx: ship.vx + Math.cos(ship.a) * SHOT_V,
        vy: ship.vy + Math.sin(ship.a) * SHOT_V,
        life: shotLife(),
      })
    }
  } else if (hud.over) {
    overTimer -= dt
    if (overTimer <= 0) reset(false)
  } else {
    ship.respawn -= dt
    if (ship.respawn <= 0) placeShip()
  }

  // rochers
  for (const k of rocks) {
    k.x += k.vx * dt
    k.y += k.vy * dt
    k.a += k.va * dt
    if (k.grow < 1) k.grow = Math.min(1, k.grow + dt / GROW)
    wrap(k, k.r)
    bounce(k, k.r * 0.9, 1)
  }

  // tirs : touchent un rocher, ou s'arrêtent sur un obstacle
  for (let i = shots.length - 1; i >= 0; i--) {
    const s = shots[i]!
    s.x += s.vx * dt
    s.y += s.vy * dt
    s.life -= dt
    wrap(s, 0)
    let dead = s.life <= 0
    if (!dead && blocked(s, 0)) {
      boom(s.x, s.y, 3)
      dead = true
    }
    if (!dead) {
      const j = rocks.findIndex((k) => k.grow >= 1 && Math.hypot(k.x - s.x, k.y - s.y) < k.r)
      if (j >= 0) {
        splitRock(j)
        dead = true
      }
    }
    if (dead) shots.splice(i, 1)
  }

  // vaisseau contre rochers
  if (ship.alive && ship.shield <= 0) {
    const j = rocks.findIndex((k) => k.grow >= 1 && Math.hypot(k.x - ship.x, k.y - ship.y) < k.r * 0.85 + SHIP_R * 0.7)
    if (j >= 0) {
      splitRock(j)
      killShip()
    }
  }

  for (let i = sparks.length - 1; i >= 0; i--) {
    const p = sparks[i]!
    p.x += p.vx * dt
    p.y += p.vy * dt
    p.life -= dt
    if (p.life <= 0) sparks.splice(i, 1)
  }

  if (!rocks.length) newWave()
}

function draw(g: CanvasRenderingContext2D) {
  g.clearRect(0, 0, W, H)
  g.lineWidth = 1.4
  g.lineJoin = 'round'

  g.strokeStyle = colors.rock
  for (const k of rocks) {
    // en approche : petit et pâle, grossit jusqu'à sa taille (sans collision tant qu'il n'y est pas)
    const sc = k.grow < 1 ? 1 - (1 - k.grow) ** 2 : 1
    g.globalAlpha = k.grow < 1 ? 0.25 + 0.6 * k.grow : 1
    g.beginPath()
    const n = k.shape.length
    for (let i = 0; i < n; i++) {
      const a = k.a + (i / n) * Math.PI * 2
      const r = k.r * sc * k.shape[i]!
      const x = k.x + Math.cos(a) * r
      const y = k.y + Math.sin(a) * r
      if (i) g.lineTo(x, y)
      else g.moveTo(x, y)
    }
    g.closePath()
    g.stroke()
  }
  g.globalAlpha = 1

  if (ship.alive && (ship.shield <= 0 || Math.floor(ship.shield * 8) % 2 === 0)) {
    const { x, y, a } = ship
    const pt = (d: number, ang: number) => [x + Math.cos(a + ang) * d, y + Math.sin(a + ang) * d] as const
    g.strokeStyle = colors.ship
    g.beginPath()
    g.moveTo(...pt(SHIP_R * 1.4, 0))
    g.lineTo(...pt(SHIP_R, 2.5))
    g.lineTo(...pt(SHIP_R * 0.45, Math.PI))
    g.lineTo(...pt(SHIP_R, -2.5))
    g.closePath()
    g.stroke()
    if (ship.thrusting && (ship.boosting || Math.random() > 0.25)) {
      // boost : flamme plus longue, rouge, sans scintillement
      g.strokeStyle = ship.boosting ? colors.boom : colors.shot
      g.beginPath()
      g.moveTo(...pt(SHIP_R * 0.7, 2.75))
      g.lineTo(...pt(SHIP_R * (ship.boosting ? rnd(2.2, 3) : rnd(1.2, 1.8)), Math.PI))
      g.lineTo(...pt(SHIP_R * 0.7, -2.75))
      g.stroke()
    }
  }

  g.fillStyle = colors.shot
  for (const s of shots) g.fillRect(s.x - 1.5, s.y - 1.5, 3, 3)

  g.strokeStyle = colors.boom
  g.beginPath()
  for (const p of sparks) {
    g.moveTo(p.x, p.y)
    g.lineTo(p.x + Math.cos(p.a) * p.len, p.y + Math.sin(p.a) * p.len)
  }
  g.stroke()
}

// --- clavier / tactile ---
const KEYMAP: Record<string, keyof typeof keys> = {
  ArrowLeft: 'left', KeyA: 'left', // KeyA = Q en AZERTY (position physique)
  ArrowRight: 'right', KeyD: 'right',
  ArrowUp: 'up', KeyW: 'up', // KeyW = Z en AZERTY
  Space: 'fire',
  ShiftLeft: 'boost', ShiftRight: 'boost',
}

function typing(t: EventTarget | null) {
  const el = t as HTMLElement | null
  return !!el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))
}

function onKey(e: KeyboardEvent) {
  const k = KEYMAP[e.code]
  if (!k || e.ctrlKey || e.altKey || e.metaKey || typing(e.target)) return
  const down = e.type === 'keydown'
  // Maj sert aussi à Maj+Tab et aux majuscules : on note juste son état, sans bloquer la touche,
  // sans retirer le focus et sans lancer de partie à lui seul
  if (k === 'boost') {
    keys.boost = down
    return
  }
  // Espace sur un bouton : laisser le bouton fonctionner ; une flèche libère le focus pour jouer ensuite
  if (document.activeElement instanceof HTMLButtonElement) {
    if (k === 'fire') return
    if (down) document.activeElement.blur()
  }
  e.preventDefault() // pas de défilement de la page
  keys[k] = down
  if (down && (!hud.playing || hud.over)) reset(true)
}

function interactive(t: EventTarget | null) {
  return t instanceof Element && !!t.closest('button, a, input, select, textarea, label, [role="dialog"], header')
}

function onPointer(e: PointerEvent) {
  if (e.pointerType !== 'touch') return
  if (e.type === 'pointerdown') {
    if (interactive(e.target)) return
    if (!hud.playing || hud.over) reset(true)
    touchAim = { x: e.clientX, y: e.clientY }
  } else if (e.type === 'pointermove') {
    if (touchAim) touchAim = { x: e.clientX, y: e.clientY }
  } else touchAim = null
}

function onBlur() {
  keys.left = keys.right = keys.up = keys.fire = keys.boost = false
  touchAim = null
}

// --- démarrage / arrêt ---
// canvas : le fond ; obstacles() renvoie le radar et le bloc de texte en coordonnées de la fenêtre
export function startRockfield(canvas: HTMLCanvasElement, obstacles: () => { circle: Circle | null; rects: Rect[] }) {
  const g = canvas.getContext('2d')!
  let raf = 0
  let last = 0
  let colorAge = 0

  const readColors = () => {
    const s = getComputedStyle(document.documentElement)
    const v = (n: string, d: string) => s.getPropertyValue(n).trim() || d
    colors = { ship: v('--cyan', colors.ship), rock: v('--cyan-dim', colors.rock), shot: v('--amber', colors.shot), boom: v('--red', colors.boom) }
  }
  // le terrain s'arrête au-dessus de la bande RAM (fixée en bas), sinon tout passerait dessous
  const floor = () => {
    const band = document.querySelector('.membar .band')?.getBoundingClientRect()
    // pas de min avec innerHeight : sur Chrome Android il reste parfois sur l'ancienne valeur en passant en plein écran
    return Math.round(band && band.height ? band.top : document.documentElement.clientHeight)
  }
  const layout = () => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    W = document.documentElement.clientWidth
    H = floor()
    canvas.style.height = `${H}px`
    canvas.width = Math.round(W * dpr)
    canvas.height = Math.round(H * dpr)
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    ;({ circle, rects } = obstacles())
  }
  const relayout = () => {
    if (floor() !== H || document.documentElement.clientWidth !== W) layout()
    else ({ circle, rects } = obstacles())
  }

  layout()
  readColors()
  if (!started) {
    started = true
    reset(false)
  }

  const frame = (now: number) => {
    raf = requestAnimationFrame(frame)
    if (now - last < 1000 / FPS - 2) return
    const dt = last ? Math.min((now - last) / 1000, 0.05) : 0
    last = now
    colorAge += dt
    if (colorAge > 1) {
      colorAge = 0
      readColors() // le thème change selon les alertes (rouge, vert…)
      relayout()
    }
    step(dt)
    draw(g)
  }
  raf = requestAnimationFrame(frame)

  const ro = new ResizeObserver(relayout)
  ro.observe(document.body)
  window.addEventListener('resize', layout)
  document.addEventListener('fullscreenchange', layout)
  window.visualViewport?.addEventListener('resize', relayout)
  window.addEventListener('scroll', relayout, { passive: true })
  window.addEventListener('keydown', onKey)
  window.addEventListener('keyup', onKey)
  window.addEventListener('pointerdown', onPointer)
  window.addEventListener('pointermove', onPointer)
  window.addEventListener('pointerup', onPointer)
  window.addEventListener('pointercancel', onPointer)
  window.addEventListener('blur', onBlur)

  return () => {
    cancelAnimationFrame(raf)
    ro.disconnect()
    window.removeEventListener('resize', layout)
    document.removeEventListener('fullscreenchange', layout)
    window.visualViewport?.removeEventListener('resize', relayout)
    window.removeEventListener('scroll', relayout)
    window.removeEventListener('keydown', onKey)
    window.removeEventListener('keyup', onKey)
    window.removeEventListener('pointerdown', onPointer)
    window.removeEventListener('pointermove', onPointer)
    window.removeEventListener('pointerup', onPointer)
    window.removeEventListener('pointercancel', onPointer)
    window.removeEventListener('blur', onBlur)
    onBlur()
  }
}
