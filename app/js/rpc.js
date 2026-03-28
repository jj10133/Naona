'use strict'

const RPC      = require('bare-rpc')
const swarm    = require('./swarm')
const capture  = require('./capture')
const peers    = require('./peers')
const protocol = require('./protocol')

// Command numbers — must match RPCBridge.swift RPCCommand
const CMD = {
  START:        1,   // Swift → JS request
  STOP:         2,   // Swift → JS event
  MUTE:         3,   // Swift → JS event
  PEER_JOINED:  10,  // JS → Swift event
  PEER_LEFT:    11,
  PEER_CONTROL: 12,
  VIDEO_FRAME:  13,
  AUDIO_FRAME:  14
}

let _rpc = null

function init (ipc) {
  const stream = _wrapIPC(ipc)

  _rpc = new RPC(stream, (req) => {
    switch (req.command) {
      case CMD.START: return _handleStart(req)
      case CMD.STOP:
        _handleStop()
        if (typeof req.reply === 'function') req.reply(null)
        return
      case CMD.MUTE:
        _handleMute(req.data)
        if (typeof req.reply === 'function') req.reply(null)
        return
      default:
        throw new Error(`Unknown command: ${req.command}`)
    }
  })

  peers.configure({
    onPeerJoined (peerId) {
      _jsonEvent(CMD.PEER_JOINED, { peerId })
    },
    onPeerLeft (peerId) {
      _jsonEvent(CMD.PEER_LEFT, { peerId })
    },
    onPeerControl (peerId, evt) {
      _jsonEvent(CMD.PEER_CONTROL, { peerId, ...evt })
    },
    onVideo (frameBuffer) {
      _rpc?.event(CMD.VIDEO_FRAME, frameBuffer)
    },
    onAudio (frameBuffer) {
      _rpc?.event(CMD.AUDIO_FRAME, frameBuffer)
    }
  })

  // Send local video preview back to Swift using reserved peerId '__local__'
  // so the UI can show the local camera feed
  capture.onVideoPacket((pts, h264) => {
    const localFrame = protocol.encodeVideoFrame('__local__', pts, h264)
    _rpc?.event(CMD.VIDEO_FRAME, localFrame)
  })

  console.log('[rpc] ready')
}

async function _handleStart (req) {
  let topic, mode
  try {
    ;({ topic, mode } = JSON.parse(req.data.toString()))
  } catch {
    throw new Error('invalid JSON in start payload')
  }

  try {
    await swarm.join(topic)
  } catch (e) {
    console.error('[rpc] swarm.join failed:', e.message)
    throw e
  }

  try {
    await capture.start()
  } catch (e) {
    console.error('[rpc] capture.start failed:', e.message)
    throw e
  }

  console.log('[rpc] start complete')
  req.reply(Buffer.from(JSON.stringify({ ok: true })))
}

function _handleStop () {
  ;(async () => {
    try { capture.stop()      } catch {}
    try { peers.removeAll()   } catch {}
    try { await swarm.leave() } catch {}
    console.log('[rpc] stopped')
  })()
}

function _handleMute (data) {
  if (!data) return
  try {
    const { video, audio } = JSON.parse(data.toString())
    capture.setMute(video, audio)
    peers.broadcast({ type: 'mute', video, audio })
  } catch {}
}

function _jsonEvent (command, obj) {
  _rpc?.event(command, Buffer.from(JSON.stringify(obj)))
}

function _wrapIPC (ipc) {
  const handlers = {}
  const stream = {
    on (event, fn) { handlers[event] = fn; return this },
    write (data) {
      try { ipc.write(data); return true }
      catch (e) { console.error('[rpc] ipc write error:', e.message); return false }
    }
  }
  ipc.on('data',  (chunk) => handlers['data']?.(chunk))
  ipc.on('error', (err)   => console.error('[rpc] ipc error:', err.message))
  return stream
}

module.exports = { init, CMD }
