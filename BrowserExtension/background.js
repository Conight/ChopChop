import {message, CaptureError} from './i18n.js';
import {sendLinks} from './core.js';
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => chrome.contextMenus.create({
    id: 'send-to-chopchop', title: message('contextDownload'), contexts: ['link', 'video', 'audio']
  }));
  chrome.storage.local.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'});
});
chrome.contextMenus.onClicked.addListener(async info => {
  if (info.menuItemId !== 'send-to-chopchop') return;
  try {
    const {pairing = ''} = await chrome.storage.local.get('pairing');
    await sendLinks([info.linkUrl || info.srcUrl], pairing);
    await chrome.action.setBadgeText({text: ''});
  } catch (error) {
    // Persist only a generic actionable error, never the source URL or request headers.
    await chrome.storage.session.set({lastError: error instanceof CaptureError ? error.code : 'unavailable'});
    await chrome.action.setBadgeText({text: '!'});
    await chrome.action.setBadgeBackgroundColor({color: '#bd6510'});
  }
});
