'use strict'

// Capture pipeline: avfoundation → H264 + Opus encoded packets
// Encoded packets are stored in a ring buffer and distributed to peers
// via Protomux channels in peers.js — no Hypercore, no .ts segments.

const ffmpeg = require('bare-ffmpeg')

const VIDEO_W   = 1280
const VIDEO_H   = 720
const VIDEO_FPS = 30
const AUDIO_RATE = 48000
const AUDIO_CH   = 2

// ─── State ────────────────────────────────────────────────────────────────────

let _running        = false
let _videoMuted     = false
let _audioMuted     = false

let _captureCtx     = null
let _videoDecCtx    = null   // decode raw capture packets → frames
let _audioPCMCtx    = null   // decode raw audio capture packets → frames
let _encodeVideo    = null
let _encodeAudio    = null
let _videoScaler    = null   // NV12 → YUV420P for VP8 encoder
let _audioResampler = null
let _audioFifo      = null

// Callbacks set by peers.js — called with each encoded packet
let _onVideoPacket  = null   // (pts, buffer) → void
let _onAudioPacket  = null   // (pts, buffer) → void

// ─── Public API ───────────────────────────────────────────────────────────────

function onVideoPacket (cb) { _onVideoPacket = cb }
function onAudioPacket (cb) { _onAudioPacket = cb }

async function start () {
  if (_running) return
  _running = true

  _setupCapture()
  _setupEncoders()
  _runCaptureLoop()

  console.log('[capture] started')
}

function setMute (videoMuted, audioMuted) {
  _videoMuted = videoMuted
  _audioMuted = audioMuted
}

function stop () {
  _running = false
  try { _captureCtx?.destroy()     } catch {}
  try { _videoDecCtx?.destroy()    } catch {}
  try { _audioPCMCtx?.destroy()    } catch {}
  try { _encodeVideo?.destroy()    } catch {}
  try { _encodeAudio?.destroy()    } catch {}
  try { _videoScaler?.destroy()    } catch {}
  try { _audioResampler?.destroy() } catch {}
  try { _audioFifo?.destroy()      } catch {}
  _captureCtx = _videoDecCtx = _audioPCMCtx = null
  _videoScaler = _encodeVideo = _encodeAudio = _audioResampler = _audioFifo = null
  _onVideoPacket = _onAudioPacket = null
  console.log('[capture] stopped')
}

// ─── Private: setup ───────────────────────────────────────────────────────────

function _setupCapture () {
  const fmt  = new ffmpeg.InputFormat()
  const opts = new ffmpeg.Dictionary()
  opts.set('framerate',    String(VIDEO_FPS))
  opts.set('video_size',   `${VIDEO_W}x${VIDEO_H}`)
  opts.set('pixel_format', 'nv12')
  // Try video+audio first; fall back to video-only if audio device is busy
  // (happens when two instances run on the same machine during testing)
  let opened = false
  for (const url of ['0:0', '0:1', '0']) {
    try {
      _captureCtx = new ffmpeg.InputFormatContext(fmt, opts, url)
      console.log('[capture] avfoundation opened with url:', url)
      opened = true
      break
    } catch (e) {
      console.warn('[capture] avfoundation failed with url:', url, '-', e.message)
    }
  }
  if (!opened) throw new Error('[capture] could not open any avfoundation device')
}

function _setupEncoders () {
  // VP8 software encoder — accepts CPU frames directly from avfoundation.
  // Available in this bare-ffmpeg build. Decoder 'vp8' also available.
  // VideoToolbox H264 requires HW frames (hwFramesCtx) which avfoundation
  // CPU capture doesn't provide — VP8 works without any HW setup.
  _encodeVideo = new ffmpeg.CodecContext(new ffmpeg.Encoder('libvpx'))
  _encodeVideo.width       = VIDEO_W
  _encodeVideo.height      = VIDEO_H
  _encodeVideo.frameRate   = new ffmpeg.Rational(VIDEO_FPS, 1)
  _encodeVideo.timeBase    = new ffmpeg.Rational(1, VIDEO_FPS)
  _encodeVideo.pixelFormat = ffmpeg.constants.pixelFormats.YUV420P
  _encodeVideo.bitRate     = 1_000_000
  _encodeVideo.gopSize     = VIDEO_FPS
  // VP8 quality/speed tradeoff — deadline=1 = realtime
  _encodeVideo.setOption('deadline', 'realtime')
  _encodeVideo.setOption('cpu-used', '8')
  _encodeVideo.open()

  // Opus audio
  _encodeAudio = new ffmpeg.CodecContext(new ffmpeg.Encoder('libopus'))
  _encodeAudio.sampleRate    = AUDIO_RATE
  _encodeAudio.channels      = AUDIO_CH
  _encodeAudio.channelLayout = ffmpeg.constants.toChannelLayout('STEREO')
  _encodeAudio.sampleFormat  = ffmpeg.constants.sampleFormats.FLT
  _encodeAudio.bitRate       = 64_000
  _encodeAudio.open()

  _audioFifo = new ffmpeg.AudioFIFO(ffmpeg.constants.sampleFormats.FLT, AUDIO_CH, 4096)

  console.log('[capture] encoders ready')
}

// ─── Private: capture loop (poll-based for Bare event loop) ──────────────────

function _runCaptureLoop () {
  let videoStream = null
  let audioStream = null

  const pkt   = new ffmpeg.Packet()
  const frame = new ffmpeg.Frame()

  function poll () {
    if (!_running) {
      pkt.destroy()
      frame.destroy()
      console.log('[capture] loop ended')
      return
    }

    // Init decoders on first poll once streams are available
    if (!videoStream) {
      videoStream = _captureCtx.getBestStream(ffmpeg.constants.mediaTypes.VIDEO)
      audioStream = _captureCtx.getBestStream(ffmpeg.constants.mediaTypes.AUDIO)
      if (videoStream) {
        _videoDecCtx = videoStream.decoder()
        _videoDecCtx.open()
        console.log('[capture] video decoder ready')
      }
      if (audioStream) {
        _audioPCMCtx = audioStream.decoder()
        _audioPCMCtx.open()
        _audioFifo = new ffmpeg.AudioFIFO(ffmpeg.constants.sampleFormats.FLT, AUDIO_CH, 4096)
        console.log('[capture] audio decoder ready')
      }
    }

    let got = false
    try { got = _captureCtx.readFrame(pkt) } catch (e) {
      console.error('[capture] readFrame error:', e.message)
    }

    if (got) {
      if (videoStream && pkt.streamIndex === videoStream.index) {
        _processVideo(pkt, frame)
      } else if (audioStream && pkt.streamIndex === audioStream.index) {
        _processAudio(pkt, frame)
      }
      pkt.unref()
      setImmediate(poll)
    } else {
      setTimeout(poll, 1)
    }
  }

  setImmediate(poll)
}

function _processVideo (pkt, frame) {
  if (!_videoDecCtx) return
  _videoDecCtx.sendPacket(pkt)
  while (_videoDecCtx.receiveFrame(frame)) {
    if (_videoMuted) continue

    // avfoundation delivers NV12; VP8 encoder needs YUV420P — scale once
    if (!_videoScaler) {
      _videoScaler = new ffmpeg.Scaler(
        ffmpeg.constants.pixelFormats.NV12, VIDEO_W, VIDEO_H,
        ffmpeg.constants.pixelFormats.YUV420P, VIDEO_W, VIDEO_H
      )
      console.log('[capture] video scaler ready NV12 → YUV420P')
    }

    const yuv = new ffmpeg.Frame()
    yuv.width       = VIDEO_W
    yuv.height      = VIDEO_H
    yuv.format      = ffmpeg.constants.pixelFormats.YUV420P
    yuv.alloc()

    _videoScaler.scale(frame, yuv)
    _encodeVideo.sendFrame(yuv)
    yuv.destroy()

    const enc = new ffmpeg.Packet()
    let vPkts = 0
    while (_encodeVideo.receivePacket(enc)) {
      vPkts++
      _onVideoPacket?.(Date.now(), Buffer.from(enc.data))
    }
    if (vPkts > 0 && Math.random() < 0.02) console.log('[capture] video packets sent:', vPkts, 'peers:', require('./peers').peerCount())
    enc.destroy()
  }
}

function _processAudio (pkt, frame) {
  if (!_audioPCMCtx) return
  _audioPCMCtx.sendPacket(pkt)
  while (_audioPCMCtx.receiveFrame(frame)) {
    if (_audioMuted) continue

    // Resample to flt @ 48kHz for libopus
    if (!_audioResampler) {
      const inRate   = frame.sampleRate || AUDIO_RATE
      const inFmt    = (typeof frame.format === 'number' && frame.format >= 0)
        ? frame.format
        : ffmpeg.constants.sampleFormats.FLT
      const inLayout = frame.channelLayout
        || ffmpeg.constants.toChannelLayout(
            (frame.channels || AUDIO_CH) === 1 ? 'MONO' : 'STEREO'
           )
      _audioResampler = new ffmpeg.Resampler(
        inRate,     inLayout, inFmt,
        AUDIO_RATE, ffmpeg.constants.toChannelLayout('STEREO'),
        ffmpeg.constants.sampleFormats.FLT
      )
      console.log('[capture] audio resampler ready, inFmt:', inFmt, 'inRate:', inRate)
    }

    // Resampler.convert() allocates output frame internally — no pre-alloc needed
    const resampled = new ffmpeg.Frame()
    _audioResampler.convert(frame, resampled)
    _audioFifo.write(resampled)
    resampled.destroy()

    // Feed opus encoder in fixed 960-sample chunks
    const frameSize = _encodeAudio.frameSize || 960
    while (_audioFifo.size >= frameSize) {
      const chunk = new ffmpeg.Frame()
      chunk.format        = ffmpeg.constants.sampleFormats.FLT
      chunk.channels      = AUDIO_CH
      chunk.channelLayout = ffmpeg.constants.toChannelLayout('STEREO')
      chunk.nbSamples     = frameSize
      chunk.alloc()
      _audioFifo.read(chunk, frameSize)
      _encodeAudio.sendFrame(chunk)
      chunk.destroy()

      const enc = new ffmpeg.Packet()
      while (_encodeAudio.receivePacket(enc)) {
        _onAudioPacket?.(Date.now(), Buffer.from(enc.data))
      }
      enc.destroy()
    }
  }
}

module.exports = { start, stop, setMute, onVideoPacket, onAudioPacket }
