// Faux serveur de télémétrie pour tester la sonde sans le jeu.
// Données FICTIVES (vaisseau "SIMULATION"), même schéma que le jeu, ~17 trames/s.
// N'écoute que sur 127.0.0.1. Port par défaut 2943 pour ne pas gêner le vrai jeu.
//
// Usage : npm run fake -- [--port 2943]   puis   npm run probe -- --addr 127.0.0.1:2943

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import grpc from '@grpc/grpc-js';
import protoLoader from '@grpc/proto-loader';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const i = process.argv.indexOf('--port');
const PORT = i >= 0 ? process.argv[i + 1] : '2943';

const def = protoLoader.loadSync(path.join(root, 'proto', 'sc_telemetry.proto'), { keepCase: true, enums: String, longs: String });
const pkg = grpc.loadPackageDefinition(def).sc.game.telemetry.v1;

function fakeFrame(t) {
  const s = Math.sin(t / 2000);
  return {
    actor: {
      vitals: { health: { current: 92, max: 100 }, oxygen: { current: 80 + 10 * s, max: 100 }, heart_rate: 72 + 8 * s },
      state: { locomotion: 'ACTOR_LOCOMOTION_STATE_SEATED', crew_role: 'ACTOR_CREW_ROLE_PILOT', seat_name: 'SIMULATION' },
      environment: { external_temperature: -20, breathable_atmosphere: false }
    },
    vehicle: {
      state: {
        name: 'SIMULATION — données fictives', manufacturer: 'FAKE', type: 'VEHICLE_TYPE_SPACESHIP', health: 0.95,
        shields: { level: 0.8, faces: [0.8, 0.8] },
        flight: { instruments: { speed: 150 + 50 * s, hydrogen_fuel: 0.7, quantum_fuel: 0.9 } }
      }
    }
  };
}

const server = new grpc.Server();
server.addService(pkg.GameTelemetryService.service, {
  TelemetryStream(call) {
    console.log('client connecté');
    let n = 0;
    const timer = setInterval(() => {
      const f = fakeFrame(Date.now());
      if (++n % 170 === 0) f.events = { events: [{ type: 'GAME_EVENT_TYPE_ACTOR_ENTER_SEAT' }] };
      call.write(f);
    }, 59);
    call.on('cancelled', () => { clearInterval(timer); console.log('client parti'); });
  },
  ListTriggerableActions(_call, cb) {
    cb({ code: grpc.status.UNIMPLEMENTED, details: 'simulation 4.10 : pas d’actions' });
  },
  TriggerGameAction(_call, cb) {
    cb({ code: grpc.status.UNIMPLEMENTED, details: 'non simulé' });
  }
});
server.bindAsync(`127.0.0.1:${PORT}`, grpc.ServerCredentials.createInsecure(), (err) => {
  if (err) throw err;
  console.log(`Faux serveur (DONNÉES FICTIVES) sur 127.0.0.1:${PORT}`);
});
