import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { ECDH, createPublicKey, verify } from 'node:crypto'

const [packagePath, origin, did, password, scenario = 'base', publicHex, curve] = process.argv.slice(2)
let stage = 'setup'
const deadline = setTimeout(() => { console.error(`OAuth interop timeout at ${stage}`); process.exit(1) }, 45000)
try {
  const manifest = JSON.parse(readFileSync(resolve(packagePath, 'package.json'), 'utf8'))
  assert.equal(manifest.name, '@atproto/oauth-client-node')
  assert.equal(manifest.version, '0.3.16')
  const require = createRequire(resolve(packagePath, 'package.json'))
  const { NodeOAuthClient } = require(packagePath)
  assert.equal(new URL(origin).hostname, 'localhost')
  assert.equal(new URL(origin).protocol, 'http:')
  const store = () => {
    const data = new Map()
    return { async get(k) { return data.get(k) }, async set(k, v) { data.set(k, v) }, async del(k) { data.delete(k) } }
  }
  const requests = []
  let identityResolutions = 0
  const localFetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : input)
    assert.equal(url.origin, origin, 'request escaped the test server')
    const response = await fetch(input, { ...init, redirect: 'manual', signal: AbortSignal.any([AbortSignal.timeout(5000), ...(init.signal ? [init.signal] : [])]) })
    requests.push({ path: url.pathname, status: response.status })
    return response
  }
  assert.ok(['base', 'granular', 'blobs', 'email', 'rpc'].includes(scenario))
  const collection = 'com.example.oauthrecord'
  const audience = 'did:web:appview.example.com#bsky_appview'
  const method = 'app.bsky.feed.getTimeline'
  const rpcScope = `rpc:${method}?aud=${encodeURIComponent(audience).replaceAll('%3A', ':')}`
  const grants = {
    base: ['atproto', 'atproto'],
    granular: [`atproto repo:${collection}?action=create`, `atproto repo:${collection}?action=create repo:${collection}?action=update`],
    blobs: ['atproto blob:text/plain', 'atproto blob:text/plain blob:image/png'],
    email: ['atproto account:email', 'atproto account:email account:email?action=manage'],
    rpc: [`atproto ${rpcScope}`, `atproto ${rpcScope} rpc:app.bsky.feed.getFeed?aud=*`],
  }
  const [grantedScope, requestedScope] = grants[scenario]
  const redirect = 'http://127.0.0.1:8750/callback'
  const clientId = `http://localhost?${new URLSearchParams({ redirect_uri: redirect, scope: requestedScope })}`
  const client = new NodeOAuthClient({
    clientMetadata: {
      client_id: clientId, redirect_uris: [redirect], scope: requestedScope,
      grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'],
      token_endpoint_auth_method: 'none', dpop_bound_access_tokens: true,
    },
    allowHttp: true, fetch: localFetch, stateStore: store(), sessionStore: store(),
    // This script performs operations sequentially with one SDK instance.
    requestLock: async (_name, fn) => fn(),
    // Isolate identity resolution; OAuth discovery and issuer binding remain SDK checks.
    identityResolver: { async resolve(input) {
      assert.equal(input, did)
      identityResolutions++
      return { did, handle: 'handle.invalid', didDoc: { id: did, service: [{ id: `${did}#atproto_pds`, type: 'AtprotoPersonalDataServer', serviceEndpoint: origin }] } }
    } },
  })
  stage = 'discovery and PAR'
  const authorization = await client.authorize(did, { state: 'interop-state' })
  assert.equal(authorization.origin, origin)
  const cookies = new Map()
  const browser = async (path, fields) => {
    const headers = { cookie: [...cookies].map(([k, v]) => `${k}=${v}`).join('; ') }
    if (fields) headers['content-type'] = 'application/x-www-form-urlencoded'
    const response = await localFetch(new URL(path, origin), { method: fields ? 'POST' : 'GET', headers, ...(fields ? { body: new URLSearchParams(fields) } : {}) })
    for (const cookie of response.headers.getSetCookie()) {
      const pair = cookie.split(';')[0], at = pair.indexOf('=')
      cookies.set(pair.slice(0, at), pair.slice(at + 1))
    }
    return response
  }
  const value = (html, name) => {
    const match = html.match(new RegExp(`name="${name}" value="([^"]+)"`))
    assert.ok(match, `missing ${name} form field`)
    return match[1].replaceAll('&amp;', '&').replaceAll('&#39;', "'").replaceAll('&quot;', '"')
  }
  stage = 'browser login'
  let response = await browser(authorization)
  assert.equal(response.status, 303)
  assert.equal(response.headers.get('location'), '/account/login')
  response = await browser('/account/login')
  assert.equal(response.status, 200)
  let html = await response.text()
  response = await browser('/account/login', { _csrf_token: value(html, '_csrf_token'), identifier: did, password })
  assert.equal(response.status, 303)
  assert.equal(response.headers.get('location'), '/oauth/authorize')
  stage = 'browser consent'
  response = await browser('/oauth/authorize')
  assert.equal(response.status, 200)
  html = await response.text()
  const consent = { _csrf_token: value(html, '_csrf_token'), view: value(html, 'view'), decision: 'approve' }
  if (scenario === 'granular') {
    assert.ok(html.includes(`create in ${collection}`))
    assert.ok(html.includes(`update in ${collection}`))
    // atproto is implicit; select create, deliberately leave update unchecked.
    assert.ok(html.includes('name="permission_1"'))
    assert.ok(html.includes('name="permission_2"'))
    consent.permission_1 = 'yes'
  }
  if (scenario === 'blobs') {
    assert.ok(html.includes('Upload media: text/plain'))
    assert.ok(html.includes('Upload media: image/png'))
    // Select text uploads and decline the requested PNG permission.
    consent.permission_1 = 'yes'
  }
  if (scenario === 'email') {
    assert.ok(html.includes('Read your email address and confirmation status'))
    assert.ok(html.includes('Read and change your email address'))
    consent.permission_1 = 'yes'
  }
  if (scenario === 'rpc') {
    assert.ok(html.includes(`Call application services: ${method} on ${audience}`))
    assert.ok(html.includes('app.bsky.feed.getFeed on any service'))
    consent.permission_1 = 'yes'
  }
  response = await browser('/oauth/authorize', consent)
  assert.equal(response.status, 303)
  const callback = new URL(response.headers.get('location'))
  assert.equal(callback.origin + callback.pathname, redirect)
  stage = 'code exchange'
  const { session, state } = await client.callback(callback.searchParams)
  assert.equal(state, 'interop-state')
  assert.equal(session.did, did)
  stage = 'DPoP resource'
  response = await session.fetchHandler('/xrpc/com.atproto.server.getSession')
  assert.equal(response.status, 200)
  assert.equal((await response.json()).did, did)
  assert.ok(requests.some(r => r.path === '/xrpc/com.atproto.server.getSession' && r.status === 401))
  const write = (method, body) => session.fetchHandler(`/xrpc/com.atproto.repo.${method}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  })
  const record = { $type: collection, text: 'original' }
  const create = rkey => write('createRecord', { repo: did, collection, rkey, record, validate: false })
  const denied = async promise => {
    const result = await promise
    assert.equal(result.status, 403)
    assert.equal((await result.json()).error, 'insufficient_scope')
  }
  const serviceToken = params => session.fetchHandler(`/xrpc/com.atproto.server.getServiceAuth?${new URLSearchParams(params)}`)
  const nonces = new Set()
  const checkRpcPermissions = async () => {
    const params = { aud: audience, lxm: method }
    if (scenario !== 'rpc') {
      await denied(serviceToken(params))
      return
    }
    const result = await serviceToken(params)
    assert.equal(result.status, 200)
    const { token } = await result.json()
    const parts = token.split('.')
    assert.equal(parts.length, 3)
    const header = JSON.parse(Buffer.from(parts[0], 'base64url'))
    const claims = JSON.parse(Buffer.from(parts[1], 'base64url'))
    assert.ok(['k256', 'p256'].includes(curve))
    assert.deepEqual(header, { typ: 'JWT', alg: curve === 'k256' ? 'ES256K' : 'ES256' })
    const publicBytes = ECDH.convertKey(Buffer.from(publicHex, 'hex'), curve === 'k256' ? 'secp256k1' : 'prime256v1', undefined, undefined, 'uncompressed')
    const key = createPublicKey({ format: 'jwk', key: {
      kty: 'EC', crv: curve === 'k256' ? 'secp256k1' : 'P-256',
      x: publicBytes.subarray(1, 33).toString('base64url'), y: publicBytes.subarray(33).toString('base64url'),
    } })
    assert.ok(verify('sha256', Buffer.from(`${parts[0]}.${parts[1]}`), { key, dsaEncoding: 'ieee-p1363' }, Buffer.from(parts[2], 'base64url')))
    assert.equal(claims.iss, did)
    assert.equal(claims.aud, audience)
    assert.equal(claims.lxm, method)
    assert.equal(claims.exp - claims.iat, 60)
    assert.ok(claims.exp > Date.now() / 1000)
    assert.match(claims.jti, /^[a-f0-9]{32}$/)
    assert.ok(!nonces.has(claims.jti))
    nonces.add(claims.jti)
    for (const changed of [
      { aud: audience },
      { ...params, lxm: 'app.bsky.feed.getFeed' },
      { ...params, aud: 'did:web:appview.example.com#other' },
      { ...params, aud: 'did:web:appview.example.com' },
      { ...params, aud: 'did:web:other.example.com#bsky_appview' },
    ]) await denied(serviceToken(changed))
  }
  stage = 'RPC audience and method permissions'
  await checkRpcPermissions()
  const checkEmailPrivacy = async () => {
    const result = await session.fetchHandler('/xrpc/com.atproto.server.getSession')
    assert.equal(result.status, 200)
    const account = await result.json()
    if (scenario === 'email') {
      assert.equal(account.email, 'oauth-interop@example.com')
      assert.equal(account.emailConfirmed, true)
    } else {
      assert.ok(!Object.hasOwn(account, 'email'))
      assert.ok(!Object.hasOwn(account, 'emailConfirmed'))
    }
    assert.ok(!Object.hasOwn(account, 'emailAuthFactor'))
    for (const [method, body] of [
      ['requestEmailUpdate', {}],
      ['updateEmail', { email: 'unapproved@example.com', token: 'unapproved-code' }],
      ['requestEmailConfirmation', {}],
      ['confirmEmail', { email: 'oauth-interop@example.com', token: 'unapproved-code' }],
    ]) {
      await denied(session.fetchHandler(`/xrpc/com.atproto.server.${method}`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
      }))
    }
  }
  stage = 'account email read and management restrictions'
  assert.equal((await session.getTokenInfo()).scope, grantedScope)
  await checkEmailPrivacy()
  const checkRestrictions = async () => {
    await denied(write('putRecord', { repo: did, collection, rkey: 'first', record: { ...record, text: 'forbidden update' }, validate: false }))
    await denied(write('deleteRecord', { repo: did, collection, rkey: 'first' }))
    await denied(write('createRecord', { repo: did, collection: 'com.example.other', rkey: 'denied', record: { $type: 'com.example.other' }, validate: false }))
    await denied(write('applyWrites', { repo: did, validate: false, writes: [
      { $type: 'com.atproto.repo.applyWrites#create', collection, rkey: 'partial', value: record },
      { $type: 'com.atproto.repo.applyWrites#delete', collection, rkey: 'first' },
    ] }))
    const saved = await session.fetchHandler(`/xrpc/com.atproto.repo.getRecord?${new URLSearchParams({ repo: did, collection, rkey: 'first' })}`)
    assert.equal(saved.status, 200)
    assert.deepEqual((await saved.json()).value, record)
  }
  const upload = (mime, body) => session.fetchHandler('/xrpc/com.atproto.repo.uploadBlob', {
    method: 'POST', headers: { 'content-type': mime }, body,
  })
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK1sAAAAASUVORK5CYII=', 'base64')
  const checkBlobPermissions = async suffix => {
    const body = `allowed OAuth text ${suffix}`
    const uploaded = await upload('text/plain', body)
    assert.equal(uploaded.status, 200)
    const { blob } = await uploaded.json()
    assert.equal(blob.$type, 'blob')
    assert.equal(blob.mimeType, 'text/plain')
    assert.equal(blob.size, Buffer.byteLength(body))
    assert.match(blob.ref.$link, /^b[a-z2-7]+$/)
    await denied(upload('image/png', png))
    // A permitted declaration must not bypass checks on sniffed media bytes.
    await denied(upload('text/plain', png))
    await denied(upload('application/json', '{"not":"granted"}'))
    await denied(create('blob-grant-cannot-write'))
  }
  if (scenario === 'blobs') {
    stage = 'granular blob upload and MIME restrictions'
    assert.equal((await session.getTokenInfo()).scope, grantedScope)
    await checkBlobPermissions('before refresh')
  }
  if (scenario === 'granular') {
    stage = 'granular writes and consent narrowing'
    assert.equal((await session.getTokenInfo()).scope, grantedScope)
    assert.equal((await create('first')).status, 200)
    await checkRestrictions()
  } else {
    await denied(create('base-denied'))
    if (scenario === 'base') await denied(upload('text/plain', 'base grant upload'))
  }
  stage = 'refresh'
  const info = await session.getTokenInfo(true)
  assert.equal(info.sub, did)
  assert.equal(info.scope, grantedScope)
  response = await session.fetchHandler('/xrpc/com.atproto.server.getSession')
  assert.equal(response.status, 200)
  if (scenario === 'granular') {
    stage = 'granular permissions after refresh'
    assert.equal((await create('second')).status, 200)
    await checkRestrictions()
  }
  if (scenario === 'blobs') {
    stage = 'blob permissions after refresh'
    await checkBlobPermissions('after refresh')
  }
  stage = 'account email permissions after refresh'
  await checkEmailPrivacy()
  stage = 'RPC permissions after refresh'
  await checkRpcPermissions()
  stage = 'source session logout'
  response = await browser('/account/sessions')
  html = await response.text()
  response = await browser('/account/logout', { _csrf_token: value(html, '_csrf_token') })
  assert.equal(response.status, 303)
  response = scenario === 'rpc' ? await serviceToken({ aud: audience, lxm: method }) : await session.fetchHandler('/xrpc/com.atproto.server.getSession')
  assert.equal(response.status, 401)
  for (const path of ['/.well-known/oauth-protected-resource', '/.well-known/oauth-authorization-server']) {
    assert.ok(requests.some(r => r.path === path && r.status === 200))
  }
  assert.ok(requests.some(r => r.path === '/oauth/par' && r.status === 400))
  assert.ok(requests.some(r => r.path === '/oauth/par' && r.status === 201))
  assert.ok(requests.filter(r => r.path === '/oauth/token' && r.status === 200).length >= 2)
  assert.ok(identityResolutions >= 2, 'SDK must recheck identity after authorization')
  console.log('Official ATProto OAuth client flow passed')
} catch (error) {
  // SDK errors may include tokens, assertions or complete request parameters.
  console.error(`OAuth interop failed at ${stage}: ${error?.name ?? 'Error'}`)
  process.exitCode = 1
} finally { clearTimeout(deadline) }
