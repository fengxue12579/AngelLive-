# 同步重构:错误可见性 → 本地存储 → 新同步

> 状态:设计 v2 · 2026-06-03
> 范围:三端(iOS / macOS / tvOS)的 收藏 / 登录凭证 / 订阅源 三个同步域
> 决策来源(本轮对齐):
> 1. **核心需求是「结果可见」** —— 每个操作在页面上明确告知成功与否;失败要给**具体原因 + 错误码**(iCloud 满了?网络错了?未登录?)。
> 2. 分三步走,**顺序固定**:① 错误信息 → ② 本地存储(让 iCloud 同步变可选)→ ③ 新同步(CKSyncEngine)。
> 3. 不强求三域用同一套同步引擎;**「统一」只体现在错误展示这一层**。

---

## 实施进度(截至 2026-06-03)

| Phase | 范围 | 状态 | Commit |
|---|---|---|---|
| ① 错误可见性层 | 收藏/凭证/订阅源 · iOS/macOS/tvOS | ✅ 已完成并验证(三端 build) | `58d2703` |
| ② 本地存储 + iCloud 可选 | 收藏 · iOS/macOS | ✅ 已完成(本地优先/union/开关) | `40fb7ee` |
| ③ CKSyncEngine | 收藏 · iOS/macOS | ⚠ 代码完成;真机验证发现「拉取闸」bug 已修(见下),待复验 | `6bcc409` 引擎核心 / `b8d9156` 接线 / fetch 闸修复(未提交) |
| ③+ 推送 | 收藏实时(CKSubscription 静默推送) | ⏳ 计划中(2026-06-04 测) | — |
| ② / ③ | TV 收藏(独立 AppFavoriteModel) | ⏳ 未做 | 任务 #6 |
| ③ | 凭证/订阅源 手动+重试退避 | ⏳ 未做 | — |

### ⚠ Phase③ 真机验证清单(同一 iCloud 账号、两台设备)

1. A 加收藏 → B 是否出现;A 删除 → B 是否消失。
2. 杀进程重启 → 未传完的增删是否续传(CKSyncEngine 落盘队列)。
3. 首次更新 → 旧默认 Zone 收藏是否迁入(`FavoriteSyncEngine.migrateFromDefaultZoneIfNeeded`)。
4. CloudKit 控制台确认自定义 Zone `FavoritesZone` 是否建出(**不确定点①**)。
5. 反复增删同一主播 → 是否出现 `serverRecordChanged`(**不确定点②**,预计极少)。
6. 关闭「收藏 iCloud 同步」开关 → 是否纯本地、完全不碰 CloudKit。

两个不确定点在 `FavoriteSyncEngine.swift` 的 `start()` 与 `makeRecord` 处有注释标注,便于按验证结果调整。

> 注意:Phase③ 把收藏的 iCloud 路径从默认 Zone 切到自定义 Zone(迁移即切换)。灰度期旧版本设备仍读写默认 Zone,与新版自定义 Zone 互不可见,各自更新后合并。

### 真机验证发现与修复(2026-06-03)

**现象**:对端的增/删拉不到(Mac 删 → iOS 仍在;冷启动仍在),一度误判为「删除同步坏」「迁移复活」「搜索只出直播」。逐项排除后定位到真因。

**逐层结论**:
- 删除发送(`enqueueDelete` → `nextRecordZoneChangeBatch`;删除自动入批、不经 `recordProvider`)与 `applyFetched` 删除应用(按 `recordName == uniqueKey` 匹配)**均正确**。
- 「搜索只出直播」是**误判**:`FavoriteView` 搜索按 `userName`/`roomTitle` 过滤 `groupedRoomList`,不限直播状态;非直播收藏在列表、名字正常、可搜到。(附带发现:部分非直播主播落「未知状态」= 该条直播状态刷新接口失败的兜底,属刷新可靠性,另议。)
- **真因**:iOS 的 `fetchChanges()` 被 `cloudKitReady` 预检挡住(`AppFavoriteModel.syncWithActor` / `pullToRefresh`)。该账号预检在分流/代理网络下**瞬时假阴性**,一旦 false,拉取被**静默跳过** → 对端增删永远拉不到。
- 叠加:**全工程无任何 CKSubscription 推送**,对端只能靠主动拉取,本就非实时 → 表现为「延迟/怎么刷都不动」。
- 不对称根源:发送侧不设防(`addFavorite` 无条件 `enqueueSave`),拉取侧被闸挡 → 「发得出、收不回」。

**已修(待提交)**:`syncWithActor` / `pullToRefresh` 去掉 `if cloudKitReady` 包裹,改为无条件 `await FavoriteSyncEngine.shared.fetchChanges()`(引擎自带退避/错误处理;`cloudKitReady` 仅留作 UI 状态展示)。iOS + macOS 均 BUILD SUCCEEDED,待真机复验上方清单第 1、2 条。

**仍潜伏(未修)**:老收藏因默认 Zone 迁移**跨设备复活** —— 默认 Zone 旧记录永不清理 + 迁移按设备独立只跑一次,删除老收藏后尚未迁移的设备会把它读回并 re-save。本次症状是全新主播(从未进默认 Zone),故与此无关;隐患仍在,倾向方案 C(删老收藏时同删默认 Zone 那条 + **持久重试**,因 `FavoriteService.deleteRecord` 一次性无退避)。

**下一步(计划 2026-06-04 测)**:加 CKSubscription **静默推送**做到「开着就实时」。静默推送(content-available)**无需用户授权、不弹框**,仅需 Push 能力 + Remote notifications 后台模式 + `registerForRemoteNotifications()`;App 被杀场景由启动拉取兜底,无需推送。

---

## 0. 现状盘点

### 0.1 数据与传输

| 域 | 本地持久化 | 云端 | 状态/错误出口 |
|---|---|---|---|
| 收藏 | ❌ **无**(`AppFavoriteModel.roomList` 是内存数组,启动从 CloudKit 拉) | CloudKit privateDB,手动 save/fetch | `FavoriteService` 有 `syncStatus`/`getCloudState`/`formatErrorCode`,但未带错误码、加删收藏未用上 |
| 登录凭证 | ✅ 本机已有登录态 | CloudKit + Bonjour | ❌ 无 error 出口(失败仅 `Logger.warning`) |
| 订阅源 | UserDefaults 级 | CloudKit 单记录 | ❌ 无 |

### 0.2 三个必须修掉的问题

1. **UI 假报成功**:`syncAllToICloud()` 是 `async -> Void`,内部把每条失败咽成 `Logger.warning`(`PlatformCredentialSyncService.swift:203`),`SyncView` 之后无条件写「已同步到 iCloud」(`SyncView.swift:78`)。
2. **收藏「云端=唯一真相」**:iCloud 拉不到(分流环境)≈ 收藏空白;**单设备用户也被迫走 iCloud**。
3. **错误能力没用全**:`FavoriteService.formatErrorCode`(`:197`)已有完整的 CKError→人话映射,但 ① 不带错误码数字 ② 加/删收藏没用它 ③ 凭证/订阅源两域完全没有。

### 0.3 根因复盘(为什么同步会失败)

CloudKit 本身稳定;坏在**大量 iPhone 用户装了分流/代理工具**(`NEPacketTunnelProvider` 类),把发往 iCloud 的连接路由乱了 → 瞬时、可恢复的网络错误。结论:这类错误**该明确告诉用户、该能重试**,而不是静默丢失。

---

## 1. 三阶段总览

| Phase | 目标 | 依赖引擎? | 让谁受益 |
|---|---|---|---|
| **① 错误可见性层** | 每个操作上报「成功 / 失败(原因+码)」,三端展示;三域统一 `SyncError` | ❌ 引擎无关,基于现有手动同步 | 所有用户立刻看得懂发生了什么 |
| **② 本地存储 + iCloud 可选** | 本地为真相;新增「是否启用 iCloud 同步」开关 | ❌ 不依赖新引擎 | 单设备用户纯本地、不碰 iCloud;分流环境离线可用 |
| **③ 新同步(CKSyncEngine)** | 在本地层之上加 opt-in 云端同步:增量/续传/退避 | ✅ CKSyncEngine | 多设备用户可靠同步 |

**为什么是这个顺序**:① 不碰架构、当天见效;② 的「本地为真相」**正好是 ③ CKSyncEngine 的前置要求**,所以 ② 不是绕路,是给 ③ 打地基,顺带解决「单设备用户被迫用 iCloud」。

---

## 2. Phase ① — 错误可见性层(引擎无关,先做)

### 2.1 `SyncError`(`AngelLiveCore/Services/Sync/SyncError.swift`)

把 `FavoriteService.formatErrorCode` 升级成结构化、带码、三域共享的类型。**人话优先,且必须带错误码**(用户明确要)。

```swift
public struct SyncError: Error, Sendable, Equatable {
    public let code: Int          // CKError.Code.rawValue —— 页面要显示的「错误码」
    public let kind: Kind
    public let title: String      // 人话:"iCloud 空间已满"
    public let advice: String?    // 可操作建议
    public let rawDescription: String  // 原始描述,折叠展示/上报用

    public enum Kind: Sendable {
        case notSignedIn, iCloudRestricted, networkBlocked
        case rateLimited(retryAfter: TimeInterval?)
        case quotaExceeded, serverChanged, partialFailure(failed: Int, total: Int)
        case unknown
    }

    public static func from(_ error: Error) -> SyncError   // CKError → SyncError 集中映射
}
```

**映射表**(迁移并扩展现有 `formatErrorCode`,补上 `code` 数字):

| CKError(code) | title / advice |
|---|---|
| `networkUnavailable`(3) / `networkFailure`(4) / `serviceUnavailable`(6) | 「iCloud 连接失败」/「若使用了加速或分流工具,请确认已放行 *.icloud.com,或临时关闭后重试」 |
| `notAuthenticated`(9) | 「未登录 iCloud」/「请前往 系统设置 > Apple 账户 登录后重试」 |
| `quotaExceeded`(25) | 「iCloud 空间已满」/「请清理 iCloud 存储后重试」 |
| `requestRateLimited`(7) / `zoneBusy` | 「iCloud 繁忙」/「将在 N 秒后自动重试」(N 来自 `CKErrorRetryAfterKey`) |
| `serverRecordChanged` | 「云端数据已更新,请刷新」 |
| 其他 | 「同步失败(错误码 \(code))」/ 原始描述折叠 |

### 2.2 每个操作上报结果

```swift
public enum OperationOutcome: Sendable {
    case success
    case failure(SyncError)
    case partial(SyncError)   // 批量里部分失败
}
```

- `syncAllToICloud / FromICloud` 改为返回 `OperationOutcome`(不再 `Void`),内部**收集**每条失败而非只 warning。
- 加/删收藏(`addFavorite`/`removeFavoriteRoom`,现 `async throws`):失败抛 `SyncError`,调用方 catch 后展示「失败:title(错误码 code)」;成功展示「已收藏 ✓ / 已取消收藏 ✓」。
- iCloud 连接状态:`getCloudState()` 收敛到返回 `SyncError?`,页面显示具体错误 + 码。

### 2.3 页面文案(三端共用 `SyncError`,改文案改一处)

- 连 iCloud 失败 →「iCloud 连接失败:网络不可用(错误码 3)。若使用了分流工具,请放行 *.icloud.com 后重试」
- 加收藏失败 →「收藏失败:iCloud 空间已满(错误码 25)」
- 加收藏成功 →「已收藏 ✓」
- 订阅源 / 凭证同步 → 复用同一 `SyncError`,展示一致

### 2.4 触点

**新增**:`AngelLiveCore/Services/Sync/SyncError.swift`、`SyncOutcome.swift`
**改动**:
- `FavoriteService.swift` — `formatErrorCode`→`SyncError`;`saveRecord`/`deleteRecord`/`getCloudState` 走 `SyncError`
- `PlatformCredentialSyncService.swift` / `PluginSourceSyncService.swift` — `syncAll*` 返回 `OperationOutcome`;新增 `@Published lastError: SyncError?`
- 三端:`SyncView.swift` / `MacSyncManagementView.swift` / `AccountManagementView.swift` + 加/删收藏各调用点(`LiveRoomCard`/`StreamerInfoView`/`VerticalLiveControllerView`/各 VC,三端约 54 处引用中涉及加删的部分)
- 复用 iOS `Common/Components/ErrorView.swift` / tvOS `Error/ErrorView.swift` 做统一展示

> Phase ① 在**现有手动同步**上完成,不依赖 ②③。

---

## 3. Phase ② — 本地存储(真相)+ iCloud 可选

### 3.1 本地为真相

- 收藏新增本地持久化(`LiveModel` 是 Codable,落 JSON 文件或 GRDB 表均可,**不动 `LiveModel` 本身**)。
- 读路径反转:启动/进入页面**先读本地**(秒回),不再等 CloudKit。
- 写路径:加/删先写本地(立即成功),云端同步是其后的事。

### 3.2 「是否启用 iCloud 同步」开关

- 新增 app 设置项(默认可开)。**关掉 = 纯本地**,完全不碰 iCloud —— 服务于「只有一台 iPhone」的用户。
- 开关为「关」时:加/删收藏的成功判定只看本地(必然成功);iCloud 状态卡隐藏或显示「已关闭」。
- 开关为「开」时:沿用 Phase ① 的错误展示;同步失败不影响本地操作已成功这一事实。

### 3.3 各域本地存储

| 域 | 本地存储 | 备注 |
|---|---|---|
| 收藏 | 新增 JSON / GRDB 落盘 | 当前完全没有,这是 ② 的主体工作 |
| 凭证 | 现有本机登录态(Keychain 等) | 已是本地;② 主要是给它接 iCloud 开关 |
| 订阅源 | UserDefaults / 文件 | 已基本本地;同上 |

- **tvOS 注意**:tvOS 无 Documents、只有可被系统清理的 `Caches`。所以 tvOS 上本地存储是 best-effort 快取(可能被清→重新拉),iCloud 仍是该端的 durable 兜底。**不构成阻塞**,与现状一致。

### 3.4 这一步是 ③ 的地基

CKSyncEngine 要求「本地存储当真相 + 引擎只做本地↔云搬运」。Phase ② 把本地真相建起来后,③ 接入近乎自然。

---

## 4. Phase ③ — 新同步(CKSyncEngine,opt-in)

按域选「最小够用」,**不强求统一引擎**:

| 域 | 同步方案 | 理由 |
|---|---|---|
| 收藏 | **CKSyncEngine + 自定义 Zone** | 多记录、会增删、要本地缓存与增量/续传 —— 唯一值回 ceremony 的域 |
| 凭证 | 保留手动 save/fetch + Phase ① 的 `SyncError` + 重试退避(读 retryAfter) | 几条小记录,杀鸡不用牛刀;是否改自动**待定** |
| 订阅源 | 同凭证,手动 + 错误模型 | 单记录;是否改自动**待定** |

CKSyncEngine 内置:持久 sync state、退避、读 `CKErrorRetryAfterKey`、增量拉取、断点续传 —— 正对分流痛点。错误仍通过 event 映射到 Phase ① 的 `SyncError` 展示。

一次性迁移:收藏现有默认 zone 记录 → 自定义 zone(凭证服务已有 `migrateLegacyCloudRecords` 先例)。

> 「凭证/订阅源是否也改成自动」由后续决定 —— 改与不改都复用同一套 `SyncError`,Phase ① 不白做。

---

## 5. 落地顺序与估时

| # | 项 | Phase | 估时 |
|---|---|---|---|
| 1 | `SyncError` + `OperationOutcome` + CKError 映射(迁移 formatErrorCode,补错误码) | ① | 0.5d |
| 2 | 收藏 加/删/状态 真实上报 + iOS 三端展示位 | ① | 1d |
| 3 | 凭证/订阅源接 `SyncError` + 干掉「假报成功」 | ① | 1d |
| 4 | 收藏本地存储(JSON/GRDB)+ 读写路径反转 | ② | 1.5d |
| 5 | 「启用 iCloud 同步」开关 + 三端接线 | ② | 1d |
| 6 | 收藏 CKSyncEngine + 自定义 Zone + 迁移 | ③ | 3d |
| 7 | 凭证/订阅源手动同步加重试退避 | ③ | 1d |

**Phase ① ≈ 2.5d(立刻满足「结果可见」需求);② ≈ 2.5d;③ ≈ 4d。**

---

## 6. 与既有文档的关系

- 本文档不涉及播放链路(见 `PlaybackResilienceRoadmap.md`)。
- `docs/CredentialRefactorPhase2.md` 当前为空;凭证同步后续以本文档 Phase ②③ 为准。
- 自建 E2E 同步 / 三重保险(本地+iCloud+局域网编排)不在本三阶段内,留待 CKSyncEngine 稳定后评估。
