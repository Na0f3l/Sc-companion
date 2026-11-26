// Lecture du Game.log de Star Citizen : mode de jeu (univers persistant / Arena Commander / menu),
// blessures du personnage et événements marquants (repères sous la courbe de la bande RAM).
//
// Même règle que l'outil PowerShell (memoire/) :
//   gamerules="EA_…" ou « Requesting game mode …/EA_… »  → Arena Commander
//   gamerules="SC_…" (hors SC_Frontend) ou « <Join PU> »  → univers persistant
//   SC_Frontend, « <SystemQuit> »                          → menu / jeu fermé
//
// Léger : toutes les 2 s, on regarde seulement la taille du fichier ; s'il a grossi, on lit les
// octets ajoutés depuis la dernière fois (jamais tout le fichier, sauf une fois au démarrage).
// Le jeu recrée le fichier à chaque lancement : s'il rétrécit, on repart du début.
import fs from 'node:fs'
import path from 'node:path'
import type { Flat } from './flat.ts'

export type GameMode = 'pu' | 'ac' | 'menu'

const POLL_MS = 2000
const MAX_FIRST_READ = 8 * 2 ** 20 // octets lus au plus au démarrage (fin du fichier)
const MODE_RX = /gamerules="([^"]+)"|Requesting game mode [^/\s"]*\/(\w+)|(<Join PU>)|(<SystemQuit>)/g
// Fin du chargement : « <Context Establisher Done> establisher="CReplicationModel" … gamerules="SC_Default" » (écran de
// chargement fermé, personnage en jeu) ; un nouvel écran de chargement (« OpenLoadingScreen] Started ») le remet à zéro.
// « OnClientSpawned » ne convient pas : depuis la 5.0, il est aussi écrit au menu, pour le personnage de l'écran d'accueil.
const LOAD_RX = /OpenLoadingScreen\] Started|<Context Establisher Done> establisher="CReplicationModel".*?gamerules="(\w+)"/g

// Blessures : notifications du HUD, ex. « Minor Injury Detected - Right leg - Tier 3 Treatment Required ».
// Tier 3 = mineure, 2 = modérée, 1 = grave. Le jeu ne note PAS la guérison : voir clearInjuries().
const INJURY_RX = /Injury Detected - (Head|Torso|Left arm|Right arm|Left leg|Right leg) - Tier ([123])/g
// Soin au lit médical : « <MED BED HEAL> … Perform surgery event Success … head: false torso: false leftArm: false
// rightArm: false leftLeg: false rightLeg: true » (true = partie soignée). Les autres soins (medpen, medgun)
// n'écrivent rien : pour eux, voir clearInjuries() (santé max revenue à 100).
const MEDBED_RX = /<MED BED HEAL>.*?surgery event Success.*?head: (true|false) torso: (true|false) leftArm: (true|false) rightArm: (true|false) leftLeg: (true|false) rightLeg: (true|false)/g
const MEDBED_PARTS = ['head', 'torso', 'left_arm', 'right_arm', 'left_leg', 'right_leg']
const PART_KEY: Record<string, string> = {
  Head: 'head', Torso: 'torso', 'Left arm': 'left_arm', 'Right arm': 'right_arm', 'Left leg': 'left_leg', 'Right leg': 'right_leg',
}

// ---- Événements pour la timeline de la bande RAM -----------------------------------------------------------
// Niveaux : info (lieu, saut quantique), board / exit (montée dans un vaisseau / sortie), note (contrat, crime,
// récompense, hangar), kill (vaisseau abattu par le joueur),
// death (mort du joueur, vaisseau du joueur détruit). Envoyés sous une seule clé : log.events = JSON de
// [[horodatage ms, niveau, texte], …], ceux des 2 dernières heures (la courbe se zoome / se déplace jusque-là).
// success / failure : contrat terminé / échoué
// abandon : contrat abandonné par le joueur (croix blanche) ; killp / deathp : kill d'un joueur / mort tué par un
// joueur (comptés à part : K/D joueurs) ; loss : vaisseau du joueur détruit (pas une mort en soi)
// downed / revived : coma (vie à 0, en attente des secours) / ranimé sans être mort entre-temps
export type LogLevel =
  | 'info' | 'board' | 'exit' | 'note' | 'success' | 'failure' | 'abandon' | 'kill' | 'killp' | 'death' | 'deathp' | 'loss'
  | 'downed' | 'revived'

const DOWNED_LABEL = 'Incapacitated'
type LogEvent = [number, LogLevel, string]
const EVENT_WINDOW_MS = 2 * 3600_000
const MAX_EVENTS = 300
// Seules les lignes qui contiennent un de ces mots sont extraites puis examinées en détail. Recherche directe
// dans le texte (et non découpage en lignes) : au démarrage, 8 Mo de log ne deviennent pas 50 000 petites chaînes.
const EVENT_LINE_RX = /^.*(?:Added notification "|<Vehicle Destroyed>|<Join PU>|PopulateItemPortForItemRecoveryEntitlement|<\[EASpawn\] ScheduleRespawn>|<AccountLoginCharacterStatus_Character>|OnClientSpawned\] Spawned!|<EndMission>|ClearDriver: Local client|<\[ActorState\] Dead>|<AttachmentReceived>).*$/gm
// le joueur quitte le siège pilote (le log ne note pas l'entrée : voir seatEvent, depuis la télémétrie)
const CLEAR_DRIVER_RX = /ClearDriver: Local client node \[(\d+)\] releasing control token for '([^']+)'/
// objet d'un corps (identifiant en fin de nom) et objet porté par un joueur (pseudo, identifiant)
const CORPSE_ITEM_RX = /PopulateItemPortForItemRecoveryEntitlement\]> Item '[^ ']*_(\d+) - /
const ATTACHMENT_RX = /<AttachmentReceived> Player\[([^\]]+)\] Attachment\[[^,]*, [^,]*, (\d+)\]/
const TS_RX = /^<(\d{4}-\d\d-\d\dT[\d:.]+Z)>/
const LOGIN_RX = /geid (\d+) .*?name (\S+)/
// contrat accepté (nom + identifiant de mission) et fin de mission (type : Complete, Fail, Abandon, Deactivate)
const ACCEPTED_RX = /Added notification "Contract Accepted:\s*(.*?):\s*".*?MissionId: \[([0-9a-f-]{36})\]/
const END_MISSION_RX = /<EndMission>.*?MissionId\[([0-9a-f-]{36})\] Player\[([^\]]*)\].*?CompletionType\[(\w+)\]/
const NOTIF_RX = /Added notification "([^"]*)/ // le texte peut continuer sur la ligne suivante (sans guillemet fermant)
const DESTROYED_RX = /Vehicle '[^']*' \[(\d+)\] class '([^']+)' \(owner player \[(\d+)\], driver \[(\d+)\]\).*?reason \[(\w+)\] level \[\d\] -> \[(\d)\].*?killer '([^']*)' \[(\d+)\]/
// mort d'un personnage ; « ejected from zone » = il était dans un vaisseau détruit (identifiant du vaisseau)
const DEAD_RX = /<\[ActorState\] Dead>.*?Actor '([^']+)' \[\d+\](?: ejected from zone '[^']*' \[(\d+)\])?/

// PNJ ou joueur, d'après le nom et l'identifiant (logique de l'outil PowerShell) : les entités du jeu ont un
// identifiant sous 201 000 000 000, les comptes joueurs au-dessus ; un nom d'entité (« Classe_123456789 ») est
// un vaisseau ou un objet (collision, zone interdite…), pas un joueur.
function who(name: string, id: string): 'npc' | 'player' | '' {
  if (/^(PU_|NPC|AI_)|_AI_|Pilot|Pirate|Vanduul|_\d{6,}$/.test(name)) return 'npc'
  const n = Number(id)
  if (n > 0) return n < 201_000_000_000 ? 'npc' : 'player'
  return ''
}
const RESPAWN_RX = /player:(\S+) id:\d+ reason:(\w+)/

// 'AEGS_Vanguard_Sentinel_PU_AI_CRIM' → 'Vanguard Sentinel' (sans fabricant ni suffixes techniques)
// Texte commun aux deux sources (log et télémétrie) : le même texte = un seul repère (doublons écartés)
const seatLabel = (seated: boolean, cls: string) => `${seated ? 'Took controls' : 'Left controls'}: ${shipName(cls)}`

function shipName(cls: string): string {
  const parts = cls.split('_')
  if (/^[A-Z]{3,4}$/.test(parts[0]!) && parts.length > 1) parts.shift()
  const cut = parts.findIndex((p) => /^(PU|AI|EA|Unmanned|Template)$/.test(p))
  return (cut > 0 ? parts.slice(0, cut) : parts).join(' ')
}

// Notification du HUD → [niveau, texte] (null : ignorée). me = nom du joueur.
function notifEvent(text: string, me: string): [LogLevel, string] | null {
  const t = text.replace(/:\s*$/, '').trim()
  let m: RegExpMatchArray | null
  if (t.startsWith('Entering Armistice Zone')) return ['info', 'Armistice zone']
  if (t.startsWith('Leaving Armistice Zone')) return ['info', 'Left armistice zone']
  if ((m = t.match(/^Entered (.+?) Jurisdiction/))) return ['info', `${m[1]} jurisdiction`]
  if (t.startsWith('Entered Monitored Space')) return ['info', 'Monitored space']
  if (t.startsWith('Exited Monitored Space')) return ['info', 'Left monitored space']
  if (t.startsWith('Restricted Area')) return ['info', 'Restricted area']
  if (t.startsWith('Leaving Restricted Area')) return ['info', 'Left restricted area']
  // écran du coma (« les secours arrivent ») : le joueur est à terre, pas encore mort (voir setHealth)
  if (t.startsWith('Standby, Local Emergency Services')) return ['downed', DOWNED_LABEL]
  if ((m = t.match(/^Crime Committed:\s*(.*)/))) return ['note', `Crime: ${m[1]}`]
  if (t.startsWith('CrimeStat Rating Increased')) return ['note', 'CrimeStat increased']
  if ((m = t.match(/^Fined (\d+) UEC/))) return ['note', `Fined ${Number(m[1]).toLocaleString('en-US')} UEC`]
  if ((m = t.match(/^Vehicle Impounded:\s*(.*)/))) return ['note', `Ship impounded: ${m[1]}`]
  if ((m = t.match(/^Quantum Travel Calibration Started By (\S*)/))) return ['info', m[1] && m[1] !== me ? `Quantum travel (${m[1]})` : 'Quantum travel']
  if (t.startsWith('Hangar Request Completed')) return ['note', 'Hangar ready'] // hangar attribué à la demande d'atterrissage, vaisseau pas encore posé
  // (canaux radio des vaisseaux, « You have joined / left the channel » : ignorés, le jeu en fait rejoindre et
  // quitter en boucle à proximité d'autres vaisseaux ; montée / sortie = prise des commandes, voir seatLabel)
  if ((m = t.match(/^Contract Accepted:\s*(.*)/))) return ['note', `Contract accepted: ${m[1]}`]
  if ((m = t.match(/^Contract Complete:\s*(.*)/))) return ['success', `Contract complete: ${m[1]}`]
  if ((m = t.match(/^Contract Failed:\s*(.*)/))) return ['failure', `Contract failed: ${m[1]}`]
  if ((m = t.match(/^Received Blueprint:\s*(.*)/))) return ['note', `Blueprint: ${m[1]}`]
  if ((m = t.match(/^A Refinery Work Order has been Completed at (.*)/))) return ['note', `Refinery order done (${m[1]})`]
  return null
}

function modeOf(m: RegExpExecArray): GameMode {
  if (m[3]) return 'pu'
  if (m[4]) return 'menu'
  const rules = m[1] ?? m[2] ?? ''
  if (rules.startsWith('EA_')) return 'ac'
  if (rules.startsWith('SC_') && rules !== 'SC_Frontend') return 'pu'
  return 'menu'
}

// Dernier mode trouvé dans un morceau de texte (ou null)
function lastMode(text: string): GameMode | null {
  let mode: GameMode | null = null
  MODE_RX.lastIndex = 0
  for (let m = MODE_RX.exec(text); m; m = MODE_RX.exec(text)) mode = modeOf(m)
  return mode
}

export type { LogEvent }

/** onEvent : appelé pour chaque nouvel événement retenu (enregistrement des sessions, sessions.ts). */
/** gameDir : dossier du jeu, relu à chaque passage (paths.ts : suit le launcher, LIVE / PTU…). */
export function createGameLogReader(gameDir: () => string, onEvent?: (e: LogEvent) => void) {
  let file = path.join(gameDir(), 'Game.log')
  let timer: NodeJS.Timeout | null = null
  let pos = 0
  let rest = '' // fin de ligne incomplète, gardée pour la lecture suivante
  let mode: GameMode | null = null
  let loaded = false // chargement terminé, personnage en jeu (LOAD_RX)
  // partie du corps → tier (la dernière notification fait foi) et moment où on l'a lue
  const injuries = new Map<string, { tier: number; at: number }>()
  let events: LogEvent[] = []
  let eventsJson = '[]'
  let dirty = true // liste changée depuis le dernier JSON
  let me = { id: '', name: '' } // joueur (ligne de connexion, au début du log)
  const contracts = new Map<string, string>() // identifiant de mission → nom du contrat (pour l'abandon)
  const myItems = new Set<string>() // identifiants des objets portés par le joueur (reconnaître son corps)
  // vaisseaux détruits (identifiant → nom, cause, tueur) : un kill par vaisseau, et la cause d'une mort à bord
  const wrecks = new Map<string, { ship: string; reason: string; killer: string; killerWho: string }>()
  // coma : début (ms) tant que le joueur est à terre ; dernier instant où sa vie était au-dessus de 0
  let downedAt: number | null = null
  let lastAlive = 0
  const deathSince = (t: number) => events.some((e) => (e[1] === 'death' || e[1] === 'deathp') && e[0] >= t)
  // kills en attente de confirmation (4 s) : un vaisseau « détruit par moi » où je meurs juste après était le mien
  // (en Arena Commander, son propriétaire n'est pas renseigné)
  let pendingKills: { id: string; t: number; reason: string; level: LogLevel; label: string; seen: number }[] = []
  function flushKills(): void {
    const limit = Date.now() - 4000
    for (const k of pendingKills) if (k.seen <= limit) addEvent(k.t, k.level, k.label)
    pendingKills = pendingKills.filter((k) => k.seen > limit)
  }

  function addEvent(t: number, level: LogLevel, label: string): void {
    // même texte dans les 30 s : doublon (notification répétée, mort = plusieurs lignes « corpse »…)
    if (events.some((e) => e[2] === label && Math.abs(e[0] - t) < 30_000)) return
    // une mort apparaît sur plusieurs lignes (état « mort » d'abord, puis le corps ~30 s après, l'écran des
    // secours…) : une seule par minute
    const isDeath = (l: LogLevel) => l === 'death' || l === 'deathp'
    if (isDeath(level) && events.some((e) => isDeath(e[1]) && Math.abs(e[0] - t) < 60_000)) return
    events.push([t, level, label])
    dirty = true
    onEvent?.([t, level, label])
  }

  function readEvents(lines: string): void {
    const since = Date.now() - EVENT_WINDOW_MS
    EVENT_LINE_RX.lastIndex = 0
    for (let found = EVENT_LINE_RX.exec(lines); found; found = EVENT_LINE_RX.exec(lines)) {
      const line = found[0]
      let m: RegExpMatchArray | null
      if ((m = line.match(LOGIN_RX)) && line.includes('AccountLoginCharacterStatus_Character')) {
        me = { id: m[1]!, name: m[2]! }
        continue
      }
      // nom des contrats acceptés, par identifiant de mission (même trop anciens : l'abandon peut venir bien après)
      if ((m = line.match(ACCEPTED_RX))) {
        if (contracts.size > 200) contracts.clear()
        contracts.set(m[2]!, m[1]!.trim())
      }
      // objets portés par le joueur (même anciens : on s'équipe bien avant de mourir) → reconnaître son corps
      if ((m = line.match(ATTACHMENT_RX))) {
        if (m[1] === me.name) {
          if (myItems.size > 3000) myItems.clear()
          myItems.add(m[2]!)
        }
        continue
      }
      const ts = line.match(TS_RX)
      const t = ts ? Date.parse(ts[1]!) : NaN
      if (!(t >= since)) continue // trop ancien pour la courbe (premier passage) ou sans horodatage
      if ((m = line.match(END_MISSION_RX))) {
        // abandon : aucune notification du jeu (terminé et échoué en ont une, lues plus haut)
        if (m[3] === 'Abandon' && (!me.name || m[2] === me.name)) {
          const name = contracts.get(m[1]!)
          addEvent(t, 'abandon', name ? `Contract abandoned: ${name}` : 'Contract abandoned')
        }
      } else if ((m = line.match(NOTIF_RX))) {
        const ev = notifEvent(m[1]!, me.name)
        if (ev?.[0] === 'downed') downedAt ??= t // écran des secours : coma (même s'il précède la télémétrie)
        if (ev) addEvent(t, ev[0], ev[1])
      } else if ((m = line.match(DESTROYED_RX))) {
        // Comme l'outil PowerShell : un vaisseau ne compte qu'une fois (neutralisé puis détruit = un seul kill)
        const [, id, cls, owner, driver, reason, level, killer, killerId] = m
        if (wrecks.has(id!)) continue
        if (wrecks.size > 500) wrecks.clear()
        const ship = shipName(cls!)
        wrecks.set(id!, { ship, reason: reason!, killer: killer!, killerWho: who(killer!, killerId!) })
        if (me.id && owner === me.id) {
          addEvent(t, 'loss', `Your ${ship} ${level === '1' ? 'disabled' : 'destroyed'} (${reason})`)
        } else if (me.id && (killerId === me.id || killer === me.name) && driver !== me.id) {
          // détruit dans un crash au moment où le joueur meurt (vaisseau embarqué…) : pas un kill
          if (reason !== 'Combat' && events.some((e) => (e[1] === 'death' || e[1] === 'deathp') && Math.abs(e[0] - t) < 3000)) continue
          // pilote du vaisseau abattu : PNJ (classe _AI_, identifiant d'entité) ou joueur (identifiant de compte) ;
          // sans pilote connu en Arena Commander multijoueur : un joueur
          let victim = /_AI_/.test(cls!) ? 'npc' : who('', driver!)
          if (!victim && mode === 'ac') victim = 'player'
          const verb = level === '1' ? 'Disabled' : 'Destroyed'
          // en attente quelques secondes : si le joueur meurt à bord, c'était son propre vaisseau (voir DEAD_RX)
          if (victim === 'player') pendingKills.push({ id: id!, t, reason: reason!, level: 'killp', label: `${verb} player: ${ship}`, seen: Date.now() })
          else pendingKills.push({ id: id!, t, reason: reason!, level: 'kill', label: `${verb} ${ship}`, seen: Date.now() })
        }
      } else if ((m = line.match(DEAD_RX))) {
        // mort du joueur dans un vaisseau détruit : on retrouve le vaisseau, donc la cause et le tueur
        if (m[1] !== me.name) continue // la ligne existe aussi pour les PNJ (pilote d'un vaisseau abattu)
        // pas un kill : le vaisseau où il est mort, et ce qui a sauté avec (vaisseau embarqué, crash : même instant)
        pendingKills = pendingKills.filter((k) => k.id !== m![2] && !(k.reason !== 'Combat' && Math.abs(k.t - t) < 3000))
        const v = m[2] ? wrecks.get(m[2]) : undefined
        const byOther = v && v.killer && v.killer !== me.name && v.killer !== 'unknown' && v.killer !== 'none'
        if (v && byOther && v.killerWho === 'player') addEvent(t, 'deathp', `Killed by ${v.killer} (${v.ship})`)
        else if (v && byOther) addEvent(t, 'death', `Shot down (${v.ship})`)
        else if (v) addEvent(t, 'death', `Died: ${v.ship} destroyed (${v.reason})`)
        else addEvent(t, 'death', 'You died')
      } else if ((m = line.match(CLEAR_DRIVER_RX))) {
        if (!me.id || m[1] === me.id) addEvent(t, 'exit', seatLabel(false, m[2]!.replace(/_\d+$/, '')))
      } else if (line.includes('OnClientSpawned')) {
        // réapparition pendant un coma sans mort notée (zone interdite…) : c'était une mort
        if (downedAt !== null && !deathSince(downedAt)) addEvent(t, 'death', 'You died')
        downedAt = null
        addEvent(t, 'info', 'Spawned') // arrivée en jeu ou réapparition après une mort
      } else if (line.includes('<Join PU>')) {
        const shard = line.match(/shard\[([^\]]+)\]/)
        addEvent(t, 'info', shard ? `Joined server ${shard[1]}` : 'Joined server')
      } else if ((m = line.match(CORPSE_ITEM_RX))) {
        // corps créé : le log ne dit pas à qui. Les corps d'autres joueurs (un pote abattu, un coéquipier) ont les
        // mêmes lignes ; c'est le nôtre seulement s'il contient des objets qu'on portait (AttachmentReceived)
        if (myItems.has(m[1]!)) addEvent(t, 'death', 'You died')
      } else if ((m = line.match(RESPAWN_RX)) && m[1] === me.name && m[2] !== 'ForceRespawnOnGameStart') {
        addEvent(t, 'death', 'You died') // Arena Commander
      }
    }
  }

  // Retire ce qui est sorti de la courbe ; le JSON envoyé aux écrans n'est refait que si la liste a changé
  // (nouvel événement ou un ancien qui sort), pas toutes les 2 s
  function pruneEvents(): void {
    const since = Date.now() - EVENT_WINDOW_MS
    const kept = events.filter((e) => e[0] >= since)
    if (!dirty && kept.length === events.length) return
    events = kept.sort((a, b) => a[0] - b[0]).slice(-MAX_EVENTS)
    eventsJson = JSON.stringify(events)
    dirty = false
  }

  // Lecture par morceaux de 1 Mo dans un tampon réutilisé : au premier passage (8 Mo de log), pas de tampon ni de
  // chaîne de 8 à 16 Mo qui resteraient en mémoire jusqu'à un grand nettoyage de V8 (rare : le tas est petit)
  const CHUNK = 1 << 20
  let chunkBuf: Buffer | null = null
  function readChunk(fd: number, start: number, end: number): string {
    chunkBuf ??= Buffer.allocUnsafe(CHUNK)
    const n = fs.readSync(fd, chunkBuf, 0, end - start, start)
    return chunkBuf.toString('utf8', 0, n)
  }

  function poll(): void {
    // autre dossier du jeu (lancé en PTU après LIVE…) : on repart du début de son Game.log
    const now = path.join(gameDir(), 'Game.log')
    if (now !== file) { file = now; pos = Infinity } // → « nouveau fichier » ci-dessous : tout repart de zéro
    let size: number
    try {
      size = fs.statSync(file).size
    } catch {
      mode = null; loaded = false // pas de Game.log (jeu jamais lancé, autre dossier)
      return
    }
    if (size < pos) { pos = 0; rest = ''; mode = null; loaded = false; injuries.clear(); events = []; dirty = true; me = { id: '', name: '' }; wrecks.clear(); pendingKills = []; downedAt = null; myItems.clear() } // nouveau fichier (jeu relancé)
    if (size === pos) { flushKills(); pruneEvents(); return }
    if (pos === 0 && size > MAX_FIRST_READ) pos = size - MAX_FIRST_READ // premier passage : la fin suffit
    const fd = fs.openSync(file, 'r') // Node ouvre en lecture partagée : le jeu peut continuer d'écrire
    try {
      while (pos < size) {
        const end = Math.min(size, pos + CHUNK)
        const text = rest + readChunk(fd, pos, end)
        pos = end
        const cut = text.lastIndexOf('\n')
        rest = cut >= 0 ? text.slice(cut + 1) : text
        if (cut >= 0) readLines(text.slice(0, cut))
      }
    } finally {
      fs.closeSync(fd)
    }
    flushKills()
    pruneEvents()
  }

  // Un bloc de lignes complètes : mode de jeu, blessures et soins, événements
  function readLines(lines: string): void {
    const found = lastMode(lines)
    if (found) mode = found
    LOAD_RX.lastIndex = 0
    for (let m = LOAD_RX.exec(lines); m; m = LOAD_RX.exec(lines)) loaded = !!m[1] && m[1] !== 'SC_Frontend'
    if (mode !== 'pu' && mode !== 'ac') loaded = false // menu, jeu quitté
    // blessures et soins dans l'ordre du log : une blessure soignée puis reprise reste affichée
    const changes: [number, () => void][] = []
    INJURY_RX.lastIndex = 0
    for (let m = INJURY_RX.exec(lines); m; m = INJURY_RX.exec(lines)) {
      const part = PART_KEY[m[1]!]!
      const tier = Number(m[2])
      changes.push([m.index, () => injuries.set(part, { tier, at: Date.now() })])
    }
    MEDBED_RX.lastIndex = 0
    for (let m = MEDBED_RX.exec(lines); m; m = MEDBED_RX.exec(lines)) {
      const healed = MEDBED_PARTS.filter((_, i) => m![i + 1] === 'true')
      changes.push([m.index, () => healed.forEach((p) => injuries.delete(p))])
    }
    changes.sort((a, b) => a[0] - b[0]).forEach(([, apply]) => apply())
    readEvents(lines)
  }

  return {
    start() {
      if (timer) return
      poll() // premier passage : lit le fichier existant une fois
      timer = setInterval(poll, POLL_MS)
    },
    stop() {
      if (timer) clearInterval(timer)
      timer = null
    },
    /**
     * Blessures soignées (le jeu ne l'écrit pas dans le log : décidé par le service, voir index.ts).
     * Seules celles lues depuis plus de 10 s sont effacées : une blessure toute neuve peut arriver dans le log
     * un instant avant que la santé max ne baisse dans la télémétrie.
     */
    clearInjuries() {
      const limit = Date.now() - 10_000
      for (const [part, i] of injuries) if (i.at < limit) injuries.delete(part)
    },
    /**
     * Siège du vaisseau d'après la télémétrie (index.ts, quand un écran est ouvert) : appelé à chaque changement.
     * cls = classe du vaisseau (ex. AEGS_Avenger_Titan).
     */
    /**
     * Vie du personnage d'après la télémétrie (index.ts) : à 0 sans mort notée = coma (crâne blanc) ;
     * remontée au-dessus de 0 sans mort entre-temps = ranimé (cœur blanc).
     */
    setHealth(hp: number): void {
      const now = Date.now()
      if (hp > 0) {
        // (un coma de plus de 15 min est une vieille trace relue dans le log au démarrage : pas de « ranimé » maintenant)
        if (downedAt !== null && now - downedAt < 15 * 60_000 && !deathSince(downedAt)) addEvent(now, 'revived', 'Revived')
        downedAt = null
        lastAlive = now
        return
      }
      // vie à 0 : coma, sauf si une mort est déjà notée depuis la dernière fois qu'il était en vie (écran de mort)
      if (downedAt === null && !deathSince(lastAlive - 2000)) {
        downedAt = now
        addEvent(now, 'downed', DOWNED_LABEL)
      }
    },
    seatEvent(seated: boolean, cls: string): void {
      addEvent(Date.now(), seated ? 'board' : 'exit', seatLabel(seated, cls))
    },
    flat: (): Flat => {
      const out: Flat = mode ? { 'game.mode': mode } : {}
      if (loaded) out['game.loaded'] = true
      for (const [part, i] of injuries) out[`injury.${part}`] = i.tier
      if (events.length) out['log.events'] = eventsJson
      return out
    },
  }
}
