// Contains logic to check for new versions on GitHub.

import log from 'electron-log/main'
import { app, net, BrowserWindow } from 'electron'

export async function checkForUpdates(window: BrowserWindow | null) {
  if (!window) return

  const repoOwner = ''
  const repoName = ''

  if (!repoOwner || !repoName) {
    log.info('[UpdateCheck] No release repo configured — skipping update check.')
    return
  }

  const currentVersion = app.getVersion()
  const url = `https://api.github.com/repos/${repoOwner}/${repoName}/releases/latest`
  const maxAttempts = 3
  let currentAttempt = 0

  const attemptRequest = () => {
    currentAttempt++
    log.info(`[UpdateCheck] Attempt ${currentAttempt}/${maxAttempts}...`)

    const request = net.request({ method: 'GET', url })

    request.on('response', (response) => {
      if (response.statusCode === 200) {
        let body = ''
        response.on('data', (chunk) => {
          body += chunk.toString()
        })
        response.on('end', () => {
          try {
            const release = JSON.parse(body)
            const latestVersion = release.tag_name.startsWith('v') ? release.tag_name.substring(1) : release.tag_name
            const downloadUrl = release.html_url

            const compareVersions = (a: string, b: string): number => {
              const pa = a.split('.').map(Number)
              const pb = b.split('.').map(Number)
              for (let i = 0; i < 3; i++) {
                if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) - (pb[i] ?? 0)
              }
              return 0
            }

            if (compareVersions(latestVersion, currentVersion) > 0) {
              log.info(`[UpdateCheck] New version available: ${latestVersion}`)
              window.webContents.send('update:available', { version: latestVersion, url: downloadUrl })
            } else {
              log.info(`[UpdateCheck] App is up to date.`)
            }
          } catch (error) {
            log.error('[UpdateCheck] Failed to parse release JSON:', error)
          }
        })
      } else if (currentAttempt < maxAttempts) {
        setTimeout(attemptRequest, 3000)
      }
    })
    request.on('error', (error) => {
      log.warn(`[UpdateCheck] Network error:`, error.message)
      if (currentAttempt < maxAttempts) {
        setTimeout(attemptRequest, 3000)
      }
    })
    request.end()
  }

  attemptRequest()
}
