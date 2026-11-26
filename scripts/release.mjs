// Fabrique la version publiée : un zip portable pour Windows, à dézipper puis lancer (SC Companion.exe), sans rien
// installer.
//
//   node scripts/release.mjs            → release/SC-Companion-<version>-win-x64.zip
//   node scripts/release.mjs --no-build → sans recompiler l'interface
//
// Contenu : SC Companion.exe (lanceur, launcher/Launcher.cs compilé ici), node\node.exe (Node officiel, même version
// que celui qui lance ce script, empreinte vérifiée) et sa licence, le service (src + dépendances de production
// seulement), l'interface compilée, README et LICENSE. Pas d'outil PowerShell (memoire/) ni d'outils de télémétrie.
// Le lanceur est aussi copié à la racine du dépôt (ignoré par Git) : il y lance le service avec le Node du PC.
// Version : celle de interface/package.json (recopiée dans service/package.json).
import { execFileSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(import.meta.dirname, '..')
const OUT = path.join(ROOT, 'release')
const CACHE = path.join(OUT, '.cache')
const TAR = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tar.exe') // bsdtar de Windows : lit et écrit les zip
// npm passe par cmd.exe sous Windows (npm.cmd n'est pas un exécutable)
const npm = (args, cwd) => (process.platform === 'win32' ? run('cmd.exe', ['/d', '/c', 'npm', ...args], cwd) : run('npm', args, cwd))

const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'))
const run = (cmd, args, cwd) => execFileSync(cmd, args, { cwd, stdio: 'inherit' })
const step = (msg) => console.log(`\n▸ ${msg}`)

// ---- Version ----------------------------------------------------------------------
const version = readJson(path.join(ROOT, 'interface', 'package.json')).version
const svcPkgFile = path.join(ROOT, 'service', 'package.json')
const svcPkg = readJson(svcPkgFile)
if (svcPkg.version !== version) {
  svcPkg.version = version
  fs.writeFileSync(svcPkgFile, JSON.stringify(svcPkg, null, 2) + '\n')
  console.log(`service/package.json → ${version}`)
}
const name = `SC-Companion-${version}-win-x64`
const stage = path.join(OUT, name)
const app = path.join(stage, 'SC Companion') // dossier unique dans le zip

// ---- Interface --------------------------------------------------------------------
if (!process.argv.includes('--no-build')) {
  step('Building the interface')
  npm(['run', 'build'], path.join(ROOT, 'interface'))
}
if (!fs.existsSync(path.join(ROOT, 'interface', 'dist', 'index.html'))) throw new Error('interface/dist missing: build it first')

// ---- Node officiel ----------------------------------------------------------------
const nodeVer = process.version // ex. v24.14.0
if (Number(nodeVer.slice(1).split('.')[0]) < 24) throw new Error(`Node 24+ required (running ${nodeVer})`)
const nodeZipName = `node-${nodeVer}-win-x64.zip`
const nodeZip = path.join(CACHE, nodeZipName)
fs.mkdirSync(CACHE, { recursive: true })
if (!fs.existsSync(nodeZip)) {
  step(`Downloading ${nodeZipName}`)
  const res = await fetch(`https://nodejs.org/dist/${nodeVer}/${nodeZipName}`)
  if (!res.ok) throw new Error(`download failed: HTTP ${res.status}`)
  fs.writeFileSync(nodeZip + '.part', Buffer.from(await res.arrayBuffer()))
  fs.renameSync(nodeZip + '.part', nodeZip)
}
step('Checking the Node download')
const sums = await (await fetch(`https://nodejs.org/dist/${nodeVer}/SHASUMS256.txt`)).text()
const expected = sums.split('\n').find((l) => l.endsWith(`  ${nodeZipName}`))?.split(' ')[0]
const actual = crypto.createHash('sha256').update(fs.readFileSync(nodeZip)).digest('hex')
if (!expected || expected !== actual) {
  fs.rmSync(nodeZip)
  throw new Error(`SHA-256 mismatch for ${nodeZipName} (deleted, run again)`)
}
console.log(`sha256 ${actual} ✓`)

// ---- Dossier de l'appli -------------------------------------------------------------
step(`Staging ${name}`)
fs.rmSync(stage, { recursive: true, force: true })
fs.mkdirSync(path.join(app, 'node'), { recursive: true })
const inner = `node-${nodeVer}-win-x64`
run(TAR, ['-xf', nodeZip, '-C', CACHE, `${inner}/node.exe`, `${inner}/LICENSE`])
fs.copyFileSync(path.join(CACHE, inner, 'node.exe'), path.join(app, 'node', 'node.exe'))
fs.copyFileSync(path.join(CACHE, inner, 'LICENSE'), path.join(app, 'node', 'LICENSE'))

const copy = (rel, to = rel) => fs.cpSync(path.join(ROOT, rel), path.join(app, to), { recursive: true })
copy('service/src')
copy('service/package.json')
copy('service/package-lock.json')
copy('interface/dist')
for (const f of ['icone.ico', 'LICENSE', 'README.md']) copy(f) // icone.ico : aussi l'icône près de l'horloge (tray.ts)

step('Compiling SC Companion.exe')
const CSC = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe')
const exe = path.join(app, 'SC Companion.exe')
run(CSC, ['/nologo', '/target:winexe', '/optimize+', `/win32icon:${path.join(ROOT, 'icone.ico')}`, '/r:System.Windows.Forms.dll', `/out:${exe}`, path.join(ROOT, 'launcher', 'Launcher.cs')])
fs.copyFileSync(exe, path.join(ROOT, 'SC Companion.exe')) // copie de développement (Node du PC)

step('Installing service dependencies (production only)')
npm(['ci', '--omit=dev', '--no-audit', '--no-fund'], path.join(app, 'service'))

// ---- Contrôle : le service démarre avec le Node livré -------------------------------
step('Smoke test')
const out = execFileSync(path.join(app, 'node', 'node.exe'), ['-e', "import('./src/access.ts').then(() => console.log('ok'))"], {
  cwd: path.join(app, 'service'),
  env: { ...process.env, SCC_DATA_DIR: path.join(CACHE, 'smoke-data') },
  encoding: 'utf8',
})
if (!out.includes('ok')) throw new Error('service modules failed to load with the bundled Node')
console.log('service modules load ✓')

// ---- Zip ----------------------------------------------------------------------------
step('Zipping')
const zip = path.join(OUT, `${name}.zip`)
fs.rmSync(zip, { force: true })
run(TAR, ['-a', '-cf', zip, '-C', stage, 'SC Companion'])
const mb = (fs.statSync(zip).size / 2 ** 20).toFixed(1)
console.log(`\n✓ ${path.relative(ROOT, zip)} (${mb} MB)`)
