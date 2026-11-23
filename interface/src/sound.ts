// Sons d'alerte synthétisés (Web Audio) : aucun fichier, quelques oscillateurs le temps d'un bip.
//
// Contrainte des navigateurs : pas de son avant une première interaction avec la page
// (clic, toucher, touche). On « déverrouille » l'audio à ce moment-là, une fois par chargement.
import { ref } from 'vue'

const KEY = 'sc-companion.sound'
function loadPref(): boolean {
  try {
    return localStorage.getItem(KEY) !== 'off'
  } catch {
    return true
  }
}

export const soundOn = ref(loadPref())
export const soundUnlocked = ref(false)

let ctx: AudioContext | null = null

function unlock(): void {
  try {
    ctx ??= new AudioContext()
    void ctx.resume().then(() => (soundUnlocked.value = ctx?.state === 'running'))
  } catch {
    /* audio indisponible : on reste silencieux */
  }
}
for (const ev of ['pointerdown', 'keydown'] as const) window.addEventListener(ev, unlock, { passive: true })

export function toggleSound(): void {
  soundOn.value = !soundOn.value
  try {
    localStorage.setItem(KEY, soundOn.value ? 'on' : 'off')
  } catch {
    /* stockage indisponible : réglage gardé le temps de la session */
  }
}

// Un bip : oscillateur + enveloppe de volume (attaque et relâche courtes pour éviter les « clics »)
function beep(freq: number, start: number, dur: number, type: OscillatorType, volume: number): void {
  if (!ctx) return
  const t = ctx.currentTime + start
  const osc = ctx.createOscillator()
  const gain = ctx.createGain()
  osc.type = type
  osc.frequency.value = freq
  gain.gain.setValueAtTime(0, t)
  gain.gain.linearRampToValueAtTime(volume, t + 0.01)
  gain.gain.setValueAtTime(volume, t + dur - 0.03)
  gain.gain.linearRampToValueAtTime(0, t + dur)
  osc.connect(gain).connect(ctx.destination)
  osc.start(t)
  osc.stop(t + dur) // l'oscillateur est libéré tout seul après l'arrêt
}

// Seules les alertes importantes (critical) sonnent ; les secondaires (warning) sont silencieuses.
export function playAlert(level: 'critical' | 'warning'): void {
  if (level !== 'critical' || !soundOn.value || !ctx || ctx.state !== 'running') return
  // alarme deux tons, 2 fois : aigu / grave / aigu / grave
  ;[880, 660, 880, 660].forEach((f, i) => beep(f, i * 0.17, 0.15, 'square', 0.06))
}
