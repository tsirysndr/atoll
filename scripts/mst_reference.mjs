// Offline reference checks using an already-installed @atproto/repo. Installs nothing.
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { resolve, join } from 'node:path'

const [mode, packageDirectory, filename] = process.argv.slice(2)
if (!['generate', 'verify'].includes(mode) || !packageDirectory || !filename) {
  throw new Error('Usage: node scripts/mst_reference.mjs generate|verify /path/to/@atproto/repo file.json')
}
const directory = resolve(packageDirectory)
const metadata = JSON.parse(await readFile(join(directory, 'package.json')))
assert.equal(metadata.name, '@atproto/repo')
assert.equal(metadata.version, '0.8.10', 'Reference version must match fixture provenance')
const implementationSha256 = createHash('sha256').update(await readFile(join(directory, 'dist/mst/mst.js'))).update(await readFile(join(directory, 'dist/mst/util.js'))).digest('hex')
const require = createRequire(join(directory, 'package.json'))
const { MST, BlockMap, MemoryBlockstore } = require('./dist/index.js')
const { CID } = require('multiformats/cid')
const path = n => `com.example.record/r${n}`
const height = key => {
  let bits = 0
  for (const byte of createHash('sha256').update(key).digest()) {
    if (byte === 0) { bits += 8; continue }
    bits += Math.clz32(byte) - 24
    break
  }
  return Math.floor(bits / 2)
}
const encodedBlocks = blocks => Object.fromEntries([...blocks].map(([cid, bytes]) => [cid.toString(), Buffer.from(bytes).toString('base64')]))

if (mode === 'generate') {
  const values = new BlockMap()
  const original = await values.add({ value: 'original' })
  const changed = await values.add({ value: 'changed' })
  const keys = Array.from({length: 600}, (_, n) => path(n + 1))
  const high = keys.filter(key => height(key) >= 2)
  const cases = [
    ['empty', [], []],
    ['initial growth', [], keys.slice(0, 40).map(key => ['create', key])],
    ['mixed boundaries', keys, [['update', path(1)], ['delete', path(2)], ['create', path(601)]]],
    ['root collapse', keys, high.map(key => ['delete', key])],
    ['root growth', keys.filter(key => !high.includes(key)), high.map(key => ['create', key])],
    ['last deletion', [high[0]], [['delete', high[0]]]],
    ['empty commit', keys, []],
    ['maximum mixed batch', keys, Array.from({length: 200}, (_, n) => n % 3 === 0 ? ['delete', path(n + 1)] : n % 3 === 1 ? ['update', path(n + 1)] : ['create', path(n + 601)])],
  ]
  const fixtures = []
  for (const [name, initial, edits] of cases) {
    let tree = await MST.create(new MemoryBlockstore())
    for (const key of initial) tree = await tree.add(key, original)
    const before = await tree.getUnstoredBlocks()
    const operations = []
    for (const [action, key] of edits) {
      const previous = await tree.get(key)
      if (action === 'create') tree = await tree.add(key, changed)
      if (action === 'update') tree = await tree.update(key, changed)
      if (action === 'delete') tree = await tree.delete(key)
      operations.push({action, path: key, cid: action === 'delete' ? null : changed.toString(), prev: previous?.toString() ?? null})
    }
    const after = await tree.getUnstoredBlocks()
    fixtures.push({name, records: Object.fromEntries(initial.map(key => [key, original.toString()])), operations,
      beforeRoot: before.root.toString(), afterRoot: after.root.toString(),
      beforeBlocks: encodedBlocks(before.blocks), afterBlocks: encodedBlocks(after.blocks)})
  }
  await writeFile(filename, JSON.stringify({reference: '@atproto/repo@0.8.10', implementationSha256, fixtures}, null, 2) + '\n')
  console.log(`Generated ${fixtures.length} reference fixtures`)
} else {
  const {reference, implementationSha256: expectedHash, fixtures} = JSON.parse(await readFile(filename))
  assert.equal(implementationSha256, expectedHash, 'Reference implementation checksum mismatch')
  assert.equal(reference, '@atproto/repo@0.8.10')
  for (const fixture of fixtures) {
    const blocks = new BlockMap(Object.entries(fixture.proof).map(([cid, bytes]) => [CID.parse(cid), Buffer.from(bytes, 'base64')]))
    let tree = MST.load(new MemoryBlockstore(blocks), CID.parse(fixture.afterRoot))
    for (const op of fixture.operations) {
      const actual = await tree.get(op.path)
      assert.equal(actual?.toString() ?? null, op.cid, `${fixture.name}: new state`)
    }
    for (const op of [...fixture.operations].reverse()) {
      if (op.action === 'create') tree = await tree.delete(op.path)
      if (op.action === 'update') tree = await tree.update(op.path, CID.parse(op.prev))
      if (op.action === 'delete') tree = await tree.add(op.path, CID.parse(op.prev))
    }
    assert.equal((await tree.getPointer()).toString(), fixture.beforeRoot, `${fixture.name}: inverse root`)
    console.log(`Verified ${fixture.name} (${blocks.size} proof nodes)`)
  }
}
