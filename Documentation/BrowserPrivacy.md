# ChopChop browser extension privacy

ChopChop's Chrome/Edge extension sends selected download resources to the paired ChopChop application on this computer. It has no remote analytics, advertising, account service, or automatic upload destination.

By default, the extension uses temporary active-tab access to inspect media elements and resource addresses when you open its popup. Opening a page alone does not scan or submit its contents. You choose which resources to send. The desktop application asks for confirmation before starting a download.

The optional **Include cookies for this download** action requests cookie access and permission for the selected resource's origin. It reads matching unpartitioned cookies only after your explicit action. Those cookies, the browser User-Agent, and the source page's origin as Referer are sent only with that submission. The desktop confirmation lets you review/edit these fields. Credentialed Metalink documents are saved for separate review; linked downloads do not automatically inherit the browser credentials. You may remove optional cookie and site permissions in the extension's options or browser permission settings. No automatic download takeover or request interception is enabled.

Local extension storage contains the pairing credential and a bounded, seven-day list of request IDs, fingerprints and receipt states. Browser session storage contains generic error codes; it does not contain resource URLs, cookies or headers. Closing an open popup releases its in-memory resource selection and task details. Browser restart clears session error storage while retaining local submission identities. Normal browser behavior determines whether browsing activity itself is retained in browser history.

The paired desktop app receives the selected resources and any explicitly included request information. The download engine necessarily contacts the selected resource's servers. Its saved download session may retain confirmed request credentials so downloads can continue later. The application receipt file stores task/request IDs and request fingerprints, with bounded retention; it does not store source URLs or headers. The extension can read progress only for tasks associated with its known receipt IDs, and cannot browse arbitrary application history or files.

Use Reset Pairing in ChopChop to revoke the old local pairing token. Review any uncertain downloads before clearing receipt history. Uninstalling the extension removes its browser storage according to browser behavior; it does not remove desktop downloads or engine sessions.

For questions, use the [ChopChop issue tracker](https://github.com/Conight/ChopChop/issues), without posting pairing credentials, cookies or private download addresses.
