# ChopChop 使用指南 / User Guide

## 简体中文

### 安装与第一次下载

从 [GitHub Releases](https://github.com/Conight/ChopChop/releases) 下载适用于 Apple 芯片的 DMG，并按 [README 安装说明](../README.md#install)核对校验和。当前测试版采用临时签名，尚未经过 Apple 公证；安装方式和限制与此前测试版一致。

1. 将 ChopChop 拖入“应用程序”后打开。首次使用时，选择“下载并启动”安装 Aria2 Next。引擎由应用管理，无需选择安装位置。
2. 在空列表中选择“粘贴链接”或“打开 Torrent 或 Metalink…”，也可将链接和文件拖入窗口。
3. 确认保存位置和启动选项。第一次访问自选文件夹时，使用系统文件选择器授予访问权限。
4. 确认添加后，在任务行查看进度、速度和错误。恢复的下载和 BT 做种默认暂停；需要时手动继续。

未知大小的下载显示已下载量，媒体任务显示媒体进度；获取元数据、校验和整理文件不会显示虚假的百分比。视频功能接受直接 HLS／DASH 地址，并不解析任意视频网站网页。

单击任务，在这一行下方展开保存位置和常用设置；一次只展开一个任务。点击系统展开三角可以收起摘要。Engine 在线时可修改任务的下载限速，BT 任务还可修改上传限速，点击“应用”保存；单位为 KiB/s，0 表示移除该任务的限速，全局限制仍然有效，不会停止做种，也不会自动继续暂停的任务。

选中任务后按 **空格** 打开独立的“下载详情”面板，再按空格或 Esc 关闭。面板可调整大小，主窗口仍可操作；在列表中用上下方向键选择其他任务，面板跟随切换。也可用摘要中的“显示详情…”、工具栏按钮或 `⌥⌘I`。正在编辑输入框时，空格和方向键仍用于输入。详情包含概览、文件、网络和日志；已下载文件的“快速查看”使用 macOS 系统预览。

左侧导航栏保持显示，可拖动分隔线调整宽度，没有收起按钮。主窗口最小内容尺寸为 900 × 600 点；打开详情不会增加分栏或改变主窗口大小。底部窄状态栏始终从左侧栏右边缘延伸到窗口最右边，显示全部任务的进行中数量、已完成数量和总大小，不受筛选影响。

任务列表使用系统文件类型图标，依次显示名称、进度和传输状态；右侧保留暂停／继续，已完成任务可直接在 Finder 中显示。刷新位于工具栏的“更多操作”菜单，也可按 `⌘R`；移除任务位于右键菜单、“下载”菜单或详情面板。左下角显示下载／上传速度、近期速度曲线和可点击的引擎状态。

### 种子文件与 Finder

右键下载任务 → **在 Finder 中显示**（也可用“下载”菜单或 `⇧⌘R`）：普通单文件选中文件；BT 任务选中它的文件夹。文件详情中也可右键定位已落盘的文件。

新建的 Magnet／Torrent 任务使用独立文件夹，保留种子副本和种子原有的目录结构；已有任务不迁移文件。若 v2 磁力链只有元数据、还没有完整分片层，则保存可打开的磁力链快捷方式，避免生成无法重新添加的 `.torrent`。同名任务会创建不同文件夹。“移除下载”仍需明确选择是否将文件移到废纸篓，清除历史不会删除文件。

“已跳过”不会显示完成进度。BT v1 文件可能共用分片：引擎为所选文件缓存边界分片时，未选文件的字节计数也可能增加，甚至达到其大小；这不表示该文件已保存。已存在的旧文件不会因改为跳过而删除。详情中的优先级和做种选项需要点击“应用到此种子”后生效。

### Chrome 与 Edge

在设置 → 集成 → 浏览器集成中依次完成：开启接收、导出扩展、在浏览器中加载、复制配对码并在扩展中保存。扩展目前通过开发者模式加载，尚未在浏览器商店发布；不支持 Safari。导出的文件夹需要保留。

发送时保持 ChopChop 运行。连接不可达时，先打开应用，再检查接收开关；扩展无法从一次连接失败中自动区分这两个原因。配对被拒绝时重新复制配对码。“重置配对”会使此前所有配对码失效。每次导入都会在应用中等待确认。

### 两种更新

设置使用通用、下载、网络、BitTorrent、ED2K、集成和引擎七个一级分类。每个分类的选项在同一页面分组平铺，向下滚动即可查看；Tracker 来源和列表也直接在 BitTorrent 页面编辑，无需进入子页面。网络、BitTorrent 和 ED2K 的“应用设置”按钮固定在底部。

- **ChopChop 应用**：应用菜单 → 检查 ChopChop 更新…，或设置 → 通用。可关闭每日更新检查。发现新版本后，点击 GitHub 下载入口，退出应用并替换“应用程序”中的副本。任务、设置和引擎存放于应用之外，会保留。
- **Aria2 Next 引擎**：点击主窗口左下角整个引擎状态区域，进入引擎设置。可在应用内下载安装更新，并查看真实进度。

开发构建没有发布标签，只提供手动检查；正式构建只提示正式版，测试构建同时接受更新的测试版和正式版。检查失败不会影响已有下载。

### 通知、失败与反馈

下载完成通知默认关闭，需要时在设置 → 通用开启。网络暂时断开时仍可查看保存的任务，应用会自动重新连接。

“继续”保留同一个任务和断点。“编辑后重新添加”创建新任务；需要认证时请重新补充 Cookie 或 Authorization。不要将认证信息贴入公开反馈。

帮助 → ChopChop 帮助提供诊断预览和导出。报告只有版本、能力、任务数量和问题代码；不包含文件名称、链接、路径、认证或原始日志。应用不会自动上传报告。请自行检查后，在 [GitHub Issues](https://github.com/Conight/ChopChop/issues/new/choose) 描述复现步骤、预期与实际结果，并选择是否附上报告。

界面跟随 macOS 的应用语言，扩展跟随浏览器语言。支持简体中文和英语，其余语言回退英语。

## English

### Install and add your first download

Download the Apple Silicon DMG from [GitHub Releases](https://github.com/Conight/ChopChop/releases), then follow the [installation and checksum instructions](../README.md#install). These beta builds remain ad-hoc signed and are not notarized by Apple.

1. Move ChopChop to Applications and open it. Choose **Download and Start** to install Aria2 Next on first launch. ChopChop manages its location.
2. Choose **Paste Link** or **Open Torrent or Metalink…** in the empty list, or drag links and files into the window.
3. Review the destination and start options. Grant access to a custom folder through the system file chooser when needed.
4. Watch the task's progress, speed and errors. Restored downloads and BitTorrent seeding stay paused until you resume them.

Unknown-size downloads show transferred bytes. Media uses duration progress; metadata, verification and finalization have distinct states. Video downloads accept direct HLS/DASH manifests, not arbitrary video-site pages.

Click a task to expand its save location and common settings beneath the row. Only one summary opens at a time; use its native disclosure triangle to collapse it. While the engine is online, edit the task’s download limit and, for BitTorrent, upload limit, then choose **Apply**. Values use KiB/s. Zero removes the task limit; global limits still apply. Changing limits does not stop seeding or resume a paused task.

Select a task and press **Space** to open its separate, resizable **Download Details** panel; press Space again or Escape to close it. The main window remains available. Up/Down in the list selects another task and updates the panel. **Show Details…**, the toolbar button, and `⌥⌘I` are also available. Text fields keep their normal Space and arrow-key behavior. Details contains Overview, Files, Network, and Logs; **Quick Look** on a downloaded file uses the system file preview.

The left sidebar stays visible, with a draggable divider and no collapse button. The main window has a minimum content size of 900 × 600 points. Opening Details adds no column and leaves the main window’s size unchanged. The compact bottom status bar always spans from the sidebar’s right edge to the window’s right edge, showing active count, completed count, and total size across all tasks, independent of the current filter.

Rows use system file-type icons, followed by the name, progress and transfer status. Pause/Resume remains at the right; completed tasks offer Show in Finder. Refresh is in the toolbar's More Actions menu and remains available with `⌘R`. Remove Download is in the context menu, Downloads menu and Details panel. The lower-left sidebar shows download/upload speed, the recent speed graph and clickable Engine status.

### Torrent files and Finder

Right-click a task and choose **Show in Finder**, use the Downloads menu, or press `⇧⌘R`. A regular single-file task reveals the file; a torrent reveals its folder. Existing files also have a Finder action in their file-row context menu.

New Magnet/Torrent tasks get separate folders containing a torrent copy and the original content hierarchy. Existing tasks keep their paths. For v2 magnets without complete piece layers, a Finder magnet shortcut is saved instead of an unusable `.torrent`. Same-name tasks use separate folders. Clearing history keeps files; moving files to Trash remains an explicit removal choice.

Skipped files have no completion bar. BT v1 files can share pieces, so downloading a selected file can cache bytes belonging to a skipped neighbor without creating that file. Previously saved files are retained when skipped. File priorities and sharing options in Details take effect after **Apply to This Torrent**.

### 传输详情 / Transfer details

选择任务 → 按空格打开详情 → **网络 / Network**：

- BT 分片图包含整个种子的分片（也包括未选文件涉及的分片）。上方概览可点击定位，下方每页 256 片；悬停或键盘方向键查看编号、完成状态和大小。填充信息不完整的 v2/hybrid 种子显示单片大小上限。未上报和未完成使用不同样式；没有单片的部分完成百分比。
- 节点列表显示客户端、连接阶段、对方完成率和双向速度，可按地址、下载速度或上传速度排序。展开查看 TCP/uTP、入站/出站、加密、来源、已传输字节及上传通道状态。暂停后隐藏引擎缓存的旧连接和旧速度。
- **上传带宽**可即时设置当前 BT 任务的上传限速（KiB/s）。0 是不限速，不是关闭做种；全局和定时带宽限制仍然有效。做种比例／时间在“文件”的 BT 管理中配置。
- 普通下载显示实际连接数、服务器地址、服务器报告的速度，以及配置的连接上限。Aria2 Next 2.8.6 的 HTTP 后端将多个连接合并为一个服务器记录，不能展示每条 HTTP 连接的独立速度、字节范围或进度。

Live telemetry refreshes while the Network tab and window are active. The engine updates BT piece data about every five seconds, so the map may briefly lag file progress. Endpoint details stay in memory and are excluded from saved history and diagnostic exports; server paths, queries and credentials are not displayed. Media and ED2K retain their protocol-specific views.

### Chrome and Edge

Settings → Integrations → Browser Integration guides you through enabling reception, exporting the extension, loading it with your browser's Developer mode, and saving its pairing code. Keep the exported folder. The extension is not published to a browser store and does not support Safari.

Keep ChopChop running when sending links. If the extension cannot connect, open the app and enable receiving. A connection failure cannot reliably distinguish those two conditions. For rejected pairing, copy and save a fresh code. Reset Pairing revokes all previous codes. Every import waits for review in the app.

### Updates, notifications and feedback

Settings has seven top-level categories: General, Downloads, Network, BitTorrent, ED2K, Integrations and Engine. Each category contains grouped, scrollable controls on one page. Edit tracker sources and lists directly in BitTorrent, with no nested settings pages. Network, BitTorrent and ED2K keep Apply Settings at the bottom.

**App updates:** use ChopChop → Check ChopChop Updates… or Settings → General. Daily checks can be disabled. Download the DMG from the linked GitHub release, quit ChopChop, and replace the Applications copy. Existing tasks, settings and the engine are kept outside the app bundle.

**Engine updates:** click the Engine area in the lower-left sidebar to manage and update Aria2 Next inside ChopChop, with download progress.

Development builds require manual app-update checks. Stable builds check stable releases; beta builds also include newer prereleases. Checking failures do not stop downloads.

Completion notifications are opt-in in General settings. Saved history remains available while the engine reconnects. Resume keeps the same task and progress; Edit and Add Again creates a new task. Re-enter authentication if needed.

Help → ChopChop Help lets you preview and export diagnostics. The report contains versions, capabilities, task counts and issue codes, excluding names, URLs, paths, credentials and raw logs. Nothing is uploaded automatically. Review the report before optionally attaching it to a [GitHub issue](https://github.com/Conight/ChopChop/issues/new/choose), along with reproduction steps and expected/actual behavior.

The app follows the macOS app language, and the extension follows the browser language. Simplified Chinese and English are supported, with English as the fallback.
