# ChopChop for Chrome and Edge

This Manifest V3 extension sends links to the running ChopChop app. It is loaded from a local folder; it has not been published to a browser store. Safari is not supported by this package.

## Setup

1. In ChopChop, open **Settings → Integrations → Browser Integration** and enable receiving downloads.
2. Choose **Export Extension…** and save the folder.
3. Open `chrome://extensions` or `edge://extensions`, enable **Developer mode**, choose **Load unpacked**, and select the exported folder.
4. Copy the pairing code from ChopChop. Open the extension's settings and paste it there.

Right-click a download link, video or audio element and choose **Send to ChopChop**. Alternatively, open the extension popup to find direct media addresses on the current page and select which links to send. Every import opens ChopChop's confirmation flow.

ChopChop must be running with Browser Capture enabled. If pairing fails, copy the current code again. **Reset Pairing** in ChopChop revokes previously copied codes. **Export Extension…** will not overwrite an existing folder; export into another location when updating, then reload that folder in the browser.

The extension follows the browser language, supports English and Simplified Chinese, and falls back to English. `chrome.i18n` supplies popup, settings, context-menu and error text. Connection failure explains both possible remedies—open ChopChop and enable receiving—because a stopped loopback listener cannot identify which condition applies. Rejected pairing, throttling and rejected imports have distinct messages and next steps. Only stable error codes are saved; raw server errors and source URLs are not retained as diagnostics.

## Scope and permissions

- `activeTab` and `scripting` inspect only the page where you explicitly open the extension. Media discovery reads video/audio/source elements, direct HLS/DASH resource addresses and manifest links.
- `contextMenus` adds the send action. `storage` retains the local pairing code and a generic last error.
- Persistent host access is limited to `http://127.0.0.1/*`. Requests go only to the configured local ChopChop port, with a pairing token. Redirects are rejected and browser credentials are omitted.
- There is no cookie access, request interception, background page scanning, remote code, or remote upload service. Signed source URLs are sent only when selected; they are not retained in extension storage.
- This does not extract arbitrary video-site pages or decrypt protected content. A blob URL is not a downloadable media address. When no direct source is found, the popup offers the current page address explicitly.
- ChopChop bounds each batch to 100 links and 128 KiB. Very large selections should be sent in smaller batches.

Tests: `node --test Scripts/test-browser-extension.mjs` from the repository root. Swift tests separately exercise the real loopback listener and authentication. No browser UI was driven during automated verification.
