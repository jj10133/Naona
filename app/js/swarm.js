'use strict'

const Hyperswarm = require('hyperswarm')
const b4a        = require('b4a')
const peers      = require('./peers')

let _swarm   = null
let _myPeerId = null

async function join (topicHex) {
  if (_swarm) throw new Error('[swarm] already joined')

  _swarm = new Hyperswarm()
  _myPeerId = b4a.toString(_swarm.keyPair.publicKey, 'hex')

  console.log('[swarm] my peer id:', _myPeerId.slice(0, 8))

  _swarm.on('connection', (socket, peerInfo) => {
    const peerId = b4a.toString(peerInfo.publicKey, 'hex').slice(0, 8)
    console.log('[swarm] connection from:', peerId, '| initiator:', peerInfo.client)
    peers.handleConnection(socket, peerInfo, _myPeerId)
  })

  _swarm.on('update', () => {
    console.log('[swarm] peers in topic:', _swarm.connections.size)
  })

  const topicBuf = b4a.from(topicHex, 'hex')
  if (topicBuf.length !== 32) throw new Error('topic must be 32 bytes')

  const discovery = _swarm.join(topicBuf, { client: true, server: true })
  await discovery.flushed()
  console.log('[swarm] joined:', topicHex.slice(0, 8))
}

async function leave () {
  if (!_swarm) return
  try { await _swarm.destroy() } catch (e) {
    console.error('[swarm] destroy error:', e.message)
  }
  _swarm    = null
  _myPeerId = null
  console.log('[swarm] left')
}

module.exports = { join, leave }
