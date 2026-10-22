import {message, localizeDocument, captureErrorMessage} from './i18n.js';
localizeDocument();
import {discoverPageMedia, normalizeLinks} from './core.js';
const status = document.getElementById('status');
const send = document.getElementById('send');
const list = document.getElementById('links');
document.getElementById('settings').addEventListener('click', () => chrome.runtime.openOptionsPage());
try {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  let discovered = [];
  try {
    const results = await chrome.scripting.executeScript({target: {tabId: tab.id}, func: discoverPageMedia});
    discovered = results.flatMap(item => item.result || []);
  } catch { /* Restricted pages cannot be inspected; the URL can still be offered. */ }
  const media = normalizeLinks(discovered);
  const urls = media.length ? media : normalizeLinks([tab?.url]);
  for (const url of urls) {
    const label = document.createElement('label'); label.className = 'resource';
    const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.value = url;
    checkbox.checked = urls.length === 1;
    const name = document.createElement('span');
    const parsed = new URL(url);
    // Show the path without signed query parameters; retain the original only in memory for sending.
    name.textContent = parsed.hostname + parsed.pathname;
    label.append(checkbox, name); list.append(label);
  }
  const update = () => { send.disabled = !list.querySelector('input:checked'); };
  list.addEventListener('change', update); update();
  const {lastError} = await chrome.storage.session.get('lastError');
  status.textContent = (lastError ? message(lastError) : null) || (media.length ? message(media.length === 1 ? 'mediaOne' : 'mediaMany', [String(media.length)]) : message('noMedia'));
  await chrome.storage.session.remove('lastError');
  await chrome.action.setBadgeText({text: ''});
} catch { status.textContent = message('pageRestricted'); }
send.addEventListener('click', async () => {
  send.disabled = true;
  try {
    const urls = Array.from(list.querySelectorAll('input:checked'), item => item.value);
    const response = await chrome.runtime.sendMessage({type: 'handoff', urls, context: urls.length === 1 && urls[0] === contextSource ? requestContext : undefined});
    if (response.error) throw Object.assign(new Error(), {code: response.error});
    requestContext = undefined;
    document.getElementById('request-context').textContent = '';
    const count = urls.length;
    status.textContent = message(count === 1 ? 'sentOne' : 'sentMany', [String(count)]);
  } catch (error) { status.textContent = error.code ? message(error.code) : captureErrorMessage(error); }
  finally { send.disabled = !list.querySelector('input:checked'); await refreshReceipts(); }
});

let requestContext, contextSource;
list.addEventListener('change', () => { requestContext = undefined; document.getElementById('request-context').textContent = ''; });
document.getElementById('include-context').addEventListener('click', async () => {
  try {
    const selected = Array.from(list.querySelectorAll('input:checked'), item => item.value);
    if (selected.length !== 1 || !/^https?:/.test(selected[0])) throw new Error();
    const target = new URL(selected[0]);
    // Prompt for one origin only, and collect credentials only for this click.
    const granted = await chrome.permissions.request({permissions: ['cookies'], origins: [target.origin + '/*']});
    if (!granted) return;
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    const cookies = await chrome.cookies.getAll({url: target.href});
    contextSource = selected[0];
    requestContext = {sourceOrigin: target.origin, userAgent: navigator.userAgent, referer: '', authorization: '',
      cookie: cookies.filter(c => !c.partitionKey).map(c => `${c.name}=${c.value}`).join('; ')};
    if (tab?.url && /^https?:/.test(tab.url)) requestContext.referer = new URL(tab.url).origin + '/';
    document.getElementById('request-context').textContent = message('contextIncluded');
  } catch { status.textContent = message('contextUnavailable'); }
});
const receiptSnapshots = new Map();
async function refreshReceipts(revealID) {
  const container = document.getElementById('receipts');
  try {
    const response = await chrome.runtime.sendMessage({type: 'receipts', revealID});
    if (response.error) throw new Error();
    container.replaceChildren();
    for (const receipt of response.value) {
      if (!receipt.error) receiptSnapshots.set(receipt.requestID, receipt);
      else if (receipt.error !== 'receiptMissing' && receiptSnapshots.has(receipt.requestID)) {
        receipt.tasks = receiptSnapshots.get(receipt.requestID).tasks.map(task => ({...task, available: false}));
      }
      const item = document.createElement('div'); item.className = 'resource';
      const title = document.createElement('span'); title.textContent = message('receipt_' + receipt.state);
      item.append(title);
      if (receipt.error) { const error = document.createElement('p'); error.textContent = message(receipt.error); item.append(error); }
      for (const task of receipt.tasks) {
        const line = document.createElement('p');
        const percent = task.total > 0 ? ` ${Math.min(100, Math.floor(task.completed / task.total * 100))}%` : '';
        line.textContent = `${task.name} · ${message('task_' + task.status)}${percent}${task.available ? '' : ' · ' + message('offline')}`;
        item.append(line);
      }
      if (receipt.tasks.length) {
        const open = document.createElement('button'); open.textContent = message('openInApp');
        open.addEventListener('click', () => refreshReceipts(receipt.requestID)); item.append(open);
      }
      container.append(item);
    }
  } catch { /* Keep the last visible receipt when the app goes offline. */ }
}
document.getElementById('refresh-receipts').addEventListener('click', () => refreshReceipts());
await refreshReceipts();
setInterval(refreshReceipts, 5000);
