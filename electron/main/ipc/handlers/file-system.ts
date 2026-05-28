// Handlers for file system-related IPC (file system).

import fs from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import { app } from 'electron'

const ALLOWED_PREFIXES = () => [
  path.normalize(app.getPath('userData')),
  path.normalize(path.join(os.homedir(), '.smoooth')),
  path.normalize(app.getPath('temp')),
]

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function handleReadFile(_event: any, filePath: string): Promise<string> {
  const resolved = path.resolve(filePath)
  const allowed = ALLOWED_PREFIXES().some(
    (prefix) => resolved === prefix || resolved.startsWith(prefix + path.sep),
  )
  if (!allowed) {
    throw new Error(`Access denied: ${filePath}`)
  }
  return fs.readFile(resolved, 'utf-8')
}
