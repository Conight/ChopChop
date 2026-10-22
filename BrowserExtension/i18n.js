const fallback = {
  "extensionDescription": "Send links and discover page media for review in ChopChop.",
  "sendTitle": "Send to ChopChop",
  "contextDownload": "Download with ChopChop",
  "pairTitle": "Pair with ChopChop",
  "pairInstructions": "In ChopChop → Settings → Browser Capture, enable integration and copy the pairing code.",
  "pairingCode": "Pairing code",
  "savePairing": "Save Pairing",
  "paired": "Paired. Keep ChopChop open when sending links.",
  "popupInstructions": "Select media found in this page, or send the current link. ChopChop will ask you to review it.",
  "looking": "Looking for media…",
  "sendSelected": "Send Selected",
  "pairBrowser": "Pair Browser…",
  "invalidPairing": "Copy the pairing code from ChopChop → Settings → Browser Capture.",
  "noLinks": "No supported download links were selected.",
  "unavailable": "Cannot connect to ChopChop. Open the app; if it is already running, enable receiving in Settings → Browser Capture, then try again.",
  "pairingRejected": "Pairing was rejected. Copy a new pairing code from ChopChop.",
  "rateLimited": "Please wait a moment before sending more links.",
  "rejected": "ChopChop could not accept these links. Review the selection and try a smaller batch.",
  "mediaOne": "1 media source found.",
  "mediaMany": "$1 media sources found.",
  "noMedia": "No direct media found. You can send this page link, or copy the direct download URL.",
  "pageRestricted": "This page cannot be inspected. Right-click a download link instead.",
  "sentOne": "1 link sent. Review in ChopChop.",
  "sentMany": "$1 links sent. Review in ChopChop.",
  "uncertain": "The submission result is unknown. Refresh recent submissions and check ChopChop before sending again.",
  "receiptMissing": "No receipt exists for this request. You can send the selection again.",
  "includeContext": "Include cookies for this download…",
  "contextIncluded": "Request details included for this selection only. Review them in ChopChop.",
  "contextUnavailable": "Select one HTTP or HTTPS link to include request details.",
  "recentSubmissions": "Recent submissions",
  "refreshReceipts": "Refresh status",
  "openInApp": "Open in ChopChop",
  "offline": "Saved status; engine unavailable",
  "launchApp": "Open ChopChop",
  "receipt_pending": "Waiting for confirmation in ChopChop",
  "receipt_created": "Downloads created",
  "receipt_partial": "Some downloads created; remaining items cancelled",
  "receipt_cancelled": "Submission cancelled",
  "receipt_unknown": "Result needs review in ChopChop",
  "task_Active": "Active",
  "task_Waiting": "Waiting",
  "task_Paused": "Paused",
  "task_Completed": "Completed",
  "task_Failed": "Failed",
  "task_Removed": "Removed",
  "forgetCookies": "Remove Optional Cookie Access",
  "cookiesForgotten": "Optional cookie and site access removed.",
  "receiptCapacity": "Too many unresolved submissions. Refresh their status and review ChopChop before sending more.",
  "appUpdateRequired": "Update and restart ChopChop before using this extension. No download was submitted to the older app."
};
export function message(key, substitutions = []) {
  const translated = globalThis.chrome?.i18n?.getMessage(key, substitutions);
  return translated || (fallback[key] || fallback.unavailable).replace(/\$(\d+)/g, (_, i) => substitutions[Number(i) - 1] ?? '');
}
export function localizeDocument() {
  document.documentElement.lang = globalThis.chrome?.i18n?.getUILanguage() || 'en';
  for (const element of document.querySelectorAll('[data-i18n]')) element.textContent = message(element.dataset.i18n);
}
export class CaptureError extends Error {
  constructor(code) { super(message(code)); this.code = code; }
}
export function captureErrorMessage(error) {
  return message(error instanceof CaptureError ? error.code : 'unavailable');
}
