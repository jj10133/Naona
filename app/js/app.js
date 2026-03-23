'use strict'

const { IPC } = BareKit
const Hyperswarm = require('hyperswarm')
const b4a = require('b4a')

// ─── State ────────────────────────────────────────────────────────────────────

let swarm = null

// Map of peerId (hex) → socket
// 1-to-1: max 1 entry, extras are rejected
// mesh:   unlimited entries
const peers = new Map()

// Buffered signaling messages keyed by peerId, queued before socket is ready
const pending = new Map()

// Mode is encoded in the topic prefix sent from Swift:
//   { type: 'call', topic: '...', mode: 'one' | 'mesh' }
let roomMode = 'one'   // default safe
let ipcBuffer = ''

// ─── IPC: Swift → JS ─────────────────────────────────────────────────────────

IPC.on('data', (raw) => {
  ipcBuffer += raw.toString('utf8')
  const lines = ipcBuffer.split('\n')
  ipcBuffer = lines.pop()

  for (const line of lines) {
    if (!line.trim()) continue
    let msg
    try { msg = JSON.parse(line) }
    catch (e) { console.error('[js] bad IPC msg:', e.message); continue }

    switch (msg.type) {
      case 'call':
        roomMode = msg.mode === 'mesh' ? 'mesh' : 'one'
        startSwarm(msg.topic)
        break

      // Signaling messages from Swift are addressed to a specific peer
      case 'offer':
      case 'answer':
      case 'candidate':
        forwardToPeer(msg.peerId, msg)
        break

      case 'hangup':
        teardown()
        break

      default:
        console.warn('[js] unknown:', msg.type)
    }
  }
})

IPC.on('error', (err) => console.error('[js] IPC error:', err.message))

// ─── Hyperswarm ───────────────────────────────────────────────────────────────

async function startSwarm (topicHex) {
  if (swarm) { await swarm.destroy(); swarm = null; peers.clear(); pending.clear() }

  swarm = new Hyperswarm()

  swarm.on('connection', (socket, peerInfo) => {
    const peerId = b4a.toString(peerInfo.publicKey, 'hex')
    const shortId = peerId.slice(0, 8)

    // ── 1-to-1: reject if room already has a peer ──────────────────────────
    if (roomMode === 'one' && peers.size >= 1) {
      console.log('[js] 1-to-1 room full, rejecting peer', shortId)
      socket.destroy()
      sendToSwift({ type: 'roomFull' })
      return
    }

    console.log('[js] peer connected:', shortId, '| mode:', roomMode)
    peers.set(peerId, socket)

    // Flush pending messages for this peer
    const queued = pending.get(peerId) || []
    pending.delete(peerId)
    for (const m of queued) writeToPeer(socket, m)

    // Tell Swift a new peer joined and whether we are the caller for this pair
    sendToSwift({ type: 'peerJoined', peerId, isCaller: peerInfo.client })

    // Per-peer line buffer for incoming signaling
    let peerBuffer = ''
    socket.on('data', (chunk) => {
      peerBuffer += chunk.toString()
      const lines = peerBuffer.split('\n')
      peerBuffer = lines.pop()
      for (const line of lines) {
        if (!line.trim()) continue
        try {
          const msg = JSON.parse(line)
          // Tag message with sender so Swift knows which peer it came from
          sendToSwift({ ...msg, peerId })
        } catch (e) {
          console.error('[js] bad peer msg from', shortId, e.message)
        }
      }
    })

    socket.on('error', (err) => {
      console.error('[js] socket error', shortId, err.message)
    })

    socket.on('close', () => {
      peers.delete(peerId)
      console.log('[js] peer disconnected:', shortId, '| remaining:', peers.size)
      sendToSwift({ type: 'peerLeft', peerId })
    })
  })

  const topicBuf = b4a.from(topicHex, 'hex')
  if (topicBuf.length !== 32) {
    sendToSwift({ type: 'error', message: 'Topic must be 32 bytes' })
    return
  }

  const discovery = swarm.join(topicBuf, { client: true, server: true })
  await discovery.flushed()
  console.log('[js] joined topic in', roomMode, 'mode, waiting for peers…')
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function forwardToPeer (peerId, msg) {
  const socket = peers.get(peerId)
  if (socket && !socket.destroyed) {
    writeToPeer(socket, msg)
  } else {
    // Buffer until socket connects
    if (!pending.has(peerId)) pending.set(peerId, [])
    pending.get(peerId).push(msg)
  }
}

function writeToPeer (socket, msg) {
  try { socket.write(JSON.stringify(msg) + '\n') }
  catch (e) { console.error('[js] writeToPeer error:', e.message) }
}

function sendToSwift (msg) {
  try { IPC.write(Buffer.from(JSON.stringify(msg) + '\n')) }
  catch (e) { console.error('[js] sendToSwift error:', e.message) }
}

async function teardown () {
  for (const [, socket] of peers) socket.destroy()
  peers.clear()
  pending.clear()
  if (swarm) { await swarm.destroy(); swarm = null }
  console.log('[js] teardown complete')
}

Bare.on('suspend', () => console.log('[js] suspended'))
Bare.on('resume',  () => console.log('[js] resumed'))
Bare.on('exit',    () => teardown())
