<script setup lang="ts">
// Fenêtre « Mobile connect » (ouverte depuis le menu, voir AppMenu) : QR code vers l'adresse du PC sur le réseau local, à scanner avec
// le téléphone, et une aide en cas de souci (réseau privé, pare-feu…).
// Affiché seulement quand la page est ouverte sur le PC lui-même (localhost) : sur le téléphone, ça ne sert à rien.
// Le générateur de QR code n'est chargé qu'à l'ouverture (import dynamique) : rien en mémoire le reste du temps.
import { ref } from 'vue'

const onPc = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname)

const dlg = ref<HTMLDialogElement | null>(null)
const urls = ref<string[]>([])
const url = ref('')
const qr = ref<{ size: number; path: string } | null>(null)
const error = ref('')
const help = ref(false)

async function open(): Promise<void> {
  help.value = false
  error.value = ''
  dlg.value?.showModal()
  try {
    const res = await fetch('/lan', { cache: 'no-store' })
    if (!res.ok) throw new Error()
    urls.value = ((await res.json()) as { urls: string[] }).urls
  } catch {
    urls.value = []
    // service arrêté, ou plus ancien que la route /lan (pas redémarré depuis la mise à jour)
    error.value = "Couldn't get this PC's network address. Restart SC Companion and try again."
    return
  }
  if (!urls.value.length) {
    error.value = 'This PC is not connected to a local network.'
    help.value = true
    return
  }
  if (!urls.value.includes(url.value)) url.value = urls.value[0]!
  await draw()
}

// le menu affiche l'entrée « Mobile connect » (si onPc) et ouvre la fenêtre
defineExpose({ open, onPc })

async function draw(): Promise<void> {
  const { default: qrcode } = await import('qrcode-generator')
  const q = qrcode(0, 'M')
  q.addData(url.value)
  q.make()
  const n = q.getModuleCount()
  // un seul chemin SVG : un carré de 1 × 1 par module foncé
  let path = ''
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (q.isDark(y, x)) path += `M${x} ${y}h1v1h-1z`
  qr.value = { size: n, path }
}

// clic sur le fond (en dehors de la boîte) : fermer
function onClick(e: MouseEvent): void {
  if (e.target === dlg.value) dlg.value?.close()
}

const PORT = location.port || '2950'
// adresse sans le jeton d'accès (?k=…, service/src/access.ts) : il est dans le QR code, inutile de l'afficher
const bare = (u: string) => u.replace(/\/?\?k=.*$/, '')
</script>

<template>
  <template v-if="onPc">

    <dialog ref="dlg" class="box" aria-labelledby="mc-title" @click="onClick">
      <header>
        <h2 id="mc-title">Mobile connect</h2>
        <button type="button" class="x" aria-label="Close" @click="dlg?.close()">✕</button>
      </header>

      <p v-if="error" class="err">{{ error }}</p>
      <template v-else-if="qr">
        <p class="lead">Scan with your phone's camera. Phone and PC must be on the same Wi-Fi network.</p>
        <!-- fond clair obligatoire : beaucoup de lecteurs ne lisent pas un QR code inversé -->
        <svg class="qr" :viewBox="`-3 -3 ${qr.size + 6} ${qr.size + 6}`" shape-rendering="crispEdges" role="img" :aria-label="`QR code: ${url}`">
          <rect x="-3" y="-3" :width="qr.size + 6" :height="qr.size + 6" fill="#fff" />
          <path :d="qr.path" fill="#000" />
        </svg>
        <p class="url">{{ bare(url) }}</p>
        <p class="lead">The code holds a private key: only devices that scanned it can open this screen.</p>
        <!-- plusieurs cartes réseau (Ethernet + Wi-Fi, VPN…) : choisir celle du réseau du téléphone -->
        <label v-if="urls.length > 1" class="pick">
          <span>Network address</span>
          <select v-model="url" @change="draw">
            <option v-for="u in urls" :key="u" :value="u">{{ bare(u) }}</option>
          </select>
        </label>
      </template>

      <button type="button" class="more" :aria-expanded="help" @click="help = !help">
        Having issues? <span class="caret" :class="{ up: help }">▾</span>
      </button>
      <div v-if="help" class="help">
        <ol>
          <li><b>Same network.</b> The phone must be on the same Wi-Fi as the PC: not on mobile data, not on a guest Wi-Fi.</li>
          <li>
            <b>Private network.</b> On the PC: Settings › Network &amp; internet › Wi-Fi (or Ethernet) › your network ›
            Network profile type: <b>Private</b>. On a <i>Public</i> network, Windows blocks connections from other devices.
          </li>
          <li>
            <b>Firewall.</b> If Windows asks whether to allow Node.js, tick <i>Private networks</i>. Otherwise, run once in
            PowerShell <i>as administrator</i>:
            <code>New-NetFirewallRule -DisplayName "SC Companion (LAN)" -Direction Inbound -Protocol TCP -LocalPort {{ PORT }} -Profile Private -RemoteAddress LocalSubnet -Action Allow</code>
            A <i>Block</i> rule for Node.js wins over this one: check Windows Defender Firewall › Advanced settings › Inbound rules.
          </li>
          <li><b>VPN.</b> A VPN on the PC or the phone can hide the local network: turn it off to test.</li>
          <li><b>Router.</b> Some routers isolate Wi-Fi devices from each other ("AP / client isolation"): disable it in the router settings.</li>
          <li><b>Address changed?</b> The PC address can change after a restart: scan the code again.</li>
        </ol>
      </div>
    </dialog>
  </template>
</template>

<style scoped lang="scss">
button:focus-visible,
select:focus-visible {
  outline: 2px solid var(--amber);
  outline-offset: 1px;
}

.box {
  width: min(440px, calc(100vw - 32px));
  max-height: calc(100vh - 32px);
  padding: 14px 16px 16px;
  border: 1px solid var(--cyan-dim);
  // coins refermés dans le fond : la fenêtre peut défiler, un pseudo-élément qui déborde ferait
  // apparaître les barres de défilement (le faux « relief » en bas et à droite)
  @include bevel-edges-bg(10px, var(--cyan-dim), var(--panel));
  color: var(--text);
  @include bevel(10px);

  &::backdrop {
    background: rgb(0 0 0 / 65%);
  }
}

header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

h2 {
  margin: 0;
  @include label;
  color: var(--cyan);
}

.x {
  padding: 2px 6px;
  border: 0;
  background: none;
  color: var(--muted);
  cursor: pointer;

  &:hover {
    color: var(--cyan);
  }
}

p {
  margin: 0 0 10px;
  font: 500 12px/1.45 var(--font-ui);
  letter-spacing: 0.02em;
}

.lead {
  color: var(--muted);
}

.err {
  color: var(--amber);
}

.qr {
  display: block;
  width: min(240px, 70vw);
  margin: 0 auto 10px;
}

.url {
  text-align: center;
  color: var(--cyan);
  font-family: var(--font-num, var(--font-ui));
  font-size: 14px;
  user-select: all;
}

.pick {
  display: flex;
  justify-content: center;
  align-items: center;
  gap: 8px;
  margin-bottom: 10px;
  color: var(--muted);
  font: 500 11px var(--font-ui);

  select {
    padding: 3px 6px;
    border: 1px solid var(--line);
    background: var(--bg, #000);
    color: var(--text);
    font: inherit;
  }
}

.more {
  padding: 0;
  border: 0;
  background: none;
  color: var(--cyan-dim);
  font: 500 11px var(--font-ui);
  letter-spacing: 0.08em;
  text-transform: uppercase;
  cursor: pointer;

  &:hover,
  &[aria-expanded='true'] {
    color: var(--cyan);
  }
}

.caret {
  display: inline-block;
  transition: transform 0.15s;

  &.up {
    transform: rotate(180deg);
  }
}

.help ol {
  margin: 10px 0 0;
  padding-left: 18px;
  font: 500 12px/1.45 var(--font-ui);
  letter-spacing: 0.02em;
  color: var(--muted);

  li + li {
    margin-top: 8px;
  }

  b {
    color: var(--text);
  }
}

code {
  display: block;
  margin: 6px 0;
  padding: 6px 8px;
  border: 1px solid var(--line);
  background: rgb(0 0 0 / 35%);
  color: var(--text);
  font: 11px/1.4 ui-monospace, Consolas, monospace;
  overflow-wrap: anywhere;
  user-select: all;
}
</style>
