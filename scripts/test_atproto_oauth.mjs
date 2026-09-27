import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const [packagePath, origin, did, password] = process.argv.slice(2)
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
  const redirect = 'http://127.0.0.1:8750/callback'
  const clientId = `http://localhost?${new URLSearchParams({ redirect_uri: redirect, scope: 'atproto' })}`
  const client = new NodeOAuthClient({
    clientMetadata: {
      client_id: clientId, redirect_uris: [redirect], scope: 'atproto',
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
  response = await browser('/oauth/authorize', { _csrf_token: value(html, '_csrf_token'), view: value(html, 'view'), decision: 'approve' })
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
  stage = 'refresh'
  const info = await session.getTokenInfo(true)
  assert.equal(info.sub, did)
  assert.equal(info.scope, 'atproto')
  response = await session.fetchHandler('/xrpc/com.atproto.server.getSession')
  assert.equal(response.status, 200)
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
