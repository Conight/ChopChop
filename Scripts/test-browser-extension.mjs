import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {parsePairingCode, normalizeLinks, sendLinks, discoverPageMedia} from '../BrowserExtension/core.js';
const token = 'a'.repeat(64);

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
