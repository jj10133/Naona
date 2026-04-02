'use strict'

const { IPC } = BareKit
const Hyperswarm = require('hyperswarm')
const b4a = require('b4a')

// ─── State ────────────────────────────────────────────────────────────────────

let swarm    = null
let myRole = 'guest'   // 'host' | 'guest'

// peerId (hex) → socket
const peers = new Map()

// Buffered signaling messages, queued before socket is ready
const pending = new Map()

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
        myRole = msg.role === 'host' ? 'host' : 'guest'
        startSwarm(msg.topic)
        break

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
    const peerId  = b4a.toString(peerInfo.publicKey, 'hex')
    const shortId = peerId.slice(0, 8)

    // ── Guest: only connect to ONE peer (the host) ──────────────────────
    // Guests find multiple peers on the DHT but only talk to host.
    if (myRole === 'guest' && peers.size >= 1) {
      console.log('[js] guest: already connected to host, rejecting', shortId)
      socket.destroy()
      return
    }

    console.log('[js] connected:', shortId, '| myRole:', myRole)
    peers.set(peerId, socket)

    // Flush buffered signaling
    const queued = pending.get(peerId) || []
    pending.delete(peerId)
    for (const m of queued) writeToPeer(socket, m)

    // ── Notify Swift about the new peer ──────────────────────────────────
    if (myRole === 'host') {
      // Host always makes the WebRTC offer to each guest
      sendToSwift({ type: 'peerJoined', peerId, isCaller: true })

      // Broadcast updated participant count to all connected guests
      // so they can adapt their encoding bitrate
      const count = peers.size + 1 // +1 for host itself
      for (const [, s] of peers) {
        writeToPeer(s, { type: 'participantCount', count })
      }
      // Also tell Swift the current count so host UI updates
      sendToSwift({ type: 'participantCount', count })

    } else {
      // Guest connecting to host:
      //   - host always makes the offer (isCaller: false for guest)
      //   - for 1-to-1: whoever dialed makes the offer (peerInfo.client)
      // Guest always waits for host's offer
      sendToSwift({ type: 'peerJoined', peerId, isCaller: false })
    }

    // ── Relay data from this peer back to Swift ───────────────────────────
    let peerBuffer = ''
    socket.on('data', (chunk) => {
      peerBuffer += chunk.toString()
      const lines = peerBuffer.split('\n')
      peerBuffer = lines.pop()
      for (const line of lines) {
        if (!line.trim()) continue
        try {
          const msg = JSON.parse(line)
          sendToSwift({ ...msg, peerId })
        } catch (e) {
          console.error('[js] bad peer msg from', shortId, e.message)
        }
      }
    })

    socket.on('error', (err) => console.error('[js] socket error', shortId, err.message))

    socket.on('close', () => {
      peers.delete(peerId)
      console.log('[js] disconnected:', shortId, '| remaining:', peers.size)
      sendToSwift({ type: 'peerLeft', peerId })

      // Update participant count after someone leaves
      if (myRole === 'host') {
        const count = peers.size + 1
        for (const [, s] of peers) writeToPeer(s, { type: 'participantCount', count })
        sendToSwift({ type: 'participantCount', count })
      }
    })
  })

  const topicBuf = b4a.from(topicHex, 'hex')
  if (topicBuf.length !== 32) {
    sendToSwift({ type: 'error', message: 'Topic must be 32 bytes' })
    return
  }

  const discovery = swarm.join(topicBuf, { client: true, server: true })
  await discovery.flushed()
  console.log('[js] joined | mode:', roomMode, '| role:', myRole)
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function forwardToPeer (peerId, msg) {
  const socket = peers.get(peerId)
  if (socket && !socket.destroyed) {
    writeToPeer(socket, msg)
  } else {
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
