import { useState, useEffect, useCallback, useRef } from 'react'

type Device = { id: string; name: string }

/**
 * Custom hook to manage loading and reloading of media devices (webcams, microphones).
 *
 * Key design notes:
 * - Platform is stored in a ref (not state) to avoid a re-render loop:
 *   state update → new fetchDevices → new loadAll → useEffect re-fires → repeat.
 * - getUserMedia is called once (combined audio+video) rather than once per device
 *   type, so macOS only shows one permission prompt instead of two.
 */
export const useDeviceManager = () => {
  const [platform, setPlatform] = useState<NodeJS.Platform | null>(null)
  const platformRef = useRef<NodeJS.Platform | null>(null)
  const [webcams, setWebcams] = useState<Device[]>([])
  const [mics, setMics] = useState<Device[]>([])
  const [isInitializing, setIsInitializing] = useState(true)

  const loadAll = useCallback(async () => {
    setIsInitializing(true)
    try {
      if (!platformRef.current) {
        platformRef.current = await window.electronAPI.getPlatform()
        setPlatform(platformRef.current)
      }
      const currentPlatform = platformRef.current!

      if (currentPlatform === 'win32') {
        const { video, audio } = await window.electronAPI.getDshowDevices()
        setWebcams(video.map((d) => ({ id: d.alternativeName, name: d.name })))
        setMics(audio.map((d) => ({ id: d.alternativeName, name: d.name })))
        return
      }

      // Single getUserMedia call so macOS only fires one permission prompt.
      // Try audio+video together; fall back to audio-only if no camera is present.
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true })
        stream.getTracks().forEach((track) => track.stop())
      } catch {
        try {
          const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
          stream.getTracks().forEach((track) => track.stop())
        } catch (err) {
          console.warn('Could not get media permissions:', err)
        }
      }

      const allDevices = await navigator.mediaDevices.enumerateDevices()
      setWebcams(
        allDevices
          .filter((d) => d.kind === 'videoinput')
          .map((d) => ({ id: d.deviceId, name: d.label || 'Unnamed Webcam' })),
      )
      setMics(
        allDevices
          .filter((d) => d.kind === 'audioinput')
          .map((d) => ({ id: d.deviceId, name: d.label || 'Unnamed Microphone' })),
      )
    } catch (error) {
      console.error('Failed to load devices:', error)
    } finally {
      setIsInitializing(false)
    }
  }, []) // stable ref — no external deps that cause re-runs

  useEffect(() => {
    loadAll()
  }, [loadAll])

  return { platform, webcams, mics, isInitializing, reload: loadAll }
}
