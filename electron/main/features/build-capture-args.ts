// Pure functions for building FFmpeg capture input and output args.
// No Electron dependencies — safe to unit-test in plain Node.

interface CaptureDevice {
  index: number
  deviceLabel: string
}

/**
 * Builds the avfoundation input segment for macOS.
 * Combines mic + webcam into a single "-i videoIdx:audioIdx" to avoid
 * dual AVCaptureSession conflicts. Returns [] when neither device is set.
 */
export function buildMacAvfoundationInput(
  mic: CaptureDevice | undefined,
  webcam: CaptureDevice | undefined,
): string[] {
  if (!mic && !webcam) return []
  const videoIdx = webcam ? `${webcam.index}` : 'none'
  const audioIdx = mic ? `${mic.index}` : 'none'
  const frameRateArgs: string[] = webcam ? ['-framerate', '30'] : []
  return ['-f', 'avfoundation', ...frameRateArgs, '-i', `${videoIdx}:${audioIdx}`]
}

/**
 * Appends output-mapping args for macOS capture.
 * Assumes a single combined avfoundation input (stream 0:v = webcam, 0:a = mic).
 */
export function buildMacCaptureOutputArgs(
  inputArgs: string[],
  hasMic: boolean,
  hasWebcam: boolean,
  micOut?: string,
  webcamOut?: string,
): string[] {
  const finalArgs = [...inputArgs]
  if (hasMic && micOut) {
    finalArgs.push('-map', '0:a', '-c:a', 'aac', '-b:a', '192k', micOut)
  }
  if (hasWebcam && webcamOut) {
    finalArgs.push('-map', '0:v', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', webcamOut)
  }
  return finalArgs
}
