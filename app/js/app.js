'use strict'

const rpc     = require('./rpc')
const capture = require('./capture')
const swarm   = require('./swarm')
const peers   = require('./peers')

rpc.init(BareKit.IPC)

Bare.on('suspend', () => console.log('[app] suspended'))
Bare.on('resume',  () => console.log('[app] resumed'))
Bare.on('exit', async () => {
  try { capture.stop()      } catch {}
  try { peers.removeAll()   } catch {}
  try { await swarm.leave() } catch {}
})
