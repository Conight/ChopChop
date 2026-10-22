import {CaptureError} from './i18n.js';
import {normalizeLinks, bridgeRequest, requestFingerprint, checkBridgeCapabilities} from './core.js';
let admission = Promise.resolve();

export function handoff(urls, context) {
  const pairingRead = chrome.storage.local.get('pairing');
  const job = admission.then(async () => {
    const {pairing = ''} = await pairingRead;
    return submit(urls, context, pairing);
  });
  admission = job.catch(() => {});
  return job;
}
async function submit(values, context, pairing) {
  const urls = normalizeLinks(values);
  if (!urls.length) throw new CaptureError('noLinks');
  const scope = await requestFingerprint(pairing);
  const fingerprint = await requestFingerprint({urls: [...urls].sort(), context});
  const {receipts: storedReceipts = []} = await chrome.storage.local.get('receipts');
  const receipts = storedReceipts.filter(entry => Date.now() - entry.issuedAt < 7 * 86400000);
  // Persist before sending. Service worker suspension cannot turn an uncertain
  // write into an automatic retry. No URL, cookie or header goes into storage.
  if (receipts.some(r => r.scope === scope && r.fingerprint === fingerprint && ['unknown', 'pending'].includes(r.state))) {
    throw new CaptureError('uncertain');
  }
  await checkBridgeCapabilities(pairing);
  const requestID = crypto.randomUUID();
  const issuedAt = Date.now();
  const entry = {requestID, issuedAt, scope, fingerprint, state: 'unknown', count: urls.length};
  const retained = [...receipts];
  if (retained.length >= 128) {
    const resolved = retained.findIndex(r => !['unknown', 'pending'].includes(r.state));
    if (resolved < 0) throw new CaptureError('receiptCapacity');
    retained.splice(resolved, 1);
  }
  retained.push(entry);
  await chrome.storage.local.set({receipts: retained});
  try {
    const receipt = await bridgeRequest('import', {requestID, issuedAt, urls, ...(context ? {context} : {})}, pairing);
    entry.state = receipt.state;
    await chrome.storage.local.set({receipts: retained});
    return receipt;
  } catch (error) {
    if (['invalidPairing', 'pairingRejected', 'rateLimited', 'rejected'].includes(error.code)) {
      entry.state = 'rejected';
      await chrome.storage.local.set({receipts: retained});
    }
    throw error;
  }
}
export async function recentReceipts(revealID) {
  // Serialize reads with admission so a status update cannot drop a newly
  // persisted identity from local storage.
  return admission = admission.catch(() => {}).then(async () => {
    const {pairing = ''} = await chrome.storage.local.get('pairing');
    await checkBridgeCapabilities(pairing);
    const scope = await requestFingerprint(pairing);
    const {receipts: storedReceipts = []} = await chrome.storage.local.get('receipts');
    const receipts = storedReceipts.filter(entry => Date.now() - entry.issuedAt < 7 * 86400000);
    const scoped = receipts.filter(r => r.scope === scope);
    const visible = scoped.slice(-10).reverse();
    const visibleIDs = new Set(visible.map(r => r.requestID));
    const queries = [...visible, ...scoped.filter(r => !visibleIDs.has(r.requestID) && ['pending', 'unknown'].includes(r.state))];
    const result = [];
    let unavailable = false;
    for (const entry of queries) {
      if (entry.state === 'rejected') continue;
      if (unavailable) { result.push({requestID: entry.requestID, state: entry.state, tasks: [], error: 'unavailable'}); continue; }
      try {
        const receipt = await bridgeRequest('receipt', {requestID: entry.requestID, reveal: entry.requestID === revealID}, pairing);
        entry.state = receipt.state;
        result.push(receipt);
      } catch (error) {
        if (error.code === 'receiptMissing') entry.state = 'rejected';
        else unavailable = true;
        result.push({requestID: entry.requestID, state: entry.state === 'rejected' ? 'unknown' : entry.state, tasks: [], error: error.code});
      }
    }
    await chrome.storage.local.set({receipts});
    return result.filter(receipt => visibleIDs.has(receipt.requestID));
  });
}
