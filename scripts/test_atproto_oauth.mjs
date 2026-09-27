import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const [packagePath, origin, did, password, scenario = 'base'] = process.argv.slice(2)
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
  assert.ok(['base', 'granular'].includes(scenario))
  const collection = 'com.example.oauthrecord'
  const grantedScope = scenario === 'granular' ? `atproto repo:${collection}?action=create` : 'atproto'
  const requestedScope = scenario === 'granular' ? `${grantedScope} repo:${collection}?action=update` : 'atproto'
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
  if (scenario === 'granular') {
    stage = 'granular writes and consent narrowing'
    assert.equal((await session.getTokenInfo()).scope, grantedScope)
    assert.equal((await create('first')).status, 200)
    await checkRestrictions()
  } else {
    await denied(create('base-denied'))
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
  stage = 'source session logout'
  response = await browser('/account/sessions')
  html = await response.text()
  response = await browser('/account/logout', { _csrf_token: value(html, '_csrf_token') })
  assert.equal(response.status, 303)
  response = await session.fetchHandler('/xrpc/com.atproto.server.getSession')
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
