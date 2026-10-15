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
      const original = value.trim();
      const thunder = /^thunder:\/\//i.test(original);
      let decoded = original;
      if (thunder) {
        let payload = decodeURIComponent(original.slice(10)).replace(/\/+$/, '');
        payload += '='.repeat((4 - payload.length % 4) % 4);
        const bytes = atob(payload);
        if (!bytes.startsWith('AA') || !bytes.endsWith('ZZ') || bytes.length <= 4) continue;
        decoded = Array.from(bytes.slice(2, -2).replace(/^[\t-\r ]+|[\t-\r ]+$/g, ''), char => {
          const byte = char.charCodeAt(0);
          return byte > 0x20 && byte < 0x7f ? char : '%' + byte.toString(16).toUpperCase().padStart(2, '0');
        }).join('');
      }
      if (/[\r\n\0]/.test(decoded)) continue;
      let link = original;
      // ED2K file links use pipe-delimited fields, not a URL authority.
      if (!/^ed2k:\/\/(?:\||%7c)file(?:\||%7c)/i.test(decoded)) {
        const url = new URL(decoded);
        if (!['http:', 'https:', 'sftp:', 'magnet:', 'ed2k:'].includes(url.protocol) || url.username || url.password) continue;
        link = thunder ? original : url.href;
      }
      if (!links.includes(link)) links.push(link);
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
