// Icône dans la zone de notification de Windows (à côté de l'horloge), dans le processus du service lui-même :
// fonctions de Windows appelées avec koffi, aucun programme en plus (un script PowerShell coûterait 60 à 80 Mo).
//
//   double-clic          ouvrir l'interface
//   clic droit           menu : Open SC Companion · Sessions · Mobile connect · Quit
//   infobulle            état du jeu (mémoire de Star Citizen, session enregistrée)
//
// Une fenêtre invisible reçoit les messages de l'icône ; ils sont relevés toutes les 100 ms (PeekMessage, sans
// attente : la boucle d'événements de Node n'est jamais bloquée, sauf pendant que le menu est ouvert).
// Si l'Explorateur Windows redémarre, l'icône est remise (message « TaskbarCreated »).
import { spawn } from 'node:child_process'
import path from 'node:path'
import koffi from 'koffi'

const user32 = koffi.load('user32.dll')
const shell32 = koffi.load('shell32.dll')
const kernel32 = koffi.load('kernel32.dll')

const WndProc = koffi.proto('intptr_t __stdcall WndProc(void *hwnd, uint32_t msg, uintptr_t wp, intptr_t lp)')
const WNDCLASSEXW = koffi.struct('WNDCLASSEXW', {
  cbSize: 'uint32_t', style: 'uint32_t', lpfnWndProc: koffi.pointer(WndProc), cbClsExtra: 'int', cbWndExtra: 'int',
  hInstance: 'void *', hIcon: 'void *', hCursor: 'void *', hbrBackground: 'void *', lpszMenuName: 'void *',
  lpszClassName: 'str16', hIconSm: 'void *',
})
const POINT = koffi.struct('TRAY_POINT', { x: 'int32_t', y: 'int32_t' })

const GetModuleHandleW = kernel32.func('void * __stdcall GetModuleHandleW(void *name)')
const RegisterClassExW = user32.func('uint16_t __stdcall RegisterClassExW(WNDCLASSEXW *wc)')
const CreateWindowExW = user32.func('void * __stdcall CreateWindowExW(uint32_t ex, str16 cls, str16 name, uint32_t style, int x, int y, int w, int h, void *parent, void *menu, void *inst, void *param)')
const DestroyWindow = user32.func('bool __stdcall DestroyWindow(void *hwnd)')
const DefWindowProcW = user32.func('intptr_t __stdcall DefWindowProcW(void *hwnd, uint32_t msg, uintptr_t wp, intptr_t lp)')
const PeekMessageW = user32.func('bool __stdcall PeekMessageW(_Out_ uint8_t *msg, void *hwnd, uint32_t min, uint32_t max, uint32_t remove)')
const TranslateMessage = user32.func('bool __stdcall TranslateMessage(uint8_t *msg)')
const DispatchMessageW = user32.func('intptr_t __stdcall DispatchMessageW(uint8_t *msg)')
const RegisterWindowMessageW = user32.func('uint32_t __stdcall RegisterWindowMessageW(str16 name)')
const LoadImageW = user32.func('void * __stdcall LoadImageW(void *inst, str16 name, uint32_t type, int cx, int cy, uint32_t flags)')
const LoadIconW = user32.func('void * __stdcall LoadIconW(void *inst, uintptr_t id)')
const CreatePopupMenu = user32.func('void * __stdcall CreatePopupMenu()')
const AppendMenuW = user32.func('bool __stdcall AppendMenuW(void *menu, uint32_t flags, uintptr_t id, str16 text)')
const SetMenuDefaultItem = user32.func('bool __stdcall SetMenuDefaultItem(void *menu, uint32_t item, uint32_t byPos)')
const TrackPopupMenu = user32.func('int __stdcall TrackPopupMenu(void *menu, uint32_t flags, int x, int y, int reserved, void *hwnd, void *rect)')
const DestroyMenu = user32.func('bool __stdcall DestroyMenu(void *menu)')
const GetCursorPos = user32.func('bool __stdcall GetCursorPos(_Out_ TRAY_POINT *p)')
const SetForegroundWindow = user32.func('bool __stdcall SetForegroundWindow(void *hwnd)')
const PostMessageW = user32.func('bool __stdcall PostMessageW(void *hwnd, uint32_t msg, uintptr_t wp, intptr_t lp)')
const Shell_NotifyIconW = shell32.func('bool __stdcall Shell_NotifyIconW(uint32_t msg, uint8_t *data)')

// NOTIFYICONDATAW (64 bits) : rempli à la main dans un tampon (champs aux décalages ci-dessous, 976 octets)
const NID_SIZE = 976
const NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2
const NIF_MESSAGE = 0x1, NIF_ICON = 0x2, NIF_TIP = 0x4
const WM_APP_TRAY = 0x8001 // message choisi pour les clics sur l'icône
const WM_LBUTTONDBLCLK = 0x203, WM_RBUTTONUP = 0x205
const MF_STRING = 0, MF_SEPARATOR = 0x800
const TPM_RIGHTBUTTON = 0x2, TPM_NONOTIFY = 0x80, TPM_RETURNCMD = 0x100

export interface TrayActions {
  open(): void
  sessions(): void
  mobile(): void
  quit(): void
}

/** Ouvre une adresse dans le navigateur par défaut. */
export function openUrl(url: string): void {
  spawn('rundll32', ['url.dll,FileProtocolHandler', url], { detached: true, stdio: 'ignore' }).unref()
}

export function createTray(actions: TrayActions) {
  const inst = GetModuleHandleW(null)
  const icon =
    LoadImageW(null, path.join(import.meta.dirname, '..', '..', 'icone.ico'), 1 /* IMAGE_ICON */, 0, 0, 0x10 | 0x40 /* LR_LOADFROMFILE | LR_DEFAULTSIZE */) ??
    LoadIconW(null, 32512 /* IDI_APPLICATION */)
  const TASKBAR_CREATED = RegisterWindowMessageW('TaskbarCreated')

  const nid = Buffer.alloc(NID_SIZE)
  let tip = 'SC Companion'

  function writeTip(text: string): void {
    nid.fill(0, 40, 40 + 256)
    nid.write(text.slice(0, 127), 40, 'utf16le')
  }
  function notify(msg: number): boolean {
    return Shell_NotifyIconW(msg, nid)
  }

  function menu(hwnd: unknown): void {
    const m = CreatePopupMenu()
    AppendMenuW(m, MF_STRING, 1, 'Open SC Companion')
    AppendMenuW(m, MF_STRING, 2, 'Sessions')
    AppendMenuW(m, MF_STRING, 3, 'Mobile connect')
    AppendMenuW(m, MF_SEPARATOR, 0, '')
    AppendMenuW(m, MF_STRING, 9, 'Quit')
    SetMenuDefaultItem(m, 1, 0) // « Open » en gras (action du double-clic)
    const p = { x: 0, y: 0 }
    GetCursorPos(p)
    SetForegroundWindow(hwnd) // sinon le menu ne se ferme pas en cliquant ailleurs
    const cmd = TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_RETURNCMD, p.x, p.y, 0, hwnd, null)
    PostMessageW(hwnd, 0, 0, 0) // WM_NULL : recommandé après TrackPopupMenu
    DestroyMenu(m)
    if (cmd === 1) actions.open()
    else if (cmd === 2) actions.sessions()
    else if (cmd === 3) actions.mobile()
    else if (cmd === 9) actions.quit()
  }

  // gardée en vie tant que l'icône existe (sinon le ramasse-miettes la libérerait sous les pieds de Windows)
  const proc = koffi.register((hwnd: unknown, msg: number, wp: number, lp: number): number => {
    if (msg === WM_APP_TRAY) {
      const ev = Number(lp) & 0xffff
      if (ev === WM_LBUTTONDBLCLK) actions.open()
      else if (ev === WM_RBUTTONUP) menu(hwnd)
      return 0
    }
    if (msg === TASKBAR_CREATED) notify(NIM_ADD) // l'Explorateur a redémarré : remettre l'icône
    return Number(DefWindowProcW(hwnd, msg, wp, lp))
  }, koffi.pointer(WndProc))

  const CLASS = 'SCCompanionTray'
  RegisterClassExW({
    cbSize: koffi.sizeof(WNDCLASSEXW), style: 0, lpfnWndProc: proc, cbClsExtra: 0, cbWndExtra: 0, hInstance: inst,
    hIcon: null, hCursor: null, hbrBackground: null, lpszMenuName: null, lpszClassName: CLASS, hIconSm: null,
  })
  const hwnd = CreateWindowExW(0, CLASS, 'SC Companion', 0, 0, 0, 0, 0, null, null, inst, null) // jamais affichée

  nid.writeUInt32LE(NID_SIZE, 0)
  nid.writeBigUInt64LE(BigInt(koffi.address(hwnd)), 8)
  nid.writeUInt32LE(1, 16) // uID
  nid.writeUInt32LE(NIF_MESSAGE | NIF_ICON | NIF_TIP, 20)
  nid.writeUInt32LE(WM_APP_TRAY, 24)
  nid.writeBigUInt64LE(BigInt(icon ? koffi.address(icon) : 0), 32)
  writeTip(tip)
  if (!hwnd || !notify(NIM_ADD)) throw new Error('Windows refused the notification area icon')

  const msgBuf = Buffer.alloc(48) // MSG (64 bits)
  const pump = setInterval(() => {
    while (PeekMessageW(msgBuf, null, 0, 0, 1 /* PM_REMOVE */)) {
      TranslateMessage(msgBuf)
      DispatchMessageW(msgBuf)
    }
  }, 100)
  pump.unref() // ne retient pas le processus à lui seul

  return {
    /** Texte au survol de l'icône (mis à jour seulement s'il change). */
    setTip(text: string): void {
      if (text === tip) return
      tip = text
      writeTip(text)
      notify(NIM_MODIFY)
    },
    /** Retire l'icône (à l'arrêt du service : sinon elle reste affichée jusqu'au survol). */
    remove(): void {
      clearInterval(pump)
      notify(NIM_DELETE)
      DestroyWindow(hwnd)
      koffi.unregister(proc)
    },
  }
}
