// Regression: webcam recording failure — avfoundation framerate + dual-session conflict
// Found by /qa on 2026-05-28
// Report: .gstack/qa-reports/
import { describe, expect, test } from 'vitest'
import { buildMacAvfoundationInput, buildMacCaptureOutputArgs } from './build-capture-args'

const MIC = { index: 1, deviceLabel: 'Camo Microphone' }
const CAM = { index: 0, deviceLabel: 'FaceTime HD Camera' }
const MIC_OUT = '/tmp/mic.m4a'
const CAM_OUT = '/tmp/webcam.mp4'

describe('buildMacAvfoundationInput', () => {
  test('webcam only: -framerate 30, video index, audio none', () => {
    expect(buildMacAvfoundationInput(undefined, CAM)).toEqual([
      '-f', 'avfoundation',
      '-framerate', '30',
      '-i', '0:none',
    ])
  })

  test('mic only: no framerate, video none, audio index', () => {
    expect(buildMacAvfoundationInput(MIC, undefined)).toEqual([
      '-f', 'avfoundation',
      '-i', 'none:1',
    ])
  })

  test('both mic and webcam: single combined input with -framerate 30', () => {
    expect(buildMacAvfoundationInput(MIC, CAM)).toEqual([
      '-f', 'avfoundation',
      '-framerate', '30',
      '-i', '0:1',
    ])
  })

  test('neither mic nor webcam: empty array', () => {
    expect(buildMacAvfoundationInput(undefined, undefined)).toEqual([])
  })

  test('webcam at index 2 uses correct index', () => {
    const cam2 = { index: 2, deviceLabel: 'Logitech C920' }
    const result = buildMacAvfoundationInput(undefined, cam2)
    expect(result).toContain('2:none')
    expect(result).toContain('-framerate')
  })

  test('mic at index 0 uses correct index', () => {
    const mic0 = { index: 0, deviceLabel: 'Built-in Microphone' }
    const result = buildMacAvfoundationInput(mic0, undefined)
    expect(result).toContain('none:0')
    expect(result).not.toContain('-framerate')
  })
})

describe('buildMacCaptureOutputArgs', () => {
  const INPUT = ['-f', 'avfoundation', '-framerate', '30', '-i', '0:1']

  test('webcam only: maps 0:v to mp4', () => {
    expect(buildMacCaptureOutputArgs(INPUT, false, true, undefined, CAM_OUT)).toEqual([
      ...INPUT,
      '-map', '0:v',
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-pix_fmt', 'yuv420p',
      CAM_OUT,
    ])
  })

  test('mic only: maps 0:a to m4a', () => {
    const micInput = ['-f', 'avfoundation', '-i', 'none:1']
    expect(buildMacCaptureOutputArgs(micInput, true, false, MIC_OUT, undefined)).toEqual([
      ...micInput,
      '-map', '0:a',
      '-c:a', 'aac',
      '-b:a', '192k',
      MIC_OUT,
    ])
  })

  test('both: maps 0:a then 0:v (mic before webcam in output)', () => {
    const result = buildMacCaptureOutputArgs(INPUT, true, true, MIC_OUT, CAM_OUT)
    expect(result).toEqual([
      ...INPUT,
      '-map', '0:a', '-c:a', 'aac', '-b:a', '192k', MIC_OUT,
      '-map', '0:v', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', CAM_OUT,
    ])
  })

  test('neither: returns input args unchanged', () => {
    expect(buildMacCaptureOutputArgs(INPUT, false, false, undefined, undefined)).toEqual(INPUT)
  })

  test('hasMic=true but no micOut: skips mic output', () => {
    const result = buildMacCaptureOutputArgs(INPUT, true, false, undefined, undefined)
    expect(result).toEqual(INPUT)
    expect(result).not.toContain('-map')
  })

  test('hasWebcam=true but no webcamOut: skips webcam output', () => {
    const result = buildMacCaptureOutputArgs(INPUT, false, true, undefined, undefined)
    expect(result).toEqual(INPUT)
    expect(result).not.toContain('-map')
  })
})
