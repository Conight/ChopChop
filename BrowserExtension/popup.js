import {message, localizeDocument, captureErrorMessage} from './i18n.js';
localizeDocument();
import {discoverPageMedia, normalizeLinks, sendLinks} from './core.js';
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
    const {pairing = ''} = await chrome.storage.local.get('pairing');
    const count = await sendLinks(Array.from(list.querySelectorAll('input:checked'), item => item.value), pairing);
    status.textContent = message(count === 1 ? 'sentOne' : 'sentMany', [String(count)]);
  } catch (error) { status.textContent = captureErrorMessage(error); }
  finally { send.disabled = !list.querySelector('input:checked'); }
});
