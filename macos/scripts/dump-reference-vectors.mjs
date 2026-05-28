#!/usr/bin/env node
// Dumps golden parity vectors from the original JS algorithms so the Swift
// port can assert byte-for-byte (well, float-for-float) parity. The function
// bodies below are copied verbatim from:
//   src/lib/easing.ts, src/lib/transform.ts, src/lib/utils.ts,
//   src/store/slices/timelineSlice.ts, src/lib/constants.ts
// Keep them in sync if the originals change.

import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

// ----------------------------------------------------------------------------
// easing.ts
// ----------------------------------------------------------------------------
function createSpringEasing({ tension = 250, friction = 25, mass = 1 } = {}) {
  const stiffness = tension
  const damping = friction
  const velocity = 0
  return (t) => {
    if (t === 0) return 0
    if (t === 1) return 1
    const m_w0 = Math.sqrt(stiffness / mass)
    const m_zeta = damping / (2 * Math.sqrt(stiffness * mass))
    if (m_zeta < 1) {
      const m_wd = m_w0 * Math.sqrt(1 - m_zeta * m_zeta)
      const b = (m_zeta * m_w0 + -velocity) / m_wd
      return 1 - Math.exp(-t * m_zeta * m_w0) * ((1 + b * Math.sin(m_wd * t)) * Math.cos(m_wd * t) + Math.sin(m_wd * t) * -1)
    } else {
      const g = m_w0
      const h = velocity + m_w0
      return 1 - (Math.exp(-t * g) * (1 + h * t)) / Math.exp(0)
    }
  }
}
const easeInOutCubic = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)
const easeInOutQuint = (t) => {
  if (t < 0.5) return 16 * t * t * t * t * t
  const f = 2 * t - 2
  return 0.5 * f * f * f * f * f + 1
}
const easeOutQuint = (t) => 1 - Math.pow(1 - t, 5)
const EASING_MAP = {
  Smooth: easeOutQuint,
  Balanced: easeInOutQuint,
  Dynamic: easeInOutCubic,
  'Gentle Spring': createSpringEasing({ tension: 180, friction: 30, mass: 1 }),
  'Bouncy Spring': createSpringEasing({ tension: 380, friction: 20, mass: 1 }),
}

// ----------------------------------------------------------------------------
// transform.ts
// ----------------------------------------------------------------------------
function lerp(start, end, t) {
  return start * (1 - t) + end * t
}
const findLastMetadataIndex = (metadata, currentTime) => {
  if (metadata.length === 0) return -1
  let left = 0,
    right = metadata.length - 1,
    result = -1
  while (left <= right) {
    const mid = Math.floor((left + right) / 2)
    if (metadata[mid].timestamp <= currentTime) {
      result = mid
      left = mid + 1
    } else right = mid - 1
  }
  return result
}
function getSmoothedMousePosition(metadata, targetTime, smoothingFactor = 0.1) {
  const endIndex = findLastMetadataIndex(metadata, targetTime)
  if (endIndex < 0) return null
  const startTime = Math.max(0, targetTime - 0.5)
  let startIndex = findLastMetadataIndex(metadata, startTime)
  if (startIndex < 0) startIndex = 0
  if (startIndex >= metadata.length) return null
  let smoothedX = metadata[startIndex].x
  let smoothedY = metadata[startIndex].y
  for (let i = startIndex + 1; i <= endIndex; i++) {
    smoothedX = lerp(smoothedX, metadata[i].x, smoothingFactor)
    smoothedY = lerp(smoothedY, metadata[i].y, smoothingFactor)
  }
  const lastEvent = metadata[endIndex]
  if (endIndex + 1 < metadata.length) {
    const nextEvent = metadata[endIndex + 1]
    const timeDiff = nextEvent.timestamp - lastEvent.timestamp
    if (timeDiff > 0) {
      const progress = (targetTime - lastEvent.timestamp) / timeDiff
      const finalX = lerp(smoothedX, nextEvent.x, smoothingFactor)
      const finalY = lerp(smoothedY, nextEvent.y, smoothingFactor)
      return { x: lerp(smoothedX, finalX, progress), y: lerp(smoothedY, finalY, progress) }
    }
  }
  return { x: smoothedX, y: smoothedY }
}
function calculateBoundedPan(mousePos, origin, zoomLevel, recordingGeometry, frameContentDimensions) {
  if (!mousePos) return { tx: 0, ty: 0 }
  const nsmx = mousePos.x / recordingGeometry.width
  const nsmy = mousePos.y / recordingGeometry.height
  const targetFinalPanX = (0.5 - ((nsmx - origin.x) * zoomLevel + origin.x)) * frameContentDimensions.width
  const targetFinalPanY = (0.5 - ((nsmy - origin.y) * zoomLevel + origin.y)) * frameContentDimensions.height
  const targetTranslateX = targetFinalPanX / zoomLevel
  const targetTranslateY = targetFinalPanY / zoomLevel
  const maxTx = (origin.x * frameContentDimensions.width * (zoomLevel - 1)) / zoomLevel
  const minTx = -((1 - origin.x) * frameContentDimensions.width * (zoomLevel - 1)) / zoomLevel
  const maxTy = (origin.y * frameContentDimensions.height * (zoomLevel - 1)) / zoomLevel
  const minTy = -((1 - origin.y) * frameContentDimensions.height * (zoomLevel - 1)) / zoomLevel
  const tx = Math.max(minTx, Math.min(maxTx, targetTranslateX))
  const ty = Math.max(minTy, Math.min(maxTy, targetTranslateY))
  return { tx, ty }
}
function getTransformOrigin(targetX, targetY) {
  return { x: targetX + 0.5, y: targetY + 0.5 }
}
const calculateZoomTransform = (currentTime, zoomRegions, metadata, recordingGeometry, frameContentDimensions) => {
  const activeRegion = Object.values(zoomRegions).find((r) => currentTime >= r.startTime && currentTime < r.startTime + r.duration)
  const defaultTransform = { scale: 1, translateX: 0, translateY: 0, transformOrigin: '50% 50%' }
  if (!activeRegion) return defaultTransform
  const { startTime, duration, zoomLevel, targetX, targetY, mode, easing, transitionDuration } = activeRegion
  const zoomOutStartTime = startTime + duration - transitionDuration
  const zoomInEndTime = startTime + transitionDuration
  const fixedOrigin = getTransformOrigin(targetX, targetY)
  const transformOrigin = `${fixedOrigin.x * 100}% ${fixedOrigin.y * 100}%`
  let currentScale = 1,
    currentTranslateX = 0,
    currentTranslateY = 0
  let initialPan = { tx: 0, ty: 0 },
    livePan = { tx: 0, ty: 0 },
    finalPan = { tx: 0, ty: 0 }
  if (mode === 'auto' && metadata.length > 0 && recordingGeometry.width > 0) {
    initialPan = calculateBoundedPan(getSmoothedMousePosition(metadata, zoomInEndTime), fixedOrigin, zoomLevel, recordingGeometry, frameContentDimensions)
    livePan = calculateBoundedPan(getSmoothedMousePosition(metadata, currentTime), fixedOrigin, zoomLevel, recordingGeometry, frameContentDimensions)
    finalPan = calculateBoundedPan(getSmoothedMousePosition(metadata, zoomOutStartTime), fixedOrigin, zoomLevel, recordingGeometry, frameContentDimensions)
  }
  if (currentTime >= startTime && currentTime < zoomInEndTime) {
    const t = (EASING_MAP[easing] || EASING_MAP.Balanced)((currentTime - startTime) / transitionDuration)
    currentScale = lerp(1, zoomLevel, t)
    currentTranslateX = lerp(0, initialPan.tx, t)
    currentTranslateY = lerp(0, initialPan.ty, t)
  } else if (currentTime >= zoomInEndTime && currentTime < zoomOutStartTime) {
    currentScale = zoomLevel
    currentTranslateX = livePan.tx
    currentTranslateY = livePan.ty
  } else if (currentTime >= zoomOutStartTime && currentTime <= startTime + duration) {
    const t = (EASING_MAP[easing] || EASING_MAP.Balanced)((currentTime - zoomOutStartTime) / transitionDuration)
    currentScale = lerp(zoomLevel, 1, t)
    currentTranslateX = lerp(finalPan.tx, 0, t)
    currentTranslateY = lerp(finalPan.ty, 0, t)
  }
  return { scale: currentScale, translateX: currentTranslateX, translateY: currentTranslateY, transformOrigin }
}

// ----------------------------------------------------------------------------
// utils.ts — mapExportTimeToSourceTime + synthesizeClicksFromMoves
// ----------------------------------------------------------------------------
const mapExportTimeToSourceTime = (exportTime, duration, cutRegions, speedRegions) => {
  const allCuts = Object.values(cutRegions)
  const allSpeeds = Object.values(speedRegions)
  const events = new Set([0, duration])
  allCuts.forEach((r) => {
    events.add(r.startTime)
    events.add(r.startTime + r.duration)
  })
  allSpeeds.forEach((r) => {
    events.add(r.startTime)
    events.add(r.startTime + r.duration)
  })
  const sortedEvents = Array.from(events).sort((a, b) => a - b).filter((t) => t >= 0 && t <= duration)
  let accumulatedExportTime = 0
  let sourceTime = 0
  for (let i = 0; i < sortedEvents.length - 1; i++) {
    const segmentStart = sortedEvents[i]
    const segmentEnd = sortedEvents[i + 1]
    const segmentSourceDuration = segmentEnd - segmentStart
    const midpoint = segmentStart + segmentSourceDuration / 2
    const isCut = allCuts.some((r) => midpoint >= r.startTime && midpoint < r.startTime + r.duration)
    if (isCut) {
      sourceTime = segmentEnd
      continue
    }
    const activeSpeedRegion = allSpeeds.find((r) => midpoint >= r.startTime && midpoint < r.startTime + r.duration)
    const speed = activeSpeedRegion ? activeSpeedRegion.speed : 1
    const segmentExportDuration = segmentSourceDuration / speed
    const endOfSegmentExportTime = accumulatedExportTime + segmentExportDuration
    if (exportTime <= endOfSegmentExportTime) {
      const timeIntoSegmentExport = exportTime - accumulatedExportTime
      const timeIntoSegmentSource = timeIntoSegmentExport * speed
      return segmentStart + timeIntoSegmentSource
    }
    accumulatedExportTime = endOfSegmentExportTime
    sourceTime = segmentEnd
  }
  return sourceTime
}
function exportDuration(duration, cutRegions, speedRegions) {
  let d = duration
  Object.values(cutRegions).forEach((r) => (d -= r.duration))
  Object.values(speedRegions).forEach((r) => {
    d -= r.duration
    d += r.duration / r.speed
  })
  return Math.max(0, d)
}
function synthesizeClicksFromMoves(metadata) {
  const PAUSE_RADIUS = 15
  const MIN_PAUSE_S = 0.1
  const MAX_PAUSE_S = 2.5
  const moves = metadata.filter((m) => m.type === 'move').sort((a, b) => a.timestamp - b.timestamp)
  if (moves.length === 0) return []
  const synthetic = []
  let i = 0
  while (i < moves.length) {
    const anchor = moves[i]
    let j = i + 1
    while (j < moves.length && Math.abs(moves[j].x - anchor.x) <= PAUSE_RADIUS && Math.abs(moves[j].y - anchor.y) <= PAUSE_RADIUS) j++
    const dwellS = moves[Math.min(j, moves.length) - 1].timestamp - anchor.timestamp
    if (dwellS >= MIN_PAUSE_S && dwellS <= MAX_PAUSE_S) synthetic.push({ ...anchor, type: 'click', pressed: true })
    i = j
  }
  return synthetic
}

// ----------------------------------------------------------------------------
// timelineSlice.ts — generateZoomRegionsFromClicks (pure form)
// ----------------------------------------------------------------------------
const ZOOM = {
  SPEED_OPTIONS: { Slow: 1.5, Mellow: 1.0, Quick: 0.7, Rapid: 0.4 },
  DEFAULT_SPEED: 'Mellow',
  DEFAULT_LEVEL: 1.5,
  DEFAULT_EASING: 'Balanced',
  AUTO_ZOOM_PRE_CLICK_OFFSET: 1.0,
  AUTO_ZOOM_POST_CLICK_PADDING: 0.9,
  AUTO_ZOOM_MIN_DURATION: 3.0,
}
const TIMELINE = { MINIMUM_REGION_DURATION: 0.1 }
function generateZoomRegions(metadata, recordingGeometry, duration) {
  if (duration === 0 || !recordingGeometry) return []
  let clicks = metadata.filter((m) => m.type === 'click').sort((a, b) => a.timestamp - b.timestamp)
  if (clicks.length === 0) clicks = synthesizeClicksFromMoves(metadata).sort((a, b) => a.timestamp - b.timestamp)
  if (clicks.length === 0) return []
  const transitionDuration = ZOOM.SPEED_OPTIONS[ZOOM.DEFAULT_SPEED]
  const groups = []
  let groupStart = clicks[0]
  let groupEnd = clicks[0]
  for (let i = 1; i < clicks.length; i++) {
    if (clicks[i].timestamp - groupEnd.timestamp < ZOOM.AUTO_ZOOM_MIN_DURATION) groupEnd = clicks[i]
    else {
      groups.push({ first: groupStart, last: groupEnd })
      groupStart = clicks[i]
      groupEnd = clicks[i]
    }
  }
  groups.push({ first: groupStart, last: groupEnd })
  const newRegions = []
  for (const { first, last } of groups) {
    const startTime = Math.max(0, first.timestamp - ZOOM.AUTO_ZOOM_PRE_CLICK_OFFSET)
    const rawDuration = last.timestamp + ZOOM.AUTO_ZOOM_POST_CLICK_PADDING - startTime
    const regionDuration = Math.max(ZOOM.AUTO_ZOOM_MIN_DURATION, Math.min(rawDuration, duration - startTime))
    if (regionDuration < TIMELINE.MINIMUM_REGION_DURATION) continue
    newRegions.push({
      startTime,
      duration: regionDuration,
      zoomLevel: ZOOM.DEFAULT_LEVEL,
      easing: ZOOM.DEFAULT_EASING,
      transitionDuration,
      targetX: first.x / recordingGeometry.width - 0.5,
      targetY: first.y / recordingGeometry.height - 0.5,
      mode: 'auto',
    })
  }
  return newRegions
}

// ----------------------------------------------------------------------------
// Geometry helpers (renderer.ts getWebcamRectForPosition, utils calculateRulerInterval,
// RendererPage export dims, utils rgbaToHexAlpha)
// ----------------------------------------------------------------------------
function getWebcamRectForPosition(pos, width, height, outputWidth, outputHeight) {
  const baseSize = Math.min(outputWidth, outputHeight)
  const edgePadding = baseSize * 0.02
  switch (pos) {
    case 'top-left': return { x: edgePadding, y: edgePadding, width, height }
    case 'top-center': return { x: (outputWidth - width) / 2, y: edgePadding, width, height }
    case 'top-right': return { x: outputWidth - width - edgePadding, y: edgePadding, width, height }
    case 'left-center': return { x: edgePadding, y: (outputHeight - height) / 2, width, height }
    case 'right-center': return { x: outputWidth - width - edgePadding, y: (outputHeight - height) / 2, width, height }
    case 'bottom-left': return { x: edgePadding, y: outputHeight - height - edgePadding, width, height }
    case 'bottom-center': return { x: (outputWidth - width) / 2, y: outputHeight - height - edgePadding, width, height }
    default: return { x: outputWidth - width - edgePadding, y: outputHeight - height - edgePadding, width, height }
  }
}
const calculateRulerInterval = (pixelsPerSecond) => {
  const niceIntervals = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
  const minMajorPixelSpacing = 90
  const major = niceIntervals.find((interval) => interval * pixelsPerSecond > minMajorPixelSpacing) || niceIntervals[niceIntervals.length - 1]
  const minMinorPixelSpacing = 10
  const possibleSubdivisions = [10, 5, 4, 2]
  for (const sub of possibleSubdivisions) {
    const minor = major / sub
    if (minor * pixelsPerSecond > minMinorPixelSpacing) return { major, minor }
  }
  return { major, minor: major / 2 }
}
const RESOLUTIONS = { '720p': { width: 1280, height: 720 }, '1080p': { width: 1920, height: 1080 }, '2k': { width: 2560, height: 1440 } }
function exportDimensions(resolution, aspectRatio) {
  const [ratioW, ratioH] = aspectRatio.split(':').map(Number)
  const baseHeight = RESOLUTIONS[resolution].height
  let outputWidth = Math.round(baseHeight * (ratioW / ratioH))
  outputWidth = outputWidth % 2 === 0 ? outputWidth : outputWidth + 1
  return { width: outputWidth, height: baseHeight }
}
const rgbaToHexAlpha = (rgba) => {
  const result = /^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/.exec(rgba)
  if (!result) return { hex: '#000000', alpha: 1 }
  const r = parseInt(result[1], 10), g = parseInt(result[2], 10), b = parseInt(result[3], 10)
  const alpha = result[4] !== undefined ? parseFloat(result[4]) : 1
  const toHex = (c) => ('0' + c.toString(16)).slice(-2)
  return { hex: `#${toHex(r)}${toHex(g)}${toHex(b)}`, alpha }
}

// ----------------------------------------------------------------------------
// Build vectors
// ----------------------------------------------------------------------------
const out = {}

// Easing: each curve at t = 0, 0.05, ..., 1.0
out.easing = []
for (const curve of Object.keys(EASING_MAP)) {
  for (let i = 0; i <= 20; i++) {
    const t = i / 20
    out.easing.push({ curve, t, value: EASING_MAP[curve](t) })
  }
}

// Zoom transform scenarios
const ztMeta = [
  { timestamp: 0, x: 100, y: 100, type: 'move' },
  { timestamp: 0.5, x: 500, y: 400, type: 'move' },
  { timestamp: 1.0, x: 900, y: 600, type: 'move' },
  { timestamp: 1.5, x: 1200, y: 700, type: 'move' },
  { timestamp: 2.0, x: 1500, y: 800, type: 'click', pressed: true },
  { timestamp: 3.0, x: 1600, y: 850, type: 'move' },
  { timestamp: 4.0, x: 1000, y: 500, type: 'move' },
  { timestamp: 6.0, x: 700, y: 350, type: 'move' },
  { timestamp: 8.0, x: 300, y: 200, type: 'move' },
]
const ztGeo = { width: 1920, height: 1080 }
const ztFrame = { width: 1280, height: 720 }
const ztRegions = {
  z1: { id: 'z1', type: 'zoom', startTime: 1.0, duration: 3.0, zoomLevel: 2.0, easing: 'Balanced', transitionDuration: 1.0, targetX: 0.1, targetY: 0.05, mode: 'auto', zIndex: 10 },
  z2: { id: 'z2', type: 'zoom', startTime: 5.0, duration: 3.0, zoomLevel: 1.5, easing: 'Smooth', transitionDuration: 0.7, targetX: 0, targetY: 0, mode: 'fixed', zIndex: 10 },
}
const ztTimes = [0.5, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.25, 3.5, 3.75, 4.0, 4.5, 5.0, 5.35, 5.7, 6.5, 7.3, 8.0, 9.0]
out.zoomTransform = {
  metadata: ztMeta,
  geometry: ztGeo,
  frame: ztFrame,
  regions: ztRegions,
  samples: ztTimes.map((t) => {
    const r = calculateZoomTransform(t, ztRegions, ztMeta, ztGeo, ztFrame)
    return { t, scale: r.scale, translateX: r.translateX, translateY: r.translateY, transformOrigin: r.transformOrigin }
  }),
}

// Time remap
const trDuration = 20
const trCuts = { c1: { id: 'c1', type: 'cut', startTime: 5, duration: 2, zIndex: 10 } }
const trSpeeds = { s1: { id: 's1', type: 'speed', startTime: 10, duration: 4, speed: 2, zIndex: 10 } }
const trTimes = [0, 1, 2, 3, 4, 4.9, 5, 6, 7, 7.5, 8, 9, 9.5, 10, 11, 12, 13, 14, 15, 16]
out.timeRemap = {
  duration: trDuration,
  cuts: trCuts,
  speeds: trSpeeds,
  exportDuration: exportDuration(trDuration, trCuts, trSpeeds),
  samples: trTimes.map((exportTime) => ({ exportTime, sourceTime: mapExportTimeToSourceTime(exportTime, trDuration, trCuts, trSpeeds) })),
}
// passthrough case
out.timeRemapPassthrough = {
  duration: 10,
  samples: [0, 2.5, 5, 9.999].map((exportTime) => ({ exportTime, sourceTime: mapExportTimeToSourceTime(exportTime, 10, {}, {}) })),
}

// Auto-zoom (real clicks)
const azMeta = [
  { timestamp: 2.0, x: 960, y: 540, type: 'click', pressed: true },
  { timestamp: 2.5, x: 970, y: 545, type: 'click', pressed: true },
  { timestamp: 10.0, x: 480, y: 300, type: 'click', pressed: true },
]
const azGeo = { width: 1920, height: 1080 }
out.autoZoom = { metadata: azMeta, geometry: azGeo, duration: 15, regions: generateZoomRegions(azMeta, azGeo, 15) }

// Auto-zoom via dwell synthesis (no clicks) — moves dwelling near a point
const azSynthMeta = [
  { timestamp: 0.0, x: 100, y: 100, type: 'move' },
  { timestamp: 0.2, x: 400, y: 300, type: 'move' },
  { timestamp: 0.5, x: 402, y: 301, type: 'move' },
  { timestamp: 0.9, x: 405, y: 305, type: 'move' },
  { timestamp: 1.2, x: 408, y: 299, type: 'move' },
  { timestamp: 3.0, x: 900, y: 700, type: 'move' },
  { timestamp: 3.2, x: 905, y: 702, type: 'move' },
  { timestamp: 3.9, x: 901, y: 698, type: 'move' },
]
out.autoZoomSynth = {
  metadata: azSynthMeta,
  synthesizedClicks: synthesizeClicksFromMoves(azSynthMeta),
  geometry: azGeo,
  duration: 12,
  regions: generateZoomRegions(azSynthMeta, azGeo, 12),
}

// Geometry
out.geometry = {
  webcamRects: ['top-left', 'top-center', 'top-right', 'left-center', 'right-center', 'bottom-left', 'bottom-center', 'bottom-right'].map((pos) => ({
    pos,
    rect: getWebcamRectForPosition(pos, 200, 150, 1920, 1080),
  })),
  ruler: [5, 20, 50, 90, 150, 400].map((pps) => ({ pps, ...calculateRulerInterval(pps) })),
  exportDims: [
    ['720p', '16:9'], ['1080p', '16:9'], ['2k', '16:9'], ['1080p', '9:16'], ['1080p', '1:1'], ['1080p', '3:2'], ['2k', '4:3'],
  ].map(([r, a]) => ({ resolution: r, aspectRatio: a, ...exportDimensions(r, a) })),
  colors: ['rgba(0, 0, 0, 0.8)', 'rgba(255, 255, 255, 0.2)', 'rgba(255, 128, 0, 0.5)', 'rgb(16, 32, 48)'].map((c) => ({ input: c, ...rgbaToHexAlpha(c) })),
}

const __filename = fileURLToPath(import.meta.url)
const outPath = new URL('../SmooothCore/Tests/SmooothCoreTests/Fixtures/vectors.json', import.meta.url)
mkdirSync(dirname(fileURLToPath(outPath)), { recursive: true })
writeFileSync(fileURLToPath(outPath), JSON.stringify(out, null, 2))
console.log(`Wrote vectors.json: ${out.easing.length} easing, ${out.zoomTransform.samples.length} zoom, ${out.timeRemap.samples.length} remap, ${out.autoZoom.regions.length}+${out.autoZoomSynth.regions.length} auto-zoom regions, ${out.geometry.webcamRects.length} webcam rects.`)
