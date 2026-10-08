import {message, localizeDocument, captureErrorMessage} from './i18n.js';
localizeDocument();
import {parsePairingCode} from './core.js';
const input = document.getElementById('code');
const status = document.getElementById('status');
document.getElementById('pair').addEventListener('submit', async event => {
  event.preventDefault();
  try {
    parsePairingCode(input.value);
    await chrome.storage.local.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'});
    await chrome.storage.local.set({pairing: input.value.trim()});
    input.value = ''; status.textContent = message('paired');
  } catch (error) { status.textContent = captureErrorMessage(error); }
});
