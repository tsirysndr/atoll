import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { resolve } from 'node:path'

// Uses an existing installation; never installs packages or contacts a public PDS.
const [apiPath, repoPath, service, did, password, signingKey, streamPath, initialCursor] = process.argv.slice(2)
const load = (directory, name, version) => {
  const require = createRequire(resolve(directory, 'package.json'))
  const pkg = require('./package.json')
  assert.equal(pkg.name, name)
  assert.equal(pkg.version, version, `Expected ${name}@${version}`)
  return require(directory)
}
const { AtpAgent, ComAtprotoSyncSubscribeRepos } = load(apiPath, '@atproto/api', '0.13.35')
const { verifyRepoCar, verifyRecords, verifyProofs, verifyDiffCar, MemoryBlockstore, Repo } = load(repoPath, '@atproto/repo', '0.8.10')
const { Subscription } = load(streamPath, '@atproto/xrpc-server', '0.7.19')
const origin = new URL(service)
assert.equal(origin.protocol, 'http:')
assert.equal(origin.hostname, '127.0.0.1')
assert.equal(origin.username, '')
assert.equal(origin.password, '')
const localFetch = (input, init) => {
  const target = new URL(typeof input === 'string' || input instanceof URL ? input : input.url)
  assert.equal(target.origin, origin.origin, 'Client must stay on the disposable local server')
  return fetch(input, { ...init, redirect: 'error', signal: AbortSignal.timeout(5_000) })
}
const agent = new AtpAgent({ service, fetch: localFetch })
const anon = new AtpAgent({ service, fetch: localFetch })
const streams = []
const subscribe = cursor => {
  const abort = new AbortController()
  const iterator = new Subscription({
    service: origin.origin.replace('http:', 'ws:'),
    method: 'com.atproto.sync.subscribeRepos',
    getParams: () => ({ cursor }),
    signal: AbortSignal.any([abort.signal, AbortSignal.timeout(10_000)]),
    followRedirects: false,
    handshakeTimeout: 5_000,
    maxPayload: 3_000_000,
    onReconnectError: () => abort.abort(new Error('Unexpected reconnect')),
    validate: message => {
      assert.equal(ComAtprotoSyncSubscribeRepos.validateCommit(message).success, true)
      return message
    },
  })[Symbol.asyncIterator]()
  const close = async () => {
    abort.abort()
    await iterator.return()
  }
  streams.push(close)
  return { iterator, close }
}
let stage = 'login'
const deadline = setTimeout(() => {
  console.error(`ATProto interoperability timed out during ${stage}`)
  process.exit(1)
}, 45_000)
deadline.unref()

try {
  await agent.login({ identifier: did, password })
  assert.equal(agent.session.did, did)
  assert.equal((await agent.com.atproto.server.getSession()).data.did, did)
  const baseline = await verifyRepoCar((await anon.com.atproto.sync.getRepo({ did })).data, did, signingKey)
  const mirrorStore = new MemoryBlockstore()
  await mirrorStore.applyCommit(baseline.commit)
  let mirror = await Repo.load(mirrorStore)
  let sequence = Number(initialCursor)
  assert.ok(Number.isSafeInteger(sequence) && sequence >= 0)
  const consume = async (pending, actions) => {
    stage = `firehose ${actions.join('/')} event metadata`
    const { value: event, done } = await pending
    assert.equal(done, false)
    assert.equal(event.repo, did)
    assert.ok(Number.isSafeInteger(event.seq) && event.seq > sequence)
    assert.equal(event.since, mirror.commit.rev)
    assert.equal(event.prevData.toString(), mirror.commit.data.toString())
    assert.equal(event.tooBig, false)
    assert.equal(event.rebase, false)
    assert.deepEqual(event.ops.map(op => op.action).sort(), [...actions].sort())
    stage = `firehose ${actions.join('/')} signed CAR verification`
    const diff = await verifyDiffCar(mirror, event.blocks, did, signingKey)
    assert.equal(diff.commit.cid.toString(), event.commit.toString())
    assert.equal(diff.commit.rev, event.rev)
    assert.deepEqual(
      diff.writes.map(op => {
        const cid = op.action === 'delete' ? '' : op.cid.toString()
        const prev = op.action === 'delete' ? op.cid.toString() : op.prev?.toString() ?? ''
        return `${op.action}:${op.collection}/${op.rkey}:${cid}:${prev}`
      }).sort(),
      event.ops.map(op => `${op.action}:${op.path}:${op.cid?.toString() ?? ''}:${op.prev?.toString() ?? ''}`).sort(),
    )
    mirror = await mirror.applyCommit(diff.commit)
    sequence = event.seq
    return event
  }

  stage = 'createRecord'
  const collection = 'app.bsky.feed.post'
  const record = { $type: collection, text: 'upstream client', createdAt: '2026-09-27T00:00:00.000Z' }
  const first = await agent.com.atproto.repo.createRecord({ repo: did, collection, record })
  const firstKey = first.data.uri.split('/').at(-1)
  const secondKey = '3m22222222222'
  assert.equal(first.data.uri, `at://${did}/${collection}/${firstKey}`)
  const changed = { ...record, text: 'updated upstream client' }
  stage = 'putRecord'
  const updated = await agent.com.atproto.repo.putRecord({
    repo: did, collection, rkey: firstKey, record: changed, swapRecord: first.data.cid,
  })
  assert.notEqual(updated.data.cid, first.data.cid)
  stage = 'stale putRecord'
  await assert.rejects(
    agent.com.atproto.repo.putRecord({ repo: did, collection, rkey: firstKey, record, swapRecord: first.data.cid }),
    error => error.error === 'InvalidSwap',
  )
  stage = 'getRecord'
  const read = await anon.com.atproto.repo.getRecord({ repo: did, collection, rkey: firstKey })
  assert.equal(read.data.cid, updated.data.cid)
  assert.deepEqual(read.data.value, changed)

  stage = 'read-after-write timeline'
  const timeline = (await agent.app.bsky.feed.getTimeline()).data
  const uris = timeline.feed.map(item => item.post.uri)
  assert.ok(uris.includes(`at://${did}/${collection}/${firstKey}`))
  const newest = timeline.feed[0].post
  assert.equal(newest.author.did, did)
  assert.equal(newest.likeCount, 0)
  assert.equal(newest.record.text, 'updated upstream client')
  stage = 'read-after-write own thread'
  const thread = (await agent.app.bsky.feed.getPostThread({ uri: newest.uri })).data.thread
  assert.equal(thread.post.uri, newest.uri)

  stage = 'putPreferences'
  const preferences = [
    { $type: 'app.bsky.actor.defs#adultContentPref', enabled: true },
    { $type: 'app.bsky.actor.defs#personalDetailsPref', birthDate: '1990-01-01T00:00:00.000Z' },
  ]
  await agent.app.bsky.actor.putPreferences({ preferences })
  stage = 'getPreferences'
  const prefs = (await agent.app.bsky.actor.getPreferences()).data.preferences
  assert.deepEqual(prefs.filter(p => p.$type !== 'app.bsky.actor.defs#declaredAgePref'), preferences)
  assert.deepEqual(prefs.find(p => p.$type === 'app.bsky.actor.defs#declaredAgePref'), {
    $type: 'app.bsky.actor.defs#declaredAgePref',
    isOverAge13: true, isOverAge16: true, isOverAge18: true,
  })
  stage = 'anonymous getPreferences'
  await assert.rejects(anon.app.bsky.actor.getPreferences(), error => error.status === 401)

  stage = 'blob upload and publication'
  const bytes = new TextEncoder().encode('upstream blob round trip')
  const upload = await agent.com.atproto.repo.uploadBlob(bytes, { encoding: 'text/plain' })
  stage = 'uploaded blob size'
  assert.equal(upload.data.blob.size, bytes.length)
  const attachment = {
    $type: 'com.example.attachment',
    blob: upload.data.blob.toJSON(),
  }
  stage = 'applyWrites with a blob'
  await agent.com.atproto.repo.applyWrites({
    repo: did, validate: false,
    writes: [
      { $type: 'com.atproto.repo.applyWrites#create', collection: 'com.example.attachment', rkey: 'blob', value: attachment },
      { $type: 'com.atproto.repo.applyWrites#create', collection, rkey: secondKey, value: record },
    ],
  })
  stage = 'getBlob round trip'
  const downloaded = await anon.com.atproto.sync.getBlob({ did, cid: upload.data.blob.ref.toString() })
  // This client version decodes text/plain responses as strings despite its binary return type.
  const downloadedBytes = typeof downloaded.data === 'string'
    ? new TextEncoder().encode(downloaded.data)
    : new Uint8Array(downloaded.data)
  assert.deepEqual(downloadedBytes, bytes)
  stage = 'listRecords pagination'
  const listed = await anon.com.atproto.repo.listRecords({ repo: did, collection, limit: 1 })
  assert.equal(listed.data.records.length, 1)
  assert.ok(listed.data.cursor)
  const next = await anon.com.atproto.repo.listRecords({ repo: did, collection, limit: 1, cursor: listed.data.cursor })
  assert.equal(next.data.records.length, 1)
  assert.notEqual(next.data.records[0].uri, listed.data.records[0].uri)

  stage = 'upstream signed CAR and proof verification'
  const exported = await anon.com.atproto.sync.getRepo({ did })
  const verified = await verifyRepoCar(exported.data, did, signingKey)
  assert.deepEqual(verified.creates.map(x => `${x.collection}/${x.rkey}`).sort(),
    [`${collection}/${firstKey}`, `${collection}/${secondKey}`, 'com.example.attachment/blob'].sort())
  const latest = await anon.com.atproto.sync.getLatestCommit({ did })
  assert.equal(verified.commit.cid.toString(), latest.data.cid)
  const proof = await anon.com.atproto.sync.getRecord({ did, collection, rkey: firstKey })
  const records = await verifyRecords(proof.data, did, signingKey)
  assert.ok(records.some(x => x.collection === collection && x.rkey === firstKey && x.record?.text === changed.text))
  await agent.com.atproto.repo.deleteRecord({ repo: did, collection, rkey: secondKey })
  const after = await verifyRepoCar((await anon.com.atproto.sync.getRepo({ did })).data, did, signingKey)
  assert.deepEqual(after.creates.map(x => `${x.collection}/${x.rkey}`).sort(),
    [`${collection}/${firstKey}`, 'com.example.attachment/blob'].sort())
  const absence = await anon.com.atproto.sync.getRecord({ did, collection, rkey: secondKey })
  const absent = await verifyProofs(absence.data, [{ collection, rkey: secondKey, cid: null }], did, signingKey)
  assert.equal(absent.verified.length, 1)
  assert.equal(absent.unverified.length, 0)

  stage = 'upstream firehose replay and compact CAR application'
  const replay = subscribe(sequence)
  for (const actions of [['create'], ['update'], ['create', 'create'], ['delete']]) {
    await consume(replay.iterator.next(), actions)
  }
  assert.equal(mirror.cid.toString(), after.commit.cid.toString())
  assert.deepEqual(await mirror.getRecord(collection, firstKey), changed)
  assert.equal(await mirror.getRecord(collection, secondKey), null)

  stage = 'live firehose delivery'
  const pendingLive = replay.iterator.next()
  // Keep a rejected pending read handled if the concurrent HTTP mutation fails first.
  pendingLive.catch(() => {})
  const live = await agent.com.atproto.repo.createRecord({ repo: did, collection, record })
  const liveEvent = await consume(pendingLive, ['create'])
  assert.equal(liveEvent.commit.toString(), live.data.commit.cid)
  await replay.close()

  stage = 'exclusive firehose cursor resumption'
  const resumed = subscribe(sequence)
  const pendingResume = resumed.iterator.next()
  pendingResume.catch(() => {})
  await agent.com.atproto.repo.deleteRecord({ repo: did, collection, rkey: live.data.uri.split('/').at(-1) })
  await consume(pendingResume, ['delete'])
  assert.equal(mirror.cid.toString(), (await anon.com.atproto.sync.getLatestCommit({ did })).data.cid)
  await resumed.close()

  stage = 'firehose error frame decoding'
  const future = subscribe(Number.MAX_SAFE_INTEGER)
  await assert.rejects(future.iterator.next(), error => error.error === 'FutureCursor')
  await future.close()

  stage = 'session refresh and revocation'
  const oldRefresh = agent.session.refreshJwt
  const refreshed = await agent.com.atproto.server.refreshSession(undefined, {
    headers: { authorization: `Bearer ${oldRefresh}` },
  })
  assert.notEqual(refreshed.data.refreshJwt, oldRefresh)
  await agent.com.atproto.server.deleteSession(undefined, {
    headers: { authorization: `Bearer ${refreshed.data.refreshJwt}` },
  })
  await assert.rejects(agent.com.atproto.server.getSession(), error => error.status === 401)
  console.log('Official ATProto client and signed repository verification passed')
} catch (error) {
  // Do not print request options, session tokens, or passwords on failures.
  console.error(`ATProto interoperability failed during ${stage}: ${error.name}; code=${error.error ?? error.code ?? 'assertion'}`)
  process.exitCode = 1
} finally {
  for (const close of streams) await close().catch(() => {})
  clearTimeout(deadline)
}
