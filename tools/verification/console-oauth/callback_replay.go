package main

// Production callback replay, executed by Node without adding application JS sources.
const callbackReplay = `// Executes the production native callback with synthetic integration API facts.
// No real account, network, CLI, or inference request is used.
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { resolve as resolvePath } from 'node:path';
const { readConsoleAccount } = await import(pathToFileURL(resolvePath('internal/plugins/harness/opencode/assets/credentials.mjs')));

const source = { type: 'credential', method: 'oauth', id: 'synthetic-console' };
const fresh = () => ({ type: 'oauth', methodID: 'console', access: 'synthetic-access',
  refresh: 'synthetic-refresh-must-stay-native', expires: Date.now() + 300_000,
  metadata: { orgID: 'synthetic-org', server: 'https://opencode.ai/console' } });
let active = source;
let stored = fresh();
let resolve = async () => stored;
const ctx = { integration: { connection: {
  active: async id => { assert.equal(id, 'opencode'); return active; },
  resolve: async connection => { assert.equal(connection, source); return resolve(); }
} } };
const input = { sourceCredentialID: source.id, providerID: "opencode-go", phase: "lease" };
const read = extra => readConsoleAccount(ctx, { ...input, ...extra });
const lease = await read();
assert.deepEqual(lease, { lease: { type: "oauth", methodID: stored.methodID, access: stored.access, expires: stored.expires, metadata: stored.metadata }, configuration: {} });
assert(!JSON.stringify(lease).includes(stored.refresh));

// The expired stored token is never consumed by the callback. Native resolve
// refreshes it, retaining the rotated refresh grant in native storage only.
stored.expires = Date.now() - 1000;
resolve = async () => {
  assert(stored.expires < Date.now());
  stored = { ...fresh(), access: 'rotated-access', refresh: 'rotated-refresh' };
  return stored;
};
assert.equal((await read()).lease.access, 'rotated-access');
assert.equal(stored.refresh, 'rotated-refresh');
resolve = async () => stored;

active = undefined;
assert.deepEqual(await read(), {});
active = { ...source, method: 'key' };
assert.deepEqual(await read(), {});
active = { ...source, id: 'another-account' };
await assert.rejects(read(), /account changed/);
active = source;
resolve = async () => { active = { ...source, id: 'switched-during-resolve' }; return stored; };
await assert.rejects(read(), /account changed/);
active = source;
resolve = async () => stored;
for (const override of [
  { access: '' }, { type: 'key' }, { expires: Date.now() - 1000 },
  { expires: 1.5 }, { metadata: [] }
]) {
  stored = { ...fresh(), ...override };
  await assert.rejects(read());
}
stored = fresh();
resolve = async () => { throw new Error('synthetic refresh failure'); };
await assert.rejects(read(), /synthetic refresh failure/);

// Actual production queue serializes native resolve across concurrent callers,
// and a failed predecessor cannot poison later acquisitions.
let entered = 0;
let maximum = 0;
resolve = async () => {
  entered++;
  maximum = Math.max(maximum, entered);
  await new Promise(done => setTimeout(done, 5));
  entered--;
  return stored;
};
const concurrent = await Promise.all(Array.from({ length: 6 }, () => read()));
assert.equal(maximum, 1);
assert(concurrent.every(item => item.lease.access === stored.access));
console.log('Native Console account callback: refresh grant exclusion, native refresh rotation, account pin, expiry, failure recovery and concurrency passed');
`
