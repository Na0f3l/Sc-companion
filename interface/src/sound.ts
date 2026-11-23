// Sons d'alerte (Web Audio).
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
    load()
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

// Sons d'alerte : deux petits fichiers (interface/public/sounds), décodés une seule fois au
// déverrouillage de l'audio puis rejoués depuis la mémoire (~0,3 Mo une fois décodés).
//  - critical : « warning » de Lyubomir Ikonomov (Freesound 787777), début silencieux de 0,16 s coupé, 0,6 s
//  - warning  : « mechanical gas release alert » (Mixkit), partie utile seulement (0,56 s), plus discret
const FILES = { critical: '/sounds/critical.mp3', warning: '/sounds/warning.mp3' } as const
// volumes ajustés aux fichiers : le rouge reste nettement plus présent que l'orange
const VOLUME = { critical: 0.4, warning: 0.6 } as const
const buffers: Partial<Record<keyof typeof FILES, AudioBuffer>> = {}
let loading = false

function load(): void {
  if (loading || !ctx) return
  loading = true
  for (const [level, url] of Object.entries(FILES) as [keyof typeof FILES, string][]) {
    fetch(url)
      .then((r) => r.arrayBuffer())
      .then((data) => ctx!.decodeAudioData(data))
      .then((buf) => (buffers[level] = buf))
      .catch(() => { /* fichier absent : cette alerte reste muette */ })
  }
}

export function playAlert(level: 'critical' | 'warning'): void {
  const buf = buffers[level]
  if (!soundOn.value || !ctx || ctx.state !== 'running' || !buf) return
  const src = ctx.createBufferSource()
  const gain = ctx.createGain()
  src.buffer = buf
  gain.gain.value = VOLUME[level]
  src.connect(gain).connect(ctx.destination)
  src.start() // la source est libérée toute seule à la fin de la lecture
}
