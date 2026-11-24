// Sons d'alerte (Web Audio).
//
// Contrainte des navigateurs : pas de son avant une première interaction avec la page
// (clic, toucher, touche). On « déverrouille » l'audio à ce moment-là, une fois par chargement.
import { computed, ref } from 'vue'
import { ALERT_GROUPS, settings } from './settings'

// Bouton son de l'en-tête = interrupteur général des sons du menu (réglage « sound » de chaque alerte) :
//  - allumé dès qu'au moins une alerte a son son actif ; éteint quand toutes sont muettes ;
//  - un clic coupe (ou rallume) le son de toutes les alertes d'un coup.
const SOUNDED = ALERT_GROUPS.filter((g) => !('silent' in g)) // le flash de tir n'a pas de son
export const soundOn = computed(() => SOUNDED.some((g) => settings.sound[g.key]))

// Ancien réglage séparé du bouton (avant le son par alerte) : « off » devient « toutes muettes », une fois
const OLD_KEY = 'sc-companion.sound'
try {
  if (localStorage.getItem(OLD_KEY) === 'off') for (const g of SOUNDED) settings.sound[g.key] = false
  localStorage.removeItem(OLD_KEY)
} catch {
  /* stockage indisponible */
}

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
  const on = !soundOn.value
  for (const g of SOUNDED) settings.sound[g.key] = on
}

// Sons d'alerte : deux petits fichiers (interface/public/sounds), décodés une seule fois au
// déverrouillage de l'audio puis rejoués depuis la mémoire (~0,3 Mo une fois décodés).
//  - critical : « warning » de Lyubomir Ikonomov (Freesound 787777), début silencieux de 0,16 s coupé, 0,6 s
//  - warning  : « mechanical gas release alert » (Mixkit), partie utile seulement (0,56 s), plus discret
//  - info     : le son « warning » joué à l'envers (le « pfouit » montant devient un « pfiout » descendant),
//               copie inversée créée une fois au décodage, sans fichier de plus
type Level = 'critical' | 'warning' | 'info'
const FILES = { critical: '/sounds/critical.mp3', warning: '/sounds/warning.mp3' } as const
// volumes ajustés aux fichiers : le rouge reste nettement plus présent que l'orange
const VOLUME: Record<Level, number> = { critical: 0.4, warning: 0.6, info: 0.5 }
const buffers: Partial<Record<Level, AudioBuffer>> = {}
let loading = false

function reversed(c: AudioContext, buf: AudioBuffer): AudioBuffer {
  const out = c.createBuffer(buf.numberOfChannels, buf.length, buf.sampleRate)
  for (let ch = 0; ch < buf.numberOfChannels; ch++) out.getChannelData(ch).set(buf.getChannelData(ch).slice().reverse())
  return out
}

function load(): void {
  if (loading || !ctx) return
  loading = true
  for (const [level, url] of Object.entries(FILES) as [keyof typeof FILES, string][]) {
    fetch(url)
      .then((r) => r.arrayBuffer())
      .then((data) => ctx!.decodeAudioData(data))
      .then((buf) => {
        buffers[level] = buf
        if (level === 'warning') buffers.info = reversed(ctx!, buf)
      })
      .catch(() => { /* fichier absent : cette alerte reste muette */ })
  }
}

export function playAlert(level: Level): void {
  const buf = buffers[level]
  if (!soundOn.value || !ctx || ctx.state !== 'running' || !buf) return
  const src = ctx.createBufferSource()
  const gain = ctx.createGain()
  src.buffer = buf
  gain.gain.value = VOLUME[level]
  src.connect(gain).connect(ctx.destination)
  src.start() // la source est libérée toute seule à la fin de la lecture
}
