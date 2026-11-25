// Écran du téléphone / de la tablette : rester allumé (« Keep screen on ») et plein écran.
//
// Rester allumé :
// 1. API Wake Lock du navigateur : la bonne méthode, mais réservée aux pages sûres (HTTPS ou localhost).
//    Le téléphone ouvre l'appli en http://192.168.x.x:2950 → API refusée.
// 2. Repli : une vidéo muette noire lue en boucle. Chrome / Brave ne gardent l'écran allumé que pour
//    une vidéo VISIBLE et assez grande : elle couvre tout l'écran, derrière l'interface, quasi transparente.
//    Coût faible (64 × 64 px agrandie, décodage matériel).
// Le verrou saute quand l'onglet passe en arrière-plan : on le reprend au retour.
// Certains navigateurs exigent un geste de l'utilisateur : on réessaie à chaque toucher tant que ça n'a pas pris.
import { ref, watch } from 'vue'
import { settings } from './settings'

// off · system (API) · video (repli) · pending (en attente d'un toucher sur la page)
export type AwakeState = 'off' | 'system' | 'video' | 'pending'
export const awake = ref<AwakeState>('off')

const canApi = 'wakeLock' in navigator && window.isSecureContext
let sentinel: WakeLockSentinel | null = null
let video: HTMLVideoElement | null = null

function makeVideo(): HTMLVideoElement {
  const v = document.createElement('video')
  v.src = `${import.meta.env.BASE_URL}keepawake.mp4`
  v.muted = true
  v.loop = true
  v.playsInline = true
  v.setAttribute('aria-hidden', 'true')
  Object.assign(v.style, {
    position: 'fixed',
    inset: '0',
    width: '100vw',
    height: '100vh',
    objectFit: 'cover',
    zIndex: '-1', // sous l'interface, au-dessus du fond de page
    opacity: '0.01',
    pointerEvents: 'none',
  })
  document.body.appendChild(v)
  return v
}

// téléphone / tablette seulement : sur PC le réglage n'est pas proposé (l'écran sert déjà au jeu), et un ancien
// réglage coché ne doit pas y rester actif sans qu'on puisse le décocher
const touch = window.matchMedia('(pointer: coarse)').matches
const wanted = () => touch && settings.keepAwake

async function acquire(): Promise<void> {
  if (!wanted() || document.visibilityState !== 'visible') return
  if (sentinel || (video && !video.paused)) return // déjà actif
  if (canApi) {
    try {
      sentinel = await navigator.wakeLock.request('screen')
      sentinel.addEventListener('release', () => {
        sentinel = null
        if (settings.keepAwake) awake.value = 'pending'
      })
      awake.value = 'system'
      return
    } catch {
      /* refusé (batterie faible, pas de geste…) : repli sur la vidéo */
    }
  }
  video ??= makeVideo()
  try {
    await video.play()
    awake.value = 'video'
  } catch {
    awake.value = 'pending'
  }
}

function release(): void {
  void sentinel?.release()
  sentinel = null
  video?.pause()
  awake.value = 'off'
}

watch(wanted, (on) => (on ? void acquire() : release()), { immediate: true })
document.addEventListener('visibilitychange', () => void acquire())
window.addEventListener('pointerdown', () => void acquire(), { passive: true })

// ---- Plein écran -------------------------------------------------------------------
// Pas sur iPhone (Safari ne le permet que pour les vidéos) : le bouton est alors masqué.
export const canFullscreen = document.fullscreenEnabled === true
export const fullscreen = ref(false)
document.addEventListener('fullscreenchange', () => (fullscreen.value = !!document.fullscreenElement))

export function toggleFullscreen(): void {
  if (document.fullscreenElement) void document.exitFullscreen()
  else void document.documentElement.requestFullscreen({ navigationUI: 'hide' }).catch(() => {})
}
