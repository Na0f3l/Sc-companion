// Capture brute de la télémétrie : lit les octets tels que le jeu les envoie, sans passer par le schéma,
// puis compare au schéma pour lister les champs INCONNUS (numéros absents du .proto) et les champs
// connus mais jamais vus. Lecture seule : n'appelle jamais TriggerGameAction.
//
// Usage : npm run raw -- [--seconds 90] [--addr 127.0.0.1:2942]
// Résultat : résumé dans la console + captures/raw_<date>.json (résumé + séries des champs inconnus)

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import grpc from '@grpc/grpc-js'
import protobuf from 'protobufjs'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const args = process.argv.slice(2)
const opt = (n, d) => { const i = args.indexOf(`--${n}`); return i >= 0 && args[i + 1] ? args[i + 1] : d }
const ADDR = opt('addr', '127.0.0.1:2942')
const SECONDS = Number(opt('seconds', 90))
if (!/^(127\.0\.0\.1|localhost):/.test(ADDR)) { console.error('Refusé : localhost uniquement.'); process.exit(2) }

const schema = new protobuf.Root().loadSync(path.join(root, 'proto', 'sc_telemetry.proto'), { keepCase: true }) // noms d'origine (snake_case)
const Response = schema.lookupType('sc.game.telemetry.v1.TelemetryStreamResponse')

// ---- Décodeur protobuf minimal (format filaire) ----------------------------------
function varint(buf, pos) {
  let v = 0n, shift = 0n, b
  do {
    if (pos >= buf.length) throw new Error('varint tronqué')
    b = buf[pos++]
    v |= BigInt(b & 0x7f) << shift
    shift += 7n
  } while (b & 0x80)
  return [v, pos]
}
function parse(buf) {
  const out = []
  let pos = 0
  while (pos < buf.length) {
    let tag
    ;[tag, pos] = varint(buf, pos)
    const no = Number(tag >> 3n), wt = Number(tag & 7n)
    if (no === 0) throw new Error('champ 0')
    if (wt === 0) { let v; [v, pos] = varint(buf, pos); out.push({ no, wt, v }) }
    else if (wt === 1) { out.push({ no, wt, v: buf.readDoubleLE(pos) }); pos += 8 }
    else if (wt === 5) { out.push({ no, wt, v: buf.readFloatLE(pos) }); pos += 4 }
    else if (wt === 2) {
      let len; [len, pos] = varint(buf, pos); len = Number(len)
      if (pos + len > buf.length) throw new Error('longueur invalide')
      out.push({ no, wt, v: buf.subarray(pos, pos + len) }); pos += len
    } else throw new Error(`type filaire ${wt}`)
  }
  return out
}

// ---- Parcours comparé au schéma ---------------------------------------------------
const seen = new Map() // chemin → { known, wt, count, min, max, samples }
const series = new Map() // chemin inconnu numérique → [[t, valeur]]
let t0 = 0

function note(key, known, wt, value, t) {
  let s = seen.get(key)
  if (!s) seen.set(key, (s = { known, wt, count: 0, min: Infinity, max: -Infinity, samples: [] }))
  s.count++
  if (typeof value === 'number') {
    s.min = Math.min(s.min, value); s.max = Math.max(s.max, value)
    if (!known) {
      const arr = series.get(key) ?? []
      if (arr.length < 20000) arr.push([t, +value.toFixed(4)])
      series.set(key, arr)
    }
  }
  if (s.samples.length < 24 && !s.samples.includes(String(value))) s.samples.push(String(value))
}

function walk(buf, type, prefix, t) {
  let fields
  try { fields = parse(buf) } catch { return false }
  for (const f of fields) {
    const def = type?.fieldsById?.[f.no]
    const key = `${prefix}.${def ? def.name : `#${f.no}`}`
    if (f.wt === 2) {
      if (def?.resolvedType instanceof protobuf.Type) { walk(f.v, def.resolvedType, key, t); note(key, true, 2, '{…}', t); continue }
      if (def && (def.type === 'float') && def.repeated) { // flottants « packés »
        for (let i = 0; i + 4 <= f.v.length; i += 4) note(`${key}[${i / 4}]`, true, 5, f.v.readFloatLE(i), t)
        continue
      }
      if (def?.type === 'string') { note(key, true, 2, f.v.toString('utf8'), t); continue }
      // inconnu : sous-message ? sinon texte / octets
      if (!def && f.v.length && walk(f.v, null, key, t)) { note(key, false, 2, '{…}', t); continue }
      note(key, !!def, 2, /^[\x20-\x7e]*$/.test(f.v.toString('latin1')) ? f.v.toString('latin1') : `<${f.v.length} octets>`, t)
    } else if (f.wt === 0) note(key, !!def, 0, Number(f.v), t)
    else note(key, !!def, f.wt, f.v, t)
  }
  return true
}

// Les champs prévus au schéma mais jamais reçus
function allSchemaPaths(type, prefix, out = [], depth = 0) {
  if (depth > 6) return out
  for (const fd of type.fieldsArray) {
    const key = `${prefix}.${fd.name}`
    fd.resolve()
    if (fd.resolvedType instanceof protobuf.Type) allSchemaPaths(fd.resolvedType, key, out, depth + 1)
    else out.push(key)
  }
  return out
}

// ---- Client gRPC brut (aucune désérialisation) -----------------------------------
const Client = grpc.makeGenericClientConstructor({
  TelemetryStream: {
    path: '/sc.game.telemetry.v1.GameTelemetryService/TelemetryStream',
    requestStream: false,
    responseStream: true,
    requestSerialize: () => Buffer.alloc(0),
    responseDeserialize: (b) => b,
  },
})
const client = new Client(ADDR, grpc.credentials.createInsecure())
let frames = 0, bytes = 0
const call = client.TelemetryStream({})
console.log(`Capture brute pendant ${SECONDS} s sur ${ADDR}… (vole, tire fort sur le manche, prends des dégâts)`)

call.on('data', (buf) => {
  const now = Date.now()
  if (!t0) t0 = now
  frames++; bytes += buf.length
  walk(buf, Response, '', now - t0)
})
call.on('error', (e) => { if (e.code !== grpc.status.CANCELLED) { console.error('Erreur :', e.details || e.message); finish() } })
const timer = setTimeout(finish, SECONDS * 1000)
// Ctrl+C : on arrête et on enregistre ce qui a déjà été capté
process.on('SIGINT', finish)

let done = false
function finish() {
  if (done) return
  done = true
  clearTimeout(timer)
  call.cancel()
  client.close()
  const unknown = [...seen].filter(([, s]) => !s.known)
  const known = [...seen].filter(([, s]) => s.known)
  const never = allSchemaPaths(Response, '').filter((k) => ![...seen.keys()].some((s) => s === k || s.startsWith(k + '[')))

  console.log(`\n${frames} trames, ${(bytes / 1024).toFixed(0)} Ko\n`)
  console.log(`=== CHAMPS INCONNUS DU SCHÉMA : ${unknown.length} ===`)
  for (const [k, s] of unknown) {
    const range = s.min !== Infinity ? ` [${+s.min.toFixed(3)} .. ${+s.max.toFixed(3)}]` : ''
    console.log(`${k.padEnd(48)} n=${String(s.count).padStart(5)}${range}  ex: ${s.samples.join(' | ').slice(0, 80)}`)
  }
  console.log(`\n=== CHAMPS DU SCHÉMA JAMAIS REÇUS : ${never.length} ===`)
  console.log(never.join('\n'))

  const dir = path.join(root, 'captures')
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, `raw_${new Date().toISOString().replace(/[:.]/g, '-')}.json`)
  fs.writeFileSync(file, JSON.stringify({
    frames, bytes,
    unknown: Object.fromEntries(unknown),
    known: Object.fromEntries(known.map(([k, s]) => [k, { count: s.count, min: s.min, max: s.max, samples: s.samples }])),
    neverReceived: never,
    unknownSeries: Object.fromEntries(series),
  }))
  console.log(`\nRésumé écrit : ${file}`)
}
