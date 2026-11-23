// Sonde de connexion à la télémétrie locale de Star Citizen.
//
// Lecture seule : n'appelle JAMAIS TriggerGameAction.
// Étapes : 1) port TCP ouvert ?  2) ListTriggerableActions (présent en 5.0, attendu absent en 4.10)
//          3) TelemetryStream : affiche la première trame complète puis des stats par section.
//
// Usage : npm run probe -- [--addr 127.0.0.1:2942] [--seconds 20] [--save]
//   --save écrit les trames reçues dans captures/ (désactivé par défaut : aucun enregistrement automatique).

import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import grpc from '@grpc/grpc-js';
import protoLoader from '@grpc/proto-loader';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : def;
};
const ADDR = opt('addr', '127.0.0.1:2942');
const SECONDS = Number(opt('seconds', 20));
const SAVE = args.includes('--save');
const [HOST, PORT] = ADDR.split(':');

if (HOST !== '127.0.0.1' && HOST !== 'localhost') {
  console.error('Refusé : la sonde ne se connecte qu’à localhost.');
  process.exit(2);
}

const log = (...a) => console.log(`[${new Date().toISOString().slice(11, 23)}]`, ...a);

// --- 1. Port TCP --------------------------------------------------------------
function tcpCheck() {
  return new Promise((resolve) => {
    const s = net.connect({ host: HOST, port: Number(PORT) });
    s.setTimeout(1500);
    s.once('connect', () => { s.destroy(); resolve(true); });
    s.once('timeout', () => { s.destroy(); resolve(false); });
    s.once('error', () => resolve(false));
  });
}

// --- 2. Client gRPC à partir du .proto communautaire ---------------------------
const def = protoLoader.loadSync(path.join(root, 'proto', 'sc_telemetry.proto'), {
  keepCase: true, // garde les noms snake_case du schéma
  enums: String,  // enums lisibles
  longs: String,  // int64 (uec_balance) sans perte
  defaults: false // proto3 n'envoie pas les valeurs nulles : on ne les invente pas
});
const pkg = grpc.loadPackageDefinition(def).sc.game.telemetry.v1;
const client = new pkg.GameTelemetryService(ADDR, grpc.credentials.createInsecure());

function listActions() {
  return new Promise((resolve) => {
    client.ListTriggerableActions({}, { deadline: Date.now() + 3000 }, (err, res) => {
      if (err) resolve({ ok: false, code: grpc.status[err.code] ?? err.code, msg: err.details });
      else resolve({ ok: true, actions: res.actions ?? [] });
    });
  });
}

// --- 3. Flux de télémétrie -------------------------------------------------------
function stream() {
  return new Promise((resolve) => {
    const stats = new Map(); // section -> { count, first, last }
    const frames = [];
    let total = 0;
    let firstAt = 0;
    const call = client.TelemetryStream({});

    const stop = (reason) => {
      clearTimeout(timer);
      call.cancel();
      resolve({ reason, total, firstAt, stats, frames });
    };
    const timer = setTimeout(() => stop('durée écoulée'), SECONDS * 1000);

    call.on('data', (frame) => {
      const now = Date.now();
      total++;
      if (total === 1) {
        firstAt = now;
        log('PREMIÈRE TRAME REÇUE :');
        console.log(JSON.stringify(frame, null, 2));
      }
      for (const k of Object.keys(frame)) {
        if (frame[k] == null) continue;
        const s = stats.get(k) ?? { count: 0, first: now, last: now };
        s.count++; s.last = now;
        stats.set(k, s);
      }
      if (frame.events?.events?.length) log('ÉVÉNEMENT :', frame.events.events.map((e) => e.type).join(', '));
      if (SAVE && frames.length < 5000) frames.push({ t: now, frame });
    });
    call.on('error', (err) => {
      if (err.code === grpc.status.CANCELLED) return;
      stop(`erreur ${grpc.status[err.code] ?? err.code} : ${err.details}`);
    });
    call.on('end', () => stop('flux terminé par le serveur'));
  });
}

// --- Exécution -------------------------------------------------------------------
log(`Cible : ${ADDR}`);
if (!(await tcpCheck())) {
  log('✗ Port fermé. Le jeu n’est pas lancé ou le serveur de télémétrie n’est pas activé.');
  log('  LIVE 4.10 : variable GRPC_CLIENT_SERVER_ENABLED=true + relancer le RSI Launcher.');
  log('  5.0 PTU   : server.game.telemetry.enabled=1 dans user.cfg du canal.');
  process.exit(1);
}
log('✓ Port ouvert.');

const la = await listActions();
if (la.ok) log(`✓ ListTriggerableActions : ${la.actions.length} actions (build 5.0 ou plus récent).`);
else log(`• ListTriggerableActions indisponible (${la.code}) — normal en 4.10 LIVE.`);

log(`Ouverture de TelemetryStream pendant ${SECONDS} s… (rien n’arrive tant que le personnage n’est pas spawn)`);
const r = await stream();
client.close();

log(`Fin : ${r.reason}. Trames reçues : ${r.total}.`);
if (r.total) {
  console.log('\nSection          trames    fréquence');
  for (const [k, s] of r.stats) {
    const dur = (s.last - s.first) / 1000;
    const hz = dur > 0 ? ((s.count - 1) / dur).toFixed(1) : '—';
    console.log(`${k.padEnd(16)} ${String(s.count).padStart(6)}    ${hz} Hz`);
  }
}
if (SAVE && r.frames.length) {
  const dir = path.join(root, 'captures');
  fs.mkdirSync(dir, { recursive: true });
  const f = path.join(dir, `capture_${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
  fs.writeFileSync(f, JSON.stringify(r.frames));
  log(`Capture écrite : ${f} (contient notamment le solde aUEC si le jeu l’envoie).`);
}
