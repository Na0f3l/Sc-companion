// Variable d'environnement qui allume la télémétrie du jeu : GRPC_CLIENT_SERVER_ENABLED=true.
// Le jeu la lit au lancement, transmise par le RSI Launcher (qui la tient de l'Explorateur Windows).
//
// - Lecture dans le registre : compte de l'utilisateur (HKCU\Environment) ou machine. Pas process.env : celui du
//   service date de son lancement et ne voit pas un changement fait depuis.
// - Activation en un clic depuis l'interface : écrite pour le compte de l'utilisateur (sans droits
//   administrateur), puis annoncée à Windows (WM_SETTINGCHANGE) pour que les programmes lancés ensuite la
//   reçoivent. Le RSI Launcher déjà ouvert garde l'ancien environnement : il faut le quitter et le relancer.
import koffi from 'koffi'

const NAME = 'GRPC_CLIENT_SERVER_ENABLED'
const HKCU = -2147483647 // (HKEY)(LONG)0x80000001, étendu en 64 bits
const HKLM = -2147483646 // 0x80000002
const MACHINE_ENV = 'SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment'

let api: {
  get: (...a: unknown[]) => number
  set: (...a: unknown[]) => number
  broadcast: (...a: unknown[]) => number
} | null = null
function load() {
  if (api) return api
  const advapi32 = koffi.load('advapi32.dll')
  const user32 = koffi.load('user32.dll')
  api = {
    get: advapi32.func('long __stdcall RegGetValueW(intptr_t hkey, str16 sub, str16 name, uint32 flags, _Out_ uint32 *type, uint8_t *data, _Inout_ uint32 *cb)'),
    set: advapi32.func('long __stdcall RegSetKeyValueW(intptr_t hkey, str16 sub, str16 name, uint32 type, str16 data, uint32 cb)'),
    broadcast: user32.func('intptr_t __stdcall SendMessageTimeoutW(intptr_t hwnd, uint32 msg, uintptr_t wp, str16 lp, uint32 flags, uint32 timeout, _Out_ uintptr_t *res)'),
  }
  return api
}

function read(hkey: number, sub: string): string | null {
  const data = Buffer.alloc(256)
  const cb = [data.length]
  if (load().get(hkey, sub, NAME, 0x2 /* RRF_RT_REG_SZ */, [0], data, cb) !== 0) return null
  return data.toString('utf16le', 0, Math.max(0, cb[0]! - 2))
}

let cache = { at: 0, on: false }
/** La variable vaut-elle « true » (compte ou machine) ? Relu au plus toutes les 10 s. */
export function grpcEnvEnabled(): boolean {
  if (process.platform !== 'win32') return false
  if (Date.now() - cache.at > 10_000) {
    try {
      const v = read(HKCU, 'Environment') ?? read(HKLM, MACHINE_ENV)
      cache = { at: Date.now(), on: v?.trim().toLowerCase() === 'true' }
    } catch {
      cache = { at: Date.now(), on: false }
    }
  }
  return cache.on
}

/** Crée la variable pour le compte de l'utilisateur. true si c'est fait. */
export function enableGrpcEnv(): boolean {
  try {
    const value = 'true'
    if (load().set(HKCU, 'Environment', NAME, 1 /* REG_SZ */, value, (value.length + 1) * 2) !== 0) return false
    // prévenir l'Explorateur (et le reste) : 2 = SMTO_ABORTIFHUNG, 2 s au plus
    load().broadcast(0xffff /* HWND_BROADCAST */, 0x1a /* WM_SETTINGCHANGE */, 0, 'Environment', 2, 2000, [0])
    cache.at = 0
    console.log(`${NAME}=true set for this Windows account (restart the RSI Launcher)`)
    return true
  } catch (e) {
    console.error(`Could not set ${NAME}:`, (e as Error).message)
    return false
  }
}
