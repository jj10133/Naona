'use strict'

const { IPC } = BareKit
const Hyperswarm = require('hyperswarm')
const Protomux   = require('protomux')
const c          = require('compact-encoding')
const b4a        = require('b4a')

let swarm  = null
let myRole = 'guest'

const peers    = new Map()
const pending  = new Map()
let ipcBuffer  = ''

IPC.on('data', (raw) => {
  ipcBuffer += raw.toString('utf8')
  const lines = ipcBuffer.split('\n')
  ipcBuffer = lines.pop()
  for (const line of lines) {
    if (!line.trim()) continue
    let msg
    try { msg = JSON.parse(line) } catch (e) { continue }
    switch (msg.type) {
      case 'call':
        myRole = msg.role === 'host' ? 'host' : 'guest'
        startSwarm(msg.topic)
        break
      case 'videoFrame':
        broadcastMedia('video', b4a.from(msg.data, 'base64'))
        break
      case 'audioFrame':
        broadcastMedia('audio', b4a.from(msg.data, 'base64'))
        break
      case 'muteState':
        broadcastControl({ type: 'mute', audio: msg.audio, video: msg.video })
        break
      case 'hangup':
        teardown()
        break
    }
  }
})

IPC.on('error', (err) => console.error('[js] IPC error:', err.message))

async function startSwarm(topicHex) {
  if (swarm) { await swarm.destroy(); swarm = null; peers.clear(); pending.clear() }

  swarm = new Hyperswarm()

  swarm.on('connection', (socket, peerInfo) => {
    const peerId  = b4a.toString(peerInfo.publicKey, 'hex')
    const shortId = peerId.slice(0, 8)

    if (myRole === 'guest' && peers.size >= 1) {
      socket.destroy()
      return
    }

    console.log('[js] connected:', shortId)

    const mux = new Protomux(socket)

    const ctrl = mux.createChannel({ protocol: 'naona/ctrl/v1',
      onopen() { sendToSwift({ type: 'peerJoined', peerId }) },
      onclose() { removePeer(peerId) }
    })
    const ctrlMsg = ctrl.addMessage({ encoding: c.json,
      onmessage(msg) { sendToSwift({ ...msg, peerId }) }
    })
    ctrl.open()

    const videoCh = mux.createChannel({ protocol: 'naona/video/v1', onopen() {}, onclose() {} })
    const videoMsg = videoCh.addMessage({ encoding: c.raw,
      onmessage(buf) {
        sendToSwift({ type: 'videoFrame', peerId, data: b4a.toString(buf, 'base64') })
      }
    })
    videoCh.open()

    const audioCh = mux.createChannel({ protocol: 'naona/audio/v1', onopen() {}, onclose() {} })
    const audioMsg = audioCh.addMessage({ encoding: c.raw,
      onmessage(buf) {
        sendToSwift({ type: 'audioFrame', peerId, data: b4a.toString(buf, 'base64') })
      }
    })
    audioCh.open()

    peers.set(peerId, { videoMsg, audioMsg, ctrlMsg })

    if (myRole === 'host') {
      const count = peers.size + 1
      for (const [, p] of peers) p.ctrlMsg.send({ type: 'participantCount', count })
      sendToSwift({ type: 'participantCount', count })
    }

    socket.on('error', (e) => console.error('[js] socket error', shortId, e.message))
    socket.on('close', () => removePeer(peerId))
  })

  const buf = b4a.from(topicHex, 'hex')
  if (buf.length !== 32) { sendToSwift({ type: 'error', message: 'bad topic' }); return }

  swarm.on('error', (e) => console.error('[js] swarm error:', e.message))

  const discovery = swarm.join(buf, { client: true, server: true })
  await discovery.flushed()
  console.log('[js] joined | role:', myRole, '| peers on DHT:', swarm.peers.size)

  setInterval(() => {
    if (peers.size === 0) {
      console.log('[js] waiting for peers | DHT peers:', swarm.peers.size)
    }
  }, 5000)
}

function broadcastMedia(track, buf) {
  for (const [, peer] of peers) {
    try {
      if (track === 'video') peer.videoMsg.send(buf)
      else                   peer.audioMsg.send(buf)
    } catch {}
  }
}

function broadcastControl(obj) {
  for (const [, peer] of peers) {
    try { peer.ctrlMsg.send(obj) } catch {}
  }
}

function removePeer(peerId) {
  if (!peers.has(peerId)) return
  peers.delete(peerId)
  console.log('[js] disconnected:', peerId.slice(0, 8), '| remaining:', peers.size)
  sendToSwift({ type: 'peerLeft', peerId })
  if (myRole === 'host') {
    const count = peers.size + 1
    for (const [, p] of peers) p.ctrlMsg.send({ type: 'participantCount', count })
    sendToSwift({ type: 'participantCount', count })
  }
}

function sendToSwift(msg) {
  try { IPC.write(Buffer.from(JSON.stringify(msg) + '\n')) } catch {}
}

async function teardown() {
  for (const [, socket] of peers) { try { socket.destroy?.() } catch {} }
  peers.clear()
  pending.clear()
  if (swarm) { await swarm.destroy(); swarm = null }
  console.log('[js] teardown')
}

Bare.on('suspend', () => console.log('[js] suspended'))
Bare.on('resume',  () => console.log('[js] resumed'))
Bare.on('exit',    () => teardown())
