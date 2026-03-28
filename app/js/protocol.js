//
//  protocol.js
//  App
//
//  Created by Janardhan on 2026-03-28.
//


'use strict'

// Binary frame encoding for media sent from JS → Swift over IPC.
//
// Video frame:
//   [1B: type=0x01]
//   [4B: peerId length]
//   [N:  peerId utf8]
//   [4B: pts ms LE]
//   [4B: packet data length]
//   [N:  raw H264 packet data]
//
// Audio frame:
//   [1B: type=0x02]
//   [4B: peerId length]
//   [N:  peerId utf8]
//   [4B: pts ms LE]
//   [4B: packet data length]
//   [N:  raw Opus packet data]
//
// Both directions use the same layout.

const VIDEO_FRAME = 0x01
const AUDIO_FRAME = 0x02

function encodeFrame (type, peerId, pts, data) {
  const peerBuf = Buffer.from(peerId)
  const header  = Buffer.allocUnsafe(1 + 4 + peerBuf.length + 4 + 4)
  let off = 0
  header[off++] = type
  header.writeUInt32LE(peerBuf.length, off); off += 4
  peerBuf.copy(header, off); off += peerBuf.length
  header.writeUInt32LE(pts,         off); off += 4
  header.writeUInt32LE(data.length, off); off += 4
  return Buffer.concat([header, data])
}

function encodeVideoFrame (peerId, pts, h264Data) {
  return encodeFrame(VIDEO_FRAME, peerId, pts, h264Data)
}

function encodeAudioFrame (peerId, pts, opusData) {
  return encodeFrame(AUDIO_FRAME, peerId, pts, opusData)
}

// Parse a binary frame buffer (called on Swift side by RPCBridge)
// Returns null if buffer is incomplete or malformed
function decodeFrame (buf) {
  if (buf.length < 13) return null
  let off = 0
  const type      = buf[off++]
  const peerIdLen = buf.readUInt32LE(off); off += 4
  if (buf.length < off + peerIdLen + 8) return null
  const peerId    = buf.slice(off, off + peerIdLen).toString('utf8'); off += peerIdLen
  const pts       = buf.readUInt32LE(off); off += 4
  const dataLen   = buf.readUInt32LE(off); off += 4
  if (buf.length < off + dataLen) return null
  const data      = buf.slice(off, off + dataLen)
  return { type, peerId, pts, data }
}

module.exports = { encodeVideoFrame, encodeAudioFrame, decodeFrame, VIDEO_FRAME, AUDIO_FRAME }