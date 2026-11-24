// Données figées du mode démo : de quoi afficher chaque écran sans le jeu (ni même le service).
// Tirées de captures réelles (Hornet F7A Mk II en vol, personnage à pied), sans identifiants ni solde réels.
// Tout est nominal pour ne déclencher aucune alerte.
import type { Value } from './telemetry'

export type DemoView = 'ship' | 'foot'

const NOM = 'ANNUNCIATOR_STATE_NOMINAL'

// Commun aux deux écrans : jeu lancé (mémoire), univers persistant, constantes du personnage
const COMMON: Record<string, Value> = {
  'game.mode': 'pu',
  'sc.private_mb': 18432,
  'sc.delta5_mb': 12,
  'sc.slope15': 2,
  'sc.slope30': 1,
  'sc.leak': 'ok',
  'sys.commit_gb': 31.4,
  'sys.commit_limit_gb': 72,
  'sys.commit_pct': 44,
  'sys.ram_total_gb': 32,
  'sys.ram_avail_gb': 9.6,
  'sys.cpu_pct': 38,
  'sys.gpu_pct': 92,
  'sys.gpu_temp': 67,
  'sys.vram_used_gb': 9.8,
  'actor.vitals.health.current': 100,
  'actor.vitals.health.max': 100,
  'actor.vitals.oxygen.current': 1,
  'actor.vitals.oxygen.max': 1,
  'actor.vitals.hunger.current': 81.4,
  'actor.vitals.hunger.max': 100,
  'actor.vitals.thirst.current': 51,
  'actor.vitals.thirst.max': 100,
  'actor.vitals.body_temperature.current': 36.5,
  'actor.vitals.body_temperature.max': 100,
  'actor.vitals.gravity': 1,
  'actor.vitals.pressure': 1,
  'actor.state.uec_balance': '1250000',
  'actor.environment.external_temperature': 21,
  'actor.environment.breathable_atmosphere': true,
}

const SHIP: Record<string, Value> = {
  'actor.vitals.heart_rate': 84,
  'actor.state.locomotion': 'ACTOR_LOCOMOTION_STATE_SEATED',
  'actor.state.crew_role': 'ACTOR_CREW_ROLE_PILOT',
  'vehicle.state.class_name': 'ANVL_Hornet_F7A_Mk2',
  'vehicle.state.type': 'VEHICLE_TYPE_SPACESHIP',
  'vehicle.state.annunciators.pwr': NOM,
  'vehicle.state.annunciators.wpn': NOM,
  'vehicle.state.annunciators.thr': NOM,
  'vehicle.state.annunciators.shld': 'ANNUNCIATOR_STATE_OFF',
  'vehicle.state.annunciators.cool': 'ANNUNCIATOR_STATE_OFF',
  'vehicle.state.annunciators.qdrv': NOM,
  'vehicle.state.annunciators.radr': NOM,
  'vehicle.state.annunciators.prox': NOM,
  'vehicle.state.annunciators.hit': NOM,
  'vehicle.state.annunciators.misl': NOM,
  'vehicle.state.flight.state.gear': 'VEHICLE_COMPONENT_DEPLOYMENT_STATE_RETRACTED',
  'vehicle.state.flight.state.vtol': 'VEHICLE_COMPONENT_DEPLOYMENT_STATE_DEPLOYED',
  'vehicle.state.flight.settings.ifcs_esp.enabled': true,
  'vehicle.state.flight.settings.ifcs_esp.active': true,
  'vehicle.state.flight.settings.ifcs_gravity_compensation.enabled': true,
  'vehicle.state.flight.settings.ifcs_gravity_compensation.active': true,
  'vehicle.state.flight.settings.ifcs_proximity_assist.enabled': true,
  'vehicle.state.flight.settings.ifcs_proximity_assist_landing.enabled': true,
  'vehicle.state.flight.settings.ifcs_stability.enabled': true,
  'vehicle.state.flight.settings.ifcs_stability.active': true,
  'vehicle.state.flight.settings.ifcs_core.enabled': true,
  'vehicle.state.flight.settings.ifcs_core.active': true,
  'vehicle.state.flight.settings.ifcs_command_behaviour.enabled': true,
  'vehicle.state.flight.settings.ifcs_command_behaviour.active': true,
  // en vol atmosphérique, à basse altitude : cap / altitude radar / VSI / impact affichés
  'vehicle.state.flight.instruments.speed': 187.4,
  'vehicle.state.flight.instruments.hydrogen_fuel': 1,
  'vehicle.state.flight.instruments.g_meter.current': 2.4,
  'vehicle.state.flight.instruments.g_meter.max': 16.06,
  'vehicle.state.flight.instruments.boost.reserves': 0.72,
  'vehicle.state.flight.instruments.radar_altitude': 160, // impact dans ~26 s : affiché, sous le seuil d'alerte (10 s)
  'vehicle.state.flight.instruments.vertical_speed_indicator': -6.2,
  'vehicle.state.flight.instruments.atmospheric_density': 1.2,
  'vehicle.state.flight.instruments.heading': 174.06,
  'vehicle.state.power.powerplants': true,
  'vehicle.state.power.engines': true,
  'vehicle.state.power.weapons': true,
  'vehicle.state.power.coolers': true,
  'vehicle.state.power.sensors': true,
  'weapons.settings.precision_lines': true,
  'weapons.settings.gimbals_locked': true,
  'weapons.countermeasures.0.type': 'COUNTERMEASURE_TYPE_DECOY',
  'weapons.countermeasures.0.amount': 96,
  'weapons.countermeasures.1.type': 'COUNTERMEASURE_TYPE_NOISE',
  'weapons.countermeasures.1.amount': 10,
}
// 6 canons (2 S4 + 4 S3), suffixe numérique fictif (le jeu y met l'identifiant de l'objet)
;['S4', 'S4', 'S3', 'S3', 'S3_CleanAir', 'S3_CleanAir'].forEach((size, i) => {
  const p = `weapons.weapons.${i}.`
  SHIP[p + 'name'] = `BEHR_LaserCannon_${size}_10000000${i}`
  SHIP[p + 'is_powered'] = true
  SHIP[p + 'ready_to_fire'] = true
  SHIP[p + 'contained_in_preset'] = true
})

const FOOT: Record<string, Value> = {
  'actor.vitals.heart_rate': 72,
  'actor.state.locomotion': 'ACTOR_LOCOMOTION_STATE_ON_FOOT',
  'injury.left_arm': 3, // une blessure mineure, pour montrer le panneau Injuries
}

export const demoData = (view: DemoView): Record<string, Value> => ({ ...COMMON, ...(view === 'ship' ? SHIP : FOOT) })
