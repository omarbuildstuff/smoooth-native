import { TIMELINE, ZOOM } from '../../lib/constants'
import type { TimelineState, TimelineActions, Slice } from '../../types'
import type { CutRegion, ZoomRegion, SpeedRegion } from '../../types'
import { synthesizeClicksFromMoves } from '../../lib/utils'

export const initialTimelineState: TimelineState = {
  zoomRegions: {},
  cutRegions: {},
  speedRegions: {},
  previewCutRegion: null,
  selectedRegionId: null,
  activeZoomRegionId: null,
  isCurrentlyCut: false,
  timelineZoom: 1,
}

/**
 * Recalculates and assigns z-index values to all timeline regions based on their duration.
 * Shorter regions get a higher z-index to ensure they are clickable on top of longer ones.
 * This function mutates the draft state directly within an Immer producer.
 * @param state - The current EditorState draft.
 */
const recalculateZIndices = (state: {
  zoomRegions: Record<string, ZoomRegion>
  cutRegions: Record<string, CutRegion>
  speedRegions: Record<string, SpeedRegion>
}) => {
  const allRegions = [
    ...Object.values(state.zoomRegions),
    ...Object.values(state.cutRegions),
    ...Object.values(state.speedRegions),
  ]
  allRegions.sort((a, b) => a.duration - b.duration)

  const regionCount = allRegions.length
  allRegions.forEach((region, index) => {
    const newZIndex = 10 + (regionCount - 1 - index)
    if (state.zoomRegions[region.id]) {
      state.zoomRegions[region.id].zIndex = newZIndex
    } else if (state.cutRegions[region.id]) {
      state.cutRegions[region.id].zIndex = newZIndex
    } else if (state.speedRegions[region.id]) {
      state.speedRegions[region.id].zIndex = newZIndex
    }
  })
}

export const createTimelineSlice: Slice<TimelineState, TimelineActions> = (set, get) => ({
  ...initialTimelineState,
  addZoomRegion: () => {
    const { metadata, currentTime, recordingGeometry, duration } = get()
    if (duration === 0) return

    const lastMousePos = metadata
      .slice()
      .reverse()
      .find((m) => m.timestamp <= currentTime)
    const id = `zoom-${Date.now()}`

    const newRegion: ZoomRegion = {
      id,
      type: 'zoom',
      startTime: currentTime,
      duration: ZOOM.DEFAULT_DURATION,
      zoomLevel: ZOOM.DEFAULT_LEVEL,
      easing: ZOOM.DEFAULT_EASING,
      transitionDuration: ZOOM.SPEED_OPTIONS[ZOOM.DEFAULT_SPEED as keyof typeof ZOOM.SPEED_OPTIONS],
      targetX: lastMousePos && recordingGeometry ? lastMousePos.x / recordingGeometry.width - 0.5 : 0,
      targetY: lastMousePos && recordingGeometry ? lastMousePos.y / recordingGeometry.height - 0.5 : 0,
      mode: 'auto',
      zIndex: 0,
    }

    if (newRegion.startTime + newRegion.duration > duration) {
      newRegion.duration = Math.max(TIMELINE.MINIMUM_REGION_DURATION, duration - newRegion.startTime)
    }

    set((state) => {
      state.zoomRegions[id] = newRegion
      state.selectedRegionId = id
      recalculateZIndices(state)
    })
  },
  addCutRegion: (regionData) => {
    const { currentTime, duration } = get()
    if (duration === 0) return

    const id = `cut-${Date.now()}`
    const newRegion: CutRegion = {
      id,
      type: 'cut',
      startTime: currentTime,
      duration: 2,
      zIndex: 0,
      ...regionData,
    }

    if (newRegion.startTime + newRegion.duration > duration) {
      newRegion.duration = Math.max(TIMELINE.MINIMUM_REGION_DURATION, duration - newRegion.startTime)
    }

    set((state) => {
      state.cutRegions[id] = newRegion
      state.selectedRegionId = id
      recalculateZIndices(state)
    })
  },
  addSpeedRegion: () => {
    const { currentTime, duration } = get()
    if (duration === 0) return

    const id = `speed-${Date.now()}`
    const newRegion: SpeedRegion = {
      id,
      type: 'speed',
      startTime: currentTime,
      duration: 3.0, // default duration
      speed: 1.5, // default speed
      zIndex: 0,
    }

    if (newRegion.startTime + newRegion.duration > duration) {
      newRegion.duration = Math.max(TIMELINE.MINIMUM_REGION_DURATION, duration - newRegion.startTime)
    }

    set((state) => {
      state.speedRegions[id] = newRegion
      state.selectedRegionId = id
      recalculateZIndices(state)
    })
  },
  updateRegion: (id, updates) => {
    set((state) => {
      const region = state.zoomRegions[id] || state.cutRegions[id] || state.speedRegions[id]
      if (region) {
        const oldDuration = region.duration
        Object.assign(region, updates)
        if (oldDuration !== region.duration) {
          recalculateZIndices(state)
        }
      }
    })
  },
  deleteRegion: (id) => {
    set((state) => {
      delete state.zoomRegions[id]
      delete state.cutRegions[id]
      delete state.speedRegions[id]
      if (state.selectedRegionId === id) {
        state.selectedRegionId = null
      }
      recalculateZIndices(state)
    })
  },
  setSelectedRegionId: (id) =>
    set((state) => {
      state.selectedRegionId = id
    }),
  setPreviewCutRegion: (region) =>
    set((state) => {
      state.previewCutRegion = region
    }),
  setTimelineZoom: (zoom) =>
    set((state) => {
      state.timelineZoom = zoom
    }),
  applyAnimationSettingsToAll: ({ transitionDuration, easing, zoomLevel }) => {
    set((state) => {
      Object.values(state.zoomRegions).forEach((region) => {
        region.transitionDuration = transitionDuration
        region.easing = easing
        region.zoomLevel = zoomLevel
      })
    })
  },
  applySpeedToAll: (speed) => {
    set((state) => {
      Object.values(state.speedRegions).forEach((region) => {
        region.speed = speed
      })
    })
  },
  generateZoomRegionsFromClicks: () => {
    const { metadata, recordingGeometry, duration } = get()
    if (duration === 0 || !recordingGeometry) return 0

    // Use all click events; fall back to cursor-pause synthesis on macOS (no CGEventTap)
    let clicks = metadata
      .filter((m) => m.type === 'click')
      .sort((a, b) => a.timestamp - b.timestamp)

    if (clicks.length === 0) {
      clicks = synthesizeClicksFromMoves(metadata).sort((a, b) => a.timestamp - b.timestamp)
    }

    if (clicks.length === 0) return 0

    const transitionDuration = ZOOM.SPEED_OPTIONS[ZOOM.DEFAULT_SPEED as keyof typeof ZOOM.SPEED_OPTIONS]

    // Group clicks separated by less than AUTO_ZOOM_MIN_DURATION (matching project load logic)
    const groups: { first: (typeof clicks)[0]; last: (typeof clicks)[0] }[] = []
    let groupStart = clicks[0]
    let groupEnd = clicks[0]
    for (let i = 1; i < clicks.length; i++) {
      if (clicks[i].timestamp - groupEnd.timestamp < ZOOM.AUTO_ZOOM_MIN_DURATION) {
        groupEnd = clicks[i]
      } else {
        groups.push({ first: groupStart, last: groupEnd })
        groupStart = clicks[i]
        groupEnd = clicks[i]
      }
    }
    groups.push({ first: groupStart, last: groupEnd })

    const newRegions: ZoomRegion[] = []

    for (let i = 0; i < groups.length; i++) {
      const { first, last } = groups[i]
      const startTime = Math.max(0, first.timestamp - ZOOM.AUTO_ZOOM_PRE_CLICK_OFFSET)
      const rawDuration = last.timestamp + ZOOM.AUTO_ZOOM_POST_CLICK_PADDING - startTime
      const regionDuration = Math.max(
        ZOOM.AUTO_ZOOM_MIN_DURATION,
        Math.min(rawDuration, duration - startTime),
      )

      if (regionDuration < TIMELINE.MINIMUM_REGION_DURATION) continue

      const id = `zoom-auto-${Math.round(first.timestamp * 1000)}`
      newRegions.push({
        id,
        type: 'zoom',
        startTime,
        duration: regionDuration,
        zoomLevel: ZOOM.DEFAULT_LEVEL,
        easing: ZOOM.DEFAULT_EASING,
        transitionDuration,
        targetX: first.x / recordingGeometry.width - 0.5,
        targetY: first.y / recordingGeometry.height - 0.5,
        mode: 'auto',
        zIndex: 0,
      })
    }

    if (newRegions.length === 0) return 0

    set((state) => {
      // Replace all existing zoom regions with freshly generated ones
      state.zoomRegions = {}
      for (const region of newRegions) {
        state.zoomRegions[region.id] = region
      }
      state.selectedRegionId = null
      recalculateZIndices(state)
    })

    return newRegions.length
  },
})
