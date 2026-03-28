'use strict'

// Raw IPC protocol — no bare-rpc framing.
// Every message: [1B command][4B data-length LE][N bytes data]
// This works reliably with BareKit IPC which preserves message boundaries.

const swarm    = require('./swarm')
const capture  = require('./capture')
const peers    = require('./peers')
const protocol = require('./protocol')

const CMD = {
  START:        1,
  STOP:         2,
  MUTE:         3,
  PEER_JOINED:  10,
  PEER_LEFT:    11,
  PEER_CONTROL: 12,
  VIDEO_FRAME:  13,
  AUDIO_FRAME:  14
}

let _ipc = null

function init (ipc) {
  _ipc = ipc

  // Listen for raw messages from Swift
  ipc.on('data', (chunk) => _onMessage(chunk))
  ipc.on('error', (e) => console.error('[rpc] ipc error:', e.message))

  peers.configure({
    onPeerJoined  (peerId)      { _send(CMD.PEER_JOINED,  Buffer.from(JSON.stringify({ peerId }))) },
    onPeerLeft    (peerId)      { _send(CMD.PEER_LEFT,    Buffer.from(JSON.stringify({ peerId }))) },
    onPeerControl (peerId, evt) { _send(CMD.PEER_CONTROL, Buffer.from(JSON.stringify({ peerId, ...evt }))) },
    onVideo (frameBuffer)       { _send(CMD.VIDEO_FRAME, frameBuffer) },
    onAudio (frameBuffer)       { _send(CMD.AUDIO_FRAME, frameBuffer) }
  })

  // Local video preview
  capture.onVideoPacket((pts, vp8) => {
    _send(CMD.VIDEO_FRAME, protocol.encodeVideoFrame('__local__', pts, vp8))
  })

  console.log('[rpc] ready')
}

// Send: [1B cmd][4B len LE][data]
function _send (command, data) {
  if (!_ipc) return
  const buf = Buffer.allocUnsafe(5 + data.length)
  buf[0] = command
  buf.writeUInt32LE(data.length, 1)
  data.copy(buf, 5)
  try { _ipc.write(buf) } catch (e) {
    console.error('[rpc] write error cmd', command, e.message)
  }
}

// Receive: parse [1B cmd][4B len LE][data]
let _recvBuf = Buffer.alloc(0)

function _onMessage (chunk) {
  _recvBuf = Buffer.concat([_recvBuf, chunk])

  while (_recvBuf.length >= 5) {
    const cmd     = _recvBuf[0]
    const dataLen = _recvBuf.readUInt32LE(1)
    if (_recvBuf.length < 5 + dataLen) break

    const data = _recvBuf.slice(5, 5 + dataLen)
    _recvBuf   = _recvBuf.slice(5 + dataLen)

    _dispatch(cmd, data)
  }
}

function _dispatch (cmd, data) {
  switch (cmd) {
    case CMD.START: return _handleStart(data)
    case CMD.STOP:  return _handleStop()
    case CMD.MUTE:  return _handleMute(data)
    default:
      console.warn('[rpc] unknown command:', cmd)
  }
}

async function _handleStart (data) {
  let topic, mode
  try {
    ;({ topic, mode } = JSON.parse(data.toString()))
  } catch {
    _sendError('invalid JSON in start payload')
    return
  }

  try { await swarm.join(topic) } catch (e) {
    console.error('[rpc] swarm.join failed:', e.message)
    _sendError(e.message)
    return
  }
  try { await capture.start() } catch (e) {
    console.error('[rpc] capture.start failed:', e.message)
    _sendError(e.message)
    return
  }

  console.log('[rpc] start complete')
  _send(CMD.START, Buffer.from(JSON.stringify({ ok: true })))
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
  try {
    const { video, audio } = JSON.parse(data.toString())
    capture.setMute(video, audio)
    peers.broadcast({ type: 'mute', video, audio })
  } catch {}
}

function _sendError (msg) {
  // Send START reply with error so Swift knows it failed
  _send(CMD.START, Buffer.from(JSON.stringify({ error: msg })))
}

module.exports = { init, CMD }
