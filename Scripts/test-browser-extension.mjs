import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {parsePairingCode, normalizeLinks, sendLinks, discoverPageMedia} from '../BrowserExtension/core.js';
const token = 'a'.repeat(64);

test('ED2K pipe-delimited file links work directly and inside Thunder', () => {
  const uri = 'ed2k://|file|file.bin|1|0123456789abcdef0123456789abcdef|/';
  for (const value of [uri, uri.replaceAll('|', '%7C')]) {
    const wrapped = 'thunder://' + Buffer.from('AA' + value + 'ZZ').toString('base64');
    assert.deepEqual(normalizeLinks([value, wrapped]), [value, wrapped]);
  }
  assert.deepEqual(normalizeLinks(['ed2k://user:password@example.com/file']), []);
});

test('Thunder payloads retain their spelling and accept escaped/missing padding and GBK bytes', () => {
  const bytes = Buffer.concat([Buffer.from('AAhttps://example.com/'), Buffer.from([0xd6, 0xd0]), Buffer.from('.zipZZ')]);
  const link = 'thunder://' + bytes.toString('base64');
  for (const value of [link, link.replace(/=+$/, ''), link.replaceAll('=', '%3D') + '/']) {
    assert.deepEqual(normalizeLinks([value]), [value]);
  }
  for (const uri of ['file:///tmp/secret', 'ftp://example.com/file', 'javascript:alert(1)', 'https://user:pass@example.com/file']) {
    assert.deepEqual(normalizeLinks(['thunder://' + Buffer.from('AA' + uri + 'ZZ').toString('base64')]), []);
  }
  assert.deepEqual(normalizeLinks(['thunder://bad', 'thunder://%zz']), []);
});

test('pairing codes cannot redirect the bridge to another host or an invalid port', () => {
  assert.deepEqual(parsePairingCode(`29101:${token}`), {port: 29101, token});
  for (const value of [`80:${token}`, `65536:${token}`, `https://evil.test:${token}`, '29101:short']) {
    assert.throws(() => parsePairingCode(value));
  }
});
test('links are deduplicated, bounded, and reject scripts and credentials', () => {
  assert.deepEqual(normalizeLinks(['javascript:alert(1)', 'file:///tmp/private', 'https://user:pass@example.com/file',
    'https://example.com/video.m3u8?token=kept', 'https://example.com/video.m3u8?token=kept']), ['https://example.com/video.m3u8?token=kept']);
  assert.equal(normalizeLinks(Array.from({length: 101}, (_, i) => `https://example.com/${i}`)).length, 100);
});
test('the bridge receives selected original URLs without browser cookies', async () => {
  let request;
  const count = await sendLinks(['https://example.com/video?signature=source'], `29101:${token}`, async (url, options) => {
    request = {url, options}; return {status: 202};
  });
  assert.equal(count, 1);
  assert.equal(request.url, 'http://127.0.0.1:29101/v1/import');
  assert.equal(request.options.credentials, 'omit');
  assert.equal(request.options.redirect, 'error');
  assert.equal(request.options.headers.Authorization, `Bearer ${token}`);
  assert.deepEqual(JSON.parse(request.options.body), {urls: ['https://example.com/video?signature=source']});
});
test('connection errors never echo source URLs or tokens', async () => {
  await assert.rejects(sendLinks(['https://example.com/?secret=private'], `29101:${token}`, async () => {
    throw new Error('private');
  }), {code: 'unavailable'});
  await assert.rejects(sendLinks(['https://example.com/'], `29101:${token}`, async () => ({status: 403})), /Pairing was rejected/);
});
test('manifest limits persistent host access to loopback and contains no remote scripts', async () => {
  const manifest = JSON.parse(await readFile(new URL('../BrowserExtension/manifest.json', import.meta.url)));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.host_permissions, ['http://127.0.0.1/*']);
  assert(!manifest.permissions.includes('cookies'));
  assert(!manifest.permissions.includes('webRequest'));
  assert(!manifest.content_scripts);
  assert.match(manifest.content_security_policy.extension_pages, /script-src 'self'/);
});
test('media discovery reads only current-page elements and performance entries', () => {
  const oldDocument = globalThis.document;
  const oldPerformance = globalThis.performance;
  globalThis.document = {querySelectorAll: selector => selector === 'a[href]' ? [{href:'https://example.com/clip.mpd'}] : [{currentSrc: 'https://example.com/video.mp4'}]};
  globalThis.performance = {getEntriesByType: () => [{name: 'https://example.com/master.m3u8?token=x'}, {name: 'https://example.com/script.js'}]};
  try {
    assert.deepEqual(discoverPageMedia(), ['https://example.com/video.mp4', 'https://example.com/master.m3u8?token=x', 'https://example.com/clip.mpd']);
  } finally { globalThis.document = oldDocument; globalThis.performance = oldPerformance; }
});

test('English and Chinese catalogs cover every extension message and preserve substitutions', async () => {
  const en = JSON.parse(await readFile(new URL('../BrowserExtension/_locales/en/messages.json', import.meta.url)));
  const zh = JSON.parse(await readFile(new URL('../BrowserExtension/_locales/zh_CN/messages.json', import.meta.url)));
  assert.deepEqual(Object.keys(zh).sort(), Object.keys(en).sort());
  for (const key of Object.keys(en)) {
    assert(zh[key].message.length > 0, key);
    assert.deepEqual(zh[key].message.match(/\$\d+/g), en[key].message.match(/\$\d+/g), key);
  }
  const {message} = await import('../BrowserExtension/i18n.js');
  const oldChrome = globalThis.chrome;
  globalThis.chrome = {i18n: {getMessage: key => zh[key]?.message || ''}};
  try { assert.equal(message('pairTitle'), '与 ChopChop 配对'); }
  finally { globalThis.chrome = oldChrome; }
  assert.equal(message('sentMany', ['2']), '2 links sent. Review in ChopChop.');
});

test('bridge failures have stable actionable codes and never use server response text', async () => {
  for (const [status, code] of [[403, 'pairingRejected'], [429, 'rateLimited'], [500, 'rejected']]) {
    await assert.rejects(sendLinks(['https://example.com/private'], `29101:${token}`,
      async () => ({status, statusText: 'private details'})), {code});
  }
});

test('receipts validate identity, preserve uncertainty, and never replay writes', async () => {
  const {bridgeRequest} = await import('../BrowserExtension/core.js');
  const requestID = '62f47012-46a4-44a6-ae12-4cf8f60e8d01';
  let calls = 0;
  const fetcher = async () => { calls++; throw new Error('private-cookie'); };
  await assert.rejects(bridgeRequest('import', {requestID, urls: ['https://example.com/']}, `29101:${token}`, fetcher), {code: 'uncertain'});
  assert.equal(calls, 1);
  await assert.rejects(bridgeRequest('receipt', {requestID}, `29101:${token}`, async () => ({status: 200, json: async () => ({requestID: 'other', state: 'created', tasks: []})})), {code: 'unavailable'});
});

const capableFetch = fetcher => async (url, options) => url.endsWith('/capabilities')
  ? {status: 200, json: async () => ({protocolVersion: 2, receipts: true, requestContext: true})}
  : fetcher(url, options);

test('a suspended or concurrent handoff retains admission identity without storing source credentials', async () => {
  const {handoff, recentReceipts} = await import('../BrowserExtension/handoff.js');
  const oldChrome = globalThis.chrome, oldFetch = globalThis.fetch;
  let data = {}, writes = 0;
  globalThis.chrome = {storage: {
    local: {get: async () => ({pairing: `29101:${token}`, ...structuredClone(data)}), set: async value => { data = structuredClone({...data, ...value}); }},
    session: {get: async () => ({}), set: async () => {}}
  }};
  globalThis.fetch = capableFetch(async () => { writes++; throw new Error('network lost after acceptance'); });
  const urls = ['https://example.com/file?signature=private'];
  const context = {sourceOrigin: 'https://example.com', cookie: 'private-cookie'};
  try {
    await assert.rejects(handoff(urls, context), {code: 'uncertain'});
    await assert.rejects(handoff(urls, context), {code: 'uncertain'});
    assert.equal(writes, 1);
    const saved = JSON.stringify(data);
    assert(!saved.includes('signature'));
    assert(!saved.includes('private-cookie'));
    assert(!saved.includes(token));
    const id = data.receipts[0].requestID;
    globalThis.fetch = capableFetch(async (url, options) => {
      assert(url.endsWith('/receipt'));
      assert.equal(JSON.parse(options.body).requestID, id);
      return {status: 200, json: async () => ({requestID: id, state: 'created', tasks: []})};
    });
    assert.equal((await recentReceipts())[0].state, 'created');
    assert.equal(data.receipts[0].state, 'created');
  } finally { globalThis.chrome = oldChrome; globalThis.fetch = oldFetch; }
});

test('only an authoritative missing receipt releases an uncertain admission', async () => {
  const {handoff, recentReceipts} = await import('../BrowserExtension/handoff.js');
  const oldChrome = globalThis.chrome, oldFetch = globalThis.fetch;
  let data = {};
  globalThis.chrome = {storage: {
    local: {get: async () => ({pairing: `29101:${token}`, ...structuredClone(data)}), set: async value => { data = structuredClone({...data, ...value}); }},
    session: {get: async () => ({}), set: async () => {}}
  }};
  globalThis.fetch = capableFetch(async () => { throw new Error('lost'); });
  try {
    await assert.rejects(handoff(['https://example.com/new']), {code: 'uncertain'});
    globalThis.fetch = capableFetch(async () => ({status: 404}));
    await recentReceipts();
    assert.equal(data.receipts[0].state, 'rejected');
    globalThis.fetch = capableFetch(async (url, options) => {
      const body = JSON.parse(options.body);
      assert(body.issuedAt <= Date.now());
      return {status: 202, json: async () => ({requestID: body.requestID, state: 'pending', tasks: []})};
    });
    assert.equal((await handoff(['https://example.com/new'])).state, 'pending');
  } finally { globalThis.chrome = oldChrome; globalThis.fetch = oldFetch; }
});

test('unresolved durable identities cannot be evicted by admission capacity', async () => {
  const {handoff} = await import('../BrowserExtension/handoff.js');
  const {requestFingerprint} = await import('../BrowserExtension/core.js');
  const oldChrome = globalThis.chrome, oldFetch = globalThis.fetch;
  const scope = await requestFingerprint(`29101:${token}`);
  const receipts = Array.from({length: 128}, () => ({requestID: crypto.randomUUID(), scope, fingerprint: 'other', state: 'unknown', issuedAt: Date.now()}));
  let writes = 0;
  globalThis.chrome = {storage: {local: {get: async () => ({pairing: `29101:${token}`, receipts}), set: async () => { writes++; }}}};
  globalThis.fetch = capableFetch(async () => { throw new Error('No write should be sent'); });
  try {
    await assert.rejects(handoff(['https://example.com/another']), {code: 'receiptCapacity'});
    assert.equal(writes, 0);
    assert.equal(receipts.length, 128);
  } finally { globalThis.chrome = oldChrome; globalThis.fetch = oldFetch; }
});

test('an older app is rejected before any download or credential payload is sent', async () => {
  const {handoff} = await import('../BrowserExtension/handoff.js');
  const oldChrome = globalThis.chrome, oldFetch = globalThis.fetch;
  const calls = []; let writes = 0;
  globalThis.chrome = {storage: {local: {get: async () => ({pairing: `29101:${token}`, receipts: []}), set: async () => { writes++; }}}};
  globalThis.fetch = async (url, options) => { calls.push({url, body: options.body}); return {status: 404}; };
  try {
    await assert.rejects(handoff(['https://example.com/private?token=secret'], {cookie: 'private'}), {code: 'appUpdateRequired'});
    assert.equal(calls.length, 1);
    assert(calls[0].url.endsWith('/v2/capabilities'));
    assert.equal(calls[0].body, '{}');
    assert.equal(writes, 0);
  } finally { globalThis.chrome = oldChrome; globalThis.fetch = oldFetch; }
});

test('reordering an uncertain batch does not create a second submission', async () => {
  const {handoff} = await import('../BrowserExtension/handoff.js');
  const oldChrome = globalThis.chrome, oldFetch = globalThis.fetch;
  let data = {}, writes = 0;
  globalThis.chrome = {storage: {local: {
    get: async () => ({pairing: `29101:${token}`, ...structuredClone(data)}),
    set: async value => { data = structuredClone({...data, ...value}); }
  }}};
  globalThis.fetch = capableFetch(async () => { writes++; throw new Error('lost response'); });
  try {
    const urls = ['https://example.com/a', 'https://example.com/b'];
    await assert.rejects(handoff(urls), {code: 'uncertain'});
    await assert.rejects(handoff([...urls].reverse()), {code: 'uncertain'});
    assert.equal(writes, 1);
  } finally { globalThis.chrome = oldChrome; globalThis.fetch = oldFetch; }
});
