// Fenêtre Windows « Ouvrir » pour désigner le jeu (StarCitizen.exe ou Game.log), demandée depuis le menu.
// Ouverte par un PowerShell lancé le temps du choix seulement (~60 Mo, rendus à la fermeture) : une boîte de
// dialogue appelée dans le service bloquerait sa boucle d'événements (mesures, diffusion) tant qu'elle est ouverte.
// Elle s'ouvre sur le PC même si la demande vient du téléphone.
import { spawn } from 'node:child_process'

const SCRIPT = `
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
$d = New-Object System.Windows.Forms.OpenFileDialog -Property @{
  Title = 'SC Companion - select StarCitizen.exe (in Bin64) or Game.log of the game folder'
  Filter = 'Star Citizen (StarCitizen.exe, Game.log)|StarCitizen.exe;Game.log'
  InitialDirectory = $env:SCC_INITIAL_DIR
}
if ($d.ShowDialog($owner) -eq 'OK') { [Console]::Out.Write($d.FileName) }
`

let busy = false
/** Fenêtre de choix ouverte (envoyé aux écrans : cfg.game_dir_picking). */
export const picking = (): boolean => busy

/** Chemin choisi, ou null (annulé, ou une fenêtre déjà ouverte). */
export function pickGameFile(initialDir: string): Promise<string | null> {
  if (busy || process.platform !== 'win32') return Promise.resolve(null)
  busy = true
  return new Promise((resolve) => {
    const ps = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-STA', '-Command', SCRIPT], {
      env: { ...process.env, SCC_INITIAL_DIR: initialDir },
      stdio: ['ignore', 'pipe', 'ignore'],
      windowsHide: true,
    })
    let out = ''
    ps.stdout.setEncoding('utf8').on('data', (d: string) => (out += d))
    const done = () => {
      busy = false
      resolve(out.trim() || null)
    }
    ps.on('close', done)
    ps.on('error', () => ((out = ''), done()))
  })
}
