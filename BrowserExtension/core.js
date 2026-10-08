import {CaptureError} from './i18n.js';
export function parsePairingCode(value) {
  const match = /^(\d{1,5}):([a-f0-9]{64})$/.exec(value.trim());
  if (!match || Number(match[1]) < 1024 || Number(match[1]) > 65535) throw new CaptureError('invalidPairing');
  return { port: Number(match[1]), token: match[2] };
}

export function normalizeLinks(values) {
  const links = [];
  for (const value of values) {
    if (typeof value !== 'string' || new TextEncoder().encode(value).length > 8192) continue;
    try {
      const url = new URL(value);
      if (!['http:', 'https:', 'magnet:', 'ed2k:'].includes(url.protocol) || url.username || url.password) continue;
      if (!links.includes(url.href)) links.push(url.href);
      if (links.length === 100) break;
    } catch { /* Ignore page strings that are not download URLs. */ }
  }
  return links;
}

export async function sendLinks(urls, pairing, fetcher = fetch) {
  const {port, token} = parsePairingCode(pairing);
  const links = normalizeLinks(urls);
  if (!links.length) throw new CaptureError('noLinks');
  let response;
  try {
    response = await fetcher(`http://127.0.0.1:${port}/v1/import`, {
      method: 'POST', headers: {'Content-Type': 'application/json', Authorization: `Bearer ${token}`},
      body: JSON.stringify({urls: links}), cache: 'no-store', credentials: 'omit', redirect: 'error',
      signal: AbortSignal.timeout(5000)
    });
  } catch { throw new CaptureError('unavailable'); }
  if (response.status === 403) throw new CaptureError('pairingRejected');
  if (response.status === 429) throw new CaptureError('rateLimited');
  if (response.status !== 202) throw new CaptureError('rejected');
  return links.length;
}

// Executed only after the user opens the popup, with temporary activeTab access.
export function discoverPageMedia() {
  const sources = [];
  for (const element of document.querySelectorAll('video, audio, source')) {
    sources.push(element.currentSrc || element.src || '');
  }
  const candidates = [...performance.getEntriesByType('resource').map(entry => entry.name),
    ...Array.from(document.querySelectorAll('a[href]'), node => node.href)];
  for (const candidate of candidates) {
    try { if (/\.(m3u8|mpd)(?:$|\?)/i.test(new URL(candidate).pathname + new URL(candidate).search)) sources.push(candidate); }
    catch { /* A page can contain malformed links. */ }
  }
  return sources.slice(0, 500);
}
