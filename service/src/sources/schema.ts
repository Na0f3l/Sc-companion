// Schéma de télémétrie lu dans le jeu installé : StarCitizen.exe embarque ses descripteurs protobuf compilés
// (FileDescriptorProto de sc/game/telemetry/v1/types.proto et api.proto). On les extrait de l'exe de
// l'utilisateur, rien n'est redistribué, et le schéma correspond toujours exactement à la version installée.
//
// - L'exe (~175 Mo) est lu en flux par blocs de 4 Mo : jamais chargé en entier en mémoire.
// - Le résultat (~8 Ko) est mis en cache dans le dossier des données, une seule fois par version de l'exe
//   (taille + date) : les lancements suivants ne relisent pas l'exe.
// - Repli : telemetrie/proto/sc_telemetry.proto s'il est présent (schéma communautaire récupéré à la main).
import fs from 'node:fs'
import path from 'node:path'
import protoLoader from '@grpc/proto-loader'
import { DATA_DIR } from '../paths.ts'

const FILES = ['sc/game/telemetry/v1/types.proto', 'sc/game/telemetry/v1/api.proto']
const PROTO = path.resolve(import.meta.dirname, '../../../telemetrie/proto/sc_telemetry.proto')
const OPTS: protoLoader.Options = { keepCase: true, enums: String, longs: String, defaults: false }
const CHUNK = 4 * 1024 * 1024
const WINDOW = 256 * 1024 // taille maximale lue pour un descripteur (types.proto ≈ 7 Ko)

function varint(b: Buffer, p: number): [number, number] | null {
  let v = 0
  for (let i = 0, s = 1; i < 10 && p < b.length; i++, s *= 128) {
    const x = b[p++]!
    v += (x & 0x7f) * s
    if (!(x & 0x80)) return [v, p]
  }
  return null
}

/** Longueur d'un FileDescriptorProto commençant à b[0] : on enchaîne les champs tant qu'ils sont valides. */
function messageLength(b: Buffer): number {
  let p = 0
  for (;;) {
    const t = varint(b, p)
    if (!t) break
    const field = Math.floor(t[0] / 8)
    if (field < 1 || field > 14 || (t[0] & 7) !== 2) break // champs utiles d'un FileDescriptorProto : tous length-delimited
    const l = varint(b, t[1])
    if (!l || l[1] + l[0] > b.length) break
    p = l[1] + l[0]
  }
  return p
}

function lengthPrefix(n: number): Buffer {
  const out = [0x0a] // FileDescriptorSet.file (champ 1)
  do {
    let x = n & 0x7f
    n = Math.floor(n / 128)
    if (n) x |= 0x80
    out.push(x)
  } while (n)
  return Buffer.from(out)
}

/** FileDescriptorSet extrait de l'exe, ou null si les descripteurs n'y sont pas. */
function extract(exe: string): Buffer | null {
  const needles = FILES.map((f) => Buffer.concat([Buffer.from([0x0a, f.length]), Buffer.from(f)]))
  const offsets: number[][] = FILES.map(() => [])
  const overlap = Math.max(...needles.map((n) => n.length))
  const fd = fs.openSync(exe, 'r')
  try {
    const buf = Buffer.alloc(CHUNK + overlap)
    let carry = 0
    for (let pos = 0; ; ) {
      const n = fs.readSync(fd, buf, carry, CHUNK, pos)
      if (!n) break
      const view = buf.subarray(0, carry + n)
      const base = pos - carry
      needles.forEach((needle, i) => {
        for (let k = view.indexOf(needle); k !== -1; k = view.indexOf(needle, k + 1)) {
          if (!offsets[i]!.includes(base + k)) offsets[i]!.push(base + k)
        }
      })
      pos += n
      carry = Math.min(overlap, view.length)
      view.copy(buf, 0, view.length - carry)
    }
    // plusieurs occurrences possibles (chaînes de débogage) : le vrai descripteur est le plus long
    const parts = offsets.map((list) => {
      let best: Buffer | null = null
      for (const off of list) {
        const win = Buffer.alloc(WINDOW)
        const got = fs.readSync(fd, win, 0, WINDOW, off)
        const len = messageLength(win.subarray(0, got))
        if (!best || len > best.length) best = Buffer.from(win.subarray(0, len))
      }
      return best
    })
    if (parts.some((p) => !p || p.length < 64)) return null
    return Buffer.concat(parts.flatMap((p) => [lengthPrefix(p!.length), p!]))
  } finally {
    fs.closeSync(fd)
  }
}

/** Définition gRPC de la télémétrie, lue dans le jeu installé (cache), sinon dans le .proto local. */
export function loadTelemetryDefinition(gameDir: string): protoLoader.PackageDefinition {
  const exe = path.join(gameDir, 'Bin64', 'StarCitizen.exe')
  try {
    const st = fs.statSync(exe)
    const cache = path.join(DATA_DIR, `telemetry-schema-${st.size}-${Math.floor(st.mtimeMs)}.bin`)
    if (fs.existsSync(cache)) return protoLoader.loadFileDescriptorSetFromBuffer(fs.readFileSync(cache), OPTS)
    const t = Date.now()
    const set = extract(exe)
    if (set) {
      const def = protoLoader.loadFileDescriptorSetFromBuffer(set, OPTS) // valide avant de mettre en cache
      for (const f of fs.readdirSync(DATA_DIR)) if (f.startsWith('telemetry-schema-')) fs.rmSync(path.join(DATA_DIR, f))
      fs.writeFileSync(cache, set)
      console.log(`Live: telemetry schema read from ${exe} (${Date.now() - t} ms)`)
      return def
    }
    console.warn(`Live: no telemetry schema found in ${exe}`)
  } catch (e) {
    console.warn('Live: could not read the schema from the game:', (e as Error).message)
  }
  if (fs.existsSync(PROTO)) {
    console.log(`Live: using ${PROTO}`)
    return protoLoader.loadSync(PROTO, OPTS)
  }
  throw new Error('telemetry schema not found (game executable unreadable and no .proto file)')
}
