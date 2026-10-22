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

HTTP/HTTPS, SFTP, Magnet, ED2K and Thunder links can be sent from the context menu. Thunder payloads are preserved for the engine, including GBK bytes and missing or escaped Base64 padding; wrapped local-file URLs and credentials are rejected.

## Scope and permissions

- `activeTab` and `scripting` inspect only the page where you explicitly open the extension. Media discovery reads video/audio/source elements, direct HLS/DASH resource addresses and manifest links.
- `contextMenus` adds the send action. `storage` retains the local pairing code and a generic last error.
- Persistent host access is limited to `http://127.0.0.1/*`. Requests go only to the configured local ChopChop port, with a pairing token. Redirects are rejected and browser credentials are omitted.
- Cookie access is optional and restricted to a resource origin explicitly approved for a submission. There is no request interception, background page scanning, remote code, or remote upload service. Signed source URLs are sent only when selected; they are not retained in extension storage.
- This does not extract arbitrary video-site pages or decrypt protected content. A blob URL is not a downloadable media address. When no direct source is found, the popup offers the current page address explicitly.
- ChopChop bounds each batch to 100 links and 128 KiB. Very large selections should be sent in smaller batches.

Tests: `node --test Scripts/test-browser-extension.mjs` from the repository root. Swift tests separately exercise the real loopback listener and authentication. No browser UI was driven during automated verification.

## Receipts and request details (0.0.2)

The extension checks the paired app’s v2 capabilities before sending; an older app must be updated and restarted. Download writes use a separate v2 endpoint, so an older v1 app cannot silently accept them. New submissions have a request identity saved before sending. **Recent submissions** distinguishes waiting for application confirmation, created downloads, partial cancellation, cancellation, and an unknown result. Refresh reads the receipt; it never replays a download. An interrupted application confirmation is reported as unknown after restart. If no receipt exists, the extension allows a new explicit submission. Open **ChopChop** from the popup to launch the installed production app, then refresh. This launch link contains no source, request ID, or credentials. Development builds do not register system handlers.

The application retains at most 512 receipt identities for seven days. New expired requests are rejected. The receipt file contains IDs and request fingerprints, not source URLs or headers. Reset Pairing revokes the previous pairing token and clears receipt identities; review Downloads before resetting an uncertain submission. Local browser storage retains up to 128 submission identities/fingerprints for seven days, with the last ten for the selected pairing shown. Unresolved entries are not evicted to admit new work. Browser restart preserves these identities. Task names and progress shown in an open popup are held only in memory. Pairing changes isolate the visible receipt list.

**Include cookies for this download…** is optional. Select exactly one HTTP(S) resource, then approve cookie access and host permission for that origin. Only this explicit submission receives matching unpartitioned cookies, the browser User-Agent, and the source page's origin as Referer. No credential is retained in extension storage. ChopChop displays a notice and its normal editable confirmation. Changing the resource origin requires clearing forwarded credentials. The supported engine keeps Cookie/Authorization headers with their original origin across redirects and media requests. Credentialed HTTP downloads disable automatic descriptor following: in particular, Metalink documents are saved for a separate explicit import, so their child resources cannot inherit browser credentials. Explicit torrent selection still fetches its metadata before asking you to choose files. The engine's own saved session may retain confirmed request options, as with manually entered authentication.

Remove optional cookie/site grants from the extension's options with **Remove Optional Cookie Access**. No automatic interception or background page scanning has been added.

Build the source-only Chrome/Edge store upload package with `python3 Scripts/package-browser-extension.py`. Store listing/privacy drafts live in `Documentation/BrowserStoreListing.md` and `Documentation/BrowserPrivacy.md`. A generated ZIP is an upload artifact, not a published store listing.
