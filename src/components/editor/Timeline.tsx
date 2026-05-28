import React, { useRef, useState, useEffect, useCallback, useMemo, memo } from 'react'
import { useShallow } from 'zustand/react/shallow'
import { useEditorStore, useAllRegions } from '../../store/editorStore'
import { ZoomRegionBlock } from './timeline/ZoomRegionBlock'
import { CutRegionBlock } from './timeline/CutRegionBlock'
import { SpeedRegionBlock } from './timeline/SpeedRegionBlock'
import { Playhead } from './timeline/Playhead'
import { cn } from '../../lib/utils'
import { Scissors } from 'tabler-icons-react'
import { formatTime, calculateRulerInterval } from '../../lib/utils'
import { useTimelineInteraction } from '../../hooks/useTimelineInteraction'
import { FlipScissorsIcon } from '../ui/icons'

// Memoized Ruler component (không thay đổi)
const Ruler = memo(
  ({
    ticks,
    timeToPx,
    formatTime: formatTimeFunc,
  }: {
    ticks: { time: number; type: string }[]
    timeToPx: (time: number) => number
    formatTime: (seconds: number) => string
  }) => (
    <div className="h-12 sticky overflow-hidden top-0 left-0 right-0 z-10 border-b border-border/30 bg-card/60 backdrop-blur-md">
      <div className="relative h-full pt-2">
        {ticks.map(({ time, type }) => (
          <div key={`${type}-${time}`} className="absolute top-2 h-full" style={{ left: `${timeToPx(time)}px` }}>
            <div
              className={cn(
                'timeline-tick absolute top-0 left-1/2 -translate-x-1/2 w-px',
                type === 'major' ? 'h-5 opacity-60' : 'h-2.5 opacity-30',
              )}
            />
            {type === 'major' && (
              <span className="absolute top-3.5 left-1 text-[10px] text-foreground/70 font-mono font-medium tracking-tight">
                {formatTimeFunc(time)}
              </span>
            )}
          </div>
        ))}
      </div>
    </div>
  ),
)
Ruler.displayName = 'Ruler'

export function Timeline({ videoRef }: { videoRef: React.RefObject<HTMLVideoElement> }) {
  const { currentTime, duration, timelineZoom, previewCutRegion, selectedRegionId, isPlaying } = useEditorStore(
    useShallow((state) => ({
      currentTime: state.currentTime,
      duration: state.duration,
      timelineZoom: state.timelineZoom,
      previewCutRegion: state.previewCutRegion,
      selectedRegionId: state.selectedRegionId,
      isPlaying: state.isPlaying,
    })),
  )
  const { setCurrentTime, setSelectedRegionId } = useEditorStore()

  const containerRef = useRef<HTMLDivElement>(null)
  const timelineRef = useRef<HTMLDivElement>(null)
  const playheadRef = useRef<HTMLDivElement>(null)
  const regionRefs = useRef<Map<string, HTMLDivElement | null>>(new Map())
  const animationFrameRef = useRef<number>()

  const [containerWidth, setContainerWidth] = useState(0)

  useEffect(() => {
    const containerEl = containerRef.current
    let widthObserver: ResizeObserver | null = null

    if (containerEl) {
      setContainerWidth(containerEl.clientWidth)
      widthObserver = new ResizeObserver((entries) => {
        if (entries[0]) setContainerWidth(entries[0].contentRect.width)
      })
      widthObserver.observe(containerEl)
    }

    return () => {
      if (widthObserver && containerEl) widthObserver.unobserve(containerEl)
    }
  }, [])

  const pixelsPerSecond = useMemo(() => {
    if (duration === 0 || containerWidth === 0) return 200
    return (containerWidth / duration) * timelineZoom
  }, [duration, containerWidth, timelineZoom])

  const timeToPx = useCallback((time: number) => time * pixelsPerSecond, [pixelsPerSecond])
  const pxToTime = useCallback((px: number) => px / pixelsPerSecond, [pixelsPerSecond])

  const updateVideoTime = useCallback(
    (time: number) => {
      const clampedTime = Math.max(0, Math.min(time, duration))
      setCurrentTime(clampedTime)
      if (videoRef.current) videoRef.current.currentTime = clampedTime
    },
    [duration, setCurrentTime, videoRef],
  )

  const {
    draggingRegionId,
    handleRegionMouseDown,
    handlePlayheadMouseDown,
    handleLeftStripMouseDown,
    handleRightStripMouseDown,
  } = useTimelineInteraction({
    timelineRef,
    regionRefs,
    pxToTime,
    timeToPx,
    updateVideoTime,
    duration,
  })

  const rulerTicks = useMemo(() => {
    if (duration <= 0 || pixelsPerSecond <= 0) return []
    const { major, minor } = calculateRulerInterval(pixelsPerSecond)
    const ticks = []
    for (let time = 0; time <= duration; time += major) {
      ticks.push({ time: parseFloat(time.toPrecision(10)), type: 'major' })
    }
    for (let time = 0; time <= duration; time += minor) {
      const preciseTime = parseFloat(time.toPrecision(10))
      if (preciseTime % major !== 0) {
        ticks.push({ time: preciseTime, type: 'minor' })
      }
    }
    return ticks
  }, [duration, pixelsPerSecond])

  useEffect(() => {
    const animate = () => {
      if (videoRef.current && playheadRef.current) {
        playheadRef.current.style.transform = `translateX(${timeToPx(videoRef.current.currentTime)}px)`
      }
      animationFrameRef.current = requestAnimationFrame(animate)
    }
    if (isPlaying) {
      animationFrameRef.current = requestAnimationFrame(animate)
    }
    return () => {
      if (animationFrameRef.current) cancelAnimationFrame(animationFrameRef.current)
    }
  }, [isPlaying, timeToPx, videoRef])

  useEffect(() => {
    if (!isPlaying && playheadRef.current) {
      playheadRef.current.style.transform = `translateX(${timeToPx(currentTime)}px)`
    }
  }, [currentTime, isPlaying, timeToPx])

  const { zoomRegions, cutRegions, speedRegions } = useAllRegions()

  const hasSpeedRegions = useMemo(() => Object.keys(speedRegions).length > 0, [speedRegions])

  const allRegionsToRender = useMemo(() => {
    const combined = [...Object.values(zoomRegions), ...Object.values(cutRegions), ...Object.values(speedRegions)]
    if (previewCutRegion) {
      combined.push(previewCutRegion)
    }
    return combined
  }, [zoomRegions, cutRegions, speedRegions, previewCutRegion])

  return (
    <div
      className={cn(
        'flex flex-col bg-background/50 p-3 transition-all duration-300 ease-in-out',
        hasSpeedRegions ? 'h-56' : 'h-44',
      )}
    >
      <div className="h-full flex flex-row rounded-xl overflow-hidden shadow-xl bg-card border border-border">
        <div
          className="w-8 shrink-0 h-full bg-gradient-to-b from-card to-muted/30 flex items-center justify-center transition-all duration-200 cursor-ew-resize select-none border-r border-border hover:bg-accent/40 active:bg-accent/60 group"
          onMouseDown={handleLeftStripMouseDown}
        >
          <Scissors size={16} className="text-muted-foreground group-hover:text-foreground transition-colors" />
        </div>

        <div
          ref={containerRef}
          className="flex-1 overflow-x-auto overflow-y-hidden bg-gradient-to-b from-background/30 to-background/10"
          onMouseDown={(e) => {
            if (duration === 0 || (e.target as HTMLElement).closest('[data-region-id]')) return
            const rect = (e.currentTarget as HTMLDivElement).getBoundingClientRect()
            const clickX = e.clientX - rect.left + (e.currentTarget as HTMLDivElement).scrollLeft
            updateVideoTime(pxToTime(clickX))
            setSelectedRegionId(null)
          }}
        >
          <div
            ref={timelineRef}
            className="relative h-full min-w-full overflow-hidden"
            style={{ width: `${timeToPx(duration)}px` }}
          >
            <Ruler ticks={rulerTicks} timeToPx={timeToPx} formatTime={formatTime} />

            <div className="absolute top-12 left-0 w-full" style={{ height: 'calc(100% - 3rem)' }}>
              {allRegionsToRender.map((region) => {
                const isSelected = selectedRegionId === region.id
                const zIndex = isSelected ? 100 : (region.zIndex ?? 1)

                const regionStyle: React.CSSProperties = {
                  left: `${timeToPx(region.startTime)}px`,
                  width: `${timeToPx(region.duration)}px`,
                  zIndex: zIndex,
                }

                if (region.type === 'zoom' || region.type === 'cut') {
                  return (
                    <div
                      key={region.id}
                      className={cn('absolute top-0', hasSpeedRegions ? 'h-1/2' : 'h-full')}
                      style={regionStyle}
                    >
                      {region.type === 'zoom' && (
                        <ZoomRegionBlock
                          region={region}
                          isSelected={isSelected}
                          isBeingDragged={draggingRegionId === region.id}
                          onMouseDown={handleRegionMouseDown}
                          setRef={(el) => regionRefs.current.set(region.id, el)}
                        />
                      )}
                      {region.type === 'cut' && (
                        <CutRegionBlock
                          region={region}
                          isSelected={isSelected}
                          isDraggable={region.id !== previewCutRegion?.id}
                          isBeingDragged={draggingRegionId === region.id}
                          onMouseDown={handleRegionMouseDown}
                          setRef={(el) => regionRefs.current.set(region.id, el)}
                        />
                      )}
                    </div>
                  )
                }

                if (region.type === 'speed') {
                  return (
                    <div key={region.id} className="absolute bottom-0 h-1/2" style={regionStyle}>
                      <SpeedRegionBlock
                        region={region}
                        isSelected={isSelected}
                        isBeingDragged={draggingRegionId === region.id}
                        onMouseDown={handleRegionMouseDown}
                        setRef={(el) => regionRefs.current.set(region.id, el)}
                      />
                    </div>
                  )
                }
                return null
              })}
            </div>

            {duration > 0 && (
              <div
                ref={playheadRef}
                className="absolute top-0 bottom-0 z-[200]"
                style={{ transform: `translateX(${timeToPx(currentTime)}px)`, pointerEvents: 'none' }}
              >
                <Playhead
                  height={Math.floor((timelineRef.current?.clientHeight ?? 0) * 0.9)}
                  isDragging={false}
                  onMouseDown={handlePlayheadMouseDown}
                />
              </div>
            )}
          </div>
        </div>

        <div
          className="w-8 shrink-0 h-full bg-gradient-to-b from-card to-muted/30 flex items-center justify-center transition-all duration-200 cursor-ew-resize select-none border-l border-border hover:bg-accent/40 active:bg-accent/60 group"
          onMouseDown={handleRightStripMouseDown}
        >
          <FlipScissorsIcon size={16} className="text-muted-foreground group-hover:text-foreground transition-colors" />
        </div>
      </div>
    </div>
  )
}
