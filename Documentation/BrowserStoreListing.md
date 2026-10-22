# Chrome / Edge store submission draft

Name: ChopChop

Short description (English): Send selected links and page media to ChopChop, then follow their download progress.

Short description (简体中文): 将所选链接和网页媒体发送到 ChopChop，并查看下载进度。

## English description

Send links, direct video/audio sources, and media manifests to the native ChopChop download manager for macOS. Review each import in the application before downloading. Follow recent submissions in the popup, distinguish pending confirmation from an uncertain result, and open the associated tasks in ChopChop.

Use the optional cookie action for a single selected HTTP(S) resource when authentication is needed. Approve the resource's origin and review request details in the application. Optional cookie and site permissions can be removed in extension options. The extension has no automatic download takeover, remote analytics, or arbitrary website-page video extraction.

Requires a separately installed ChopChop desktop application and local pairing. This package supports Chrome and Edge; it does not provide Safari or Firefox integration.

## 简体中文描述

将链接、直接视频或音频地址和媒体清单发送到 macOS 原生下载管理器 ChopChop。每次导入均在应用中确认后下载。扩展弹窗显示最近提交、确认状态与下载进度，并可打开对应任务；结果未知时不会自动重复创建下载。

需要身份验证时，可为单个 HTTP(S) 资源选择附带 Cookie，批准该站点权限，并在应用中核对请求信息。可在扩展设置中移除可选 Cookie 和站点权限。不自动接管浏览器下载，不包含远程分析，也不解析任意视频网站页面。

需要另行安装 ChopChop 桌面应用并完成本地配对。此安装包支持 Chrome 和 Edge，未包含 Safari 或 Firefox 集成。

## Upload preparation

Run `python3 Scripts/package-browser-extension.py`. Upload the resulting versioned ZIP and use real screenshots from the packaged extension. Verify the public privacy-policy URL resolves to the committed BrowserPrivacy document before submission. Store account identity, hosted policy URL, screenshots, and actual review/publication are external release steps; no listing has been submitted by this change.

Permission explanations: activeTab/scripting inspect only the explicitly opened page; contextMenus adds the send action; storage holds pairing and bounded receipt identities; loopback host access communicates with the local app. Cookie access and HTTP(S) origin access are optional, requested for an explicit selected-resource action. There is no webRequest permission or remote executable code.
