'use strict'

// Per-peer media streaming via Protomux.
// Each peer connection gets 3 channels:
//   naona/control/v1  — handshake (peerId exchange), mute events
//   naona/video/v1    — raw H264 packets (compact-encoding binary)
//   naona/audio/v1    — raw Opus packets (compact-encoding binary)
//
// No Hypercore. No Corestore. Packets go directly peer-to-peer.
// Sender pushes encoded packets into all peer video/audio channels.
// Receiver gets packets and sends them to Swift via RPC events.

const Protomux = require('protomux')
const c        = require('compact-encoding')
const b4a      = require('b4a')
const capture  = require('./capture')
const protocol = require('./protocol')

// ─── State ────────────────────────────────────────────────────────────────────

// peerId → { videoMsg, audioMsg, controlMsg, socket }
const _peers = new Map()

// Callbacks injected by rpc.js
let _onPeerJoined  = null
let _onPeerLeft    = null
let _onPeerControl = null
let _onVideo       = null   // (frameBuffer) called with encoded IPC frame
let _onAudio       = null

// ─── Public API ───────────────────────────────────────────────────────────────

function configure (callbacks) {
  _onPeerJoined  = callbacks.onPeerJoined
  _onPeerLeft    = callbacks.onPeerLeft
  _onPeerControl = callbacks.onPeerControl
  _onVideo       = callbacks.onVideo
  _onAudio       = callbacks.onAudio

  // Wire capture output → broadcast to all peers
  capture.onVideoPacket((pts, h264) => {
    _broadcastVideo(pts, h264)
  })
  capture.onAudioPacket((pts, opus) => {
    _broadcastAudio(pts, opus)
  })
}

function handleConnection (socket, peerInfo, myPeerId) {
  const peerId  = b4a.toString(peerInfo.publicKey, 'hex')
  const shortId = peerId.slice(0, 8)

  if (_peers.has(peerId)) {
    console.log('[peers] duplicate, ignoring:', shortId)
    return
  }

  console.log('[peers] connected:', shortId)

  const mux = new Protomux(socket)

  // ── Control channel ────────────────────────────────────────────────────────
  const ctrl = mux.createChannel({
    protocol: 'naona/control/v1',
    onopen () {
      helloMsg.send({ peerId: myPeerId })
    },
    onclose () {
      _removePeer(peerId)
    }
  })

  const helloMsg = ctrl.addMessage({
    encoding: c.json,
    onmessage (info) {
      console.log('[peers] hello from:', shortId)
      _onPeerJoined?.(peerId)
    }
  })

  const muteMsg = ctrl.addMessage({
    encoding: c.json,
    onmessage (evt) {
      _onPeerControl?.(peerId, evt)
    }
  })

  ctrl.open()

  // ── Video channel ──────────────────────────────────────────────────────────
  // Each message is a raw H264 packet.
  // compact-encoding 'raw' = pass Buffer as-is (no extra framing).
  const videoCh = mux.createChannel({
    protocol: 'naona/video/v1',
    onopen () { console.log('[peers] video channel open with:', shortId) },
    onclose () {}
  })

  let _videoRxCount = 0
  const videoMsg = videoCh.addMessage({
    encoding: c.raw,
    onmessage (buf) {
      _videoRxCount++
      if (_videoRxCount === 1 || _videoRxCount % 150 === 0) {
        console.log('[peers] video rx from', shortId, 'count:', _videoRxCount, 'size:', buf.length)
      }
      const pts  = buf.readUInt32LE(0)
      const data = buf.slice(4)
      const frame = protocol.encodeVideoFrame(peerId, pts, data)
      _onVideo?.(frame)
    }
  })

  videoCh.open()

  // ── Audio channel ──────────────────────────────────────────────────────────
  const audioCh = mux.createChannel({
    protocol: 'naona/audio/v1',
    onopen () { console.log('[peers] audio channel open with:', shortId) },
    onclose () {}
  })

  const audioMsg = audioCh.addMessage({
    encoding: c.raw,
    onmessage (buf) {
      const pts  = buf.readUInt32LE(0)
      const data = buf.slice(4)
      const frame = protocol.encodeAudioFrame(peerId, pts, data)
      _onAudio?.(frame)
    }
  })

  audioCh.open()

  _peers.set(peerId, { videoMsg, audioMsg, muteMsg, socket })

  socket.on('error', (e) => console.error('[peers] socket error', shortId, e.message))
  socket.on('close', () => _removePeer(peerId))
}

function broadcast (obj) {
  for (const [, peer] of _peers) {
    try { peer.muteMsg.send(obj) } catch {}
  }
}

function removeAll () {
  for (const id of [..._peers.keys()]) _removePeer(id)
}

// ─── Private ──────────────────────────────────────────────────────────────────

function _broadcastVideo (pts, h264) {
  if (_peers.size === 0) return
  // Pack: [4B pts LE][H264 data]
  const buf = Buffer.allocUnsafe(4 + h264.length)
  buf.writeUInt32LE(pts, 0)
  h264.copy(buf, 4)
  for (const [, peer] of _peers) {
    try { peer.videoMsg.send(buf) } catch {}
  }
}

function _broadcastAudio (pts, opus) {
  if (_peers.size === 0) return
  const buf = Buffer.allocUnsafe(4 + opus.length)
  buf.writeUInt32LE(pts, 0)
  opus.copy(buf, 4)
  for (const [, peer] of _peers) {
    try { peer.audioMsg.send(buf) } catch {}
  }
}

function _removePeer (peerId) {
  if (!_peers.has(peerId)) return
  _peers.delete(peerId)
  _onPeerLeft?.(peerId)
  console.log('[peers] removed:', peerId.slice(0, 8), '| remaining:', _peers.size)
}

function peerCount () { return _peers.size }
module.exports = { configure, handleConnection, broadcast, removeAll, peerCount }
