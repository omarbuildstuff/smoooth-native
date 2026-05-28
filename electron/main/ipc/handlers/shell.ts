/* eslint-disable @typescript-eslint/no-explicit-any */
// Handlers for shell-related IPC (electron.shell).

import { shell } from 'electron'
import log from 'electron-log/main'

const ALLOWED_SCHEMES = new Set(['https:', 'http:', 'x-apple.systempreferences:'])

export function showItemInFolder(_event: any, filePath: string) {
  shell.showItemInFolder(filePath)
}

export function openExternal(_event: any, url: string) {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    log.warn('[shell] openExternal blocked malformed URL:', url)
    return
  }
  if (!ALLOWED_SCHEMES.has(parsed.protocol)) {
    log.warn('[shell] openExternal blocked disallowed scheme:', parsed.protocol, url)
    return
  }
  shell.openExternal(url)
}
