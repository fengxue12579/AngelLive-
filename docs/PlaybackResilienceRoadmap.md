# 播放链路韧性改进路线图

> 状态:草案 v2 · 2026-05-28
> 范围:三端(iOS / macOS / tvOS)直播播放链路
> 目标:把"弱网误判 stall / 用户无感知 / CDN 起播没记忆 / 调参没工具"四类痛点收一收

---

## 0. 现状盘点

### 0.1 已落地

| 改动 | 文件 | 解决 |
|---|---|---|
| HLS 默认走 KSAVPlayer,KSMEPlayer 兜底 | `RoomPlaybackResolver.swift` | 部分 m3u8 直播流 KSME/FFmpeg 解析卡第一帧 |
| Startup watchdog 加 bytes 进度门 + 12s | `RoomPlayerView` / `PlayerContainerView` / `DetailPlayerView` | 弱网下"还在缓冲就被 refresh kill"的死循环 |
| URLCache 清缓存后强制刷计数 | `CacheMaintenanceService.swift` | 设置页第一次点清缓存大小不变 |
| 远程输入事件 id 化 + `.config` 合并 | `RemoteInputService.swift` 等 4 处 | 标题+URL 一起提交丢 URL / 同 URL 重复提交不触发 |

### 0.2 当前韧性栈

```
┌──────────────────────────────────────────┐
│  View 层:Startup Watchdog                │  ← 起播 12s 超时 + bytes 进度门 (三端 View 各一份)
├──────────────────────────────────────────┤
│  ViewModel 层:Stall Watchdog             │  ← 1Hz 采样 bytes+playhead,8s 触发 CDN failover/refresh
├──────────────────────────────────────────┤
│  FFmpeg 层:KSOptions.rw_timeout (9s)     │  ← I/O 级握手超时,走 .failed 错误路径
└──────────────────────────────────────────┘
+ Managed retry: maxPlaybackRetries=3 / 60s 窗口共享预算
+ Bugsnag + PluginConsoleService:已记 stall/managed retry 事件
```

三端 ViewModel(iOS 1084 / macOS 1063 / tvOS 1062 行)各自维护这些 watchdog,字段名一致但代码独立;View 层的 startup watchdog 同理。

---

## 1. 计划改动

本轮**只做 4 项**,理由见 §3。

### ① Stall watchdog 加指数退避

**问题**
`stallThresholdSeconds = 8s` 触发 → CDN failover。弱网下 8s 零吞吐其实很常见:
- TCP RTT 高时 FFmpeg av_read_frame 自然空窗
- KSPlayer 缓冲打满(`loadedTime > maxBufferDuration`)→ `MEPlayerItem.send(.pause)` → bytesRead 不动(已被 `stallPlayheadProgressTolerance` 覆盖)
- 服务端 keep-alive 心跳期

→ 容易把"慢但正常"误判成 stall,浪费 CDN 切换预算。

**改动**
```swift
// 退避序列与 maxPlaybackRetries=3 对齐
public static let stallBackoffSeconds: [Int] = [8, 16, 32]

let threshold = stallBackoffSeconds[
    min(playbackRetryAttempts, stallBackoffSeconds.count - 1)
]
if stallNoChangeTicks >= threshold { ... }
```

**已知行为(写入文档,不算 bug)**
- `playbackRetryWindowStart` 在 60s 窗口外被清零(`RoomInfoViewModel.swift:978-982`)。**这意味着退避也会被重置回 8s**。
- 直播持续 1 小时,经历 6 次零散卡顿(每次相隔 > 60s)时,每次都从 8s 起,而不是退到 32s 不动。
- 这是想要的:避免持久退避把"偶发卡顿"也搞慢。

**预算**:`maxPlaybackRetries=3 / 60s` 不变。
**风险**:CDN 真死时第二次切换从 8s → 16s,首次切换不变。
**触点**:三端 `RoomInfoViewModel.swift:77`(常量)、`:965`(判定)。

---

### ② 加载状态文字反馈(PlaybackPhase 状态机)

**问题**
现在 loading overlay = 转圈 + "加载中"一句。watchdog 触发 refresh / CDN 切换时用户无感知 → 体感是"卡了又自动好了",或者"卡了越来越久"(看不到补救动作)。

**改动**
1. ViewModel 暴露 `playbackPhase: PlaybackPhase` 状态机:
   ```swift
   public enum PlaybackPhase: Sendable {
       case idle
       case fetchingPlayArgs     // 拉播放地址中
       case connecting           // URL 已下发,等首字节
       case bufferingFirstFrame  // 收到字节但 player 还没进 readyToPlay
       case playing
       case error(message: String)
   }

   // 一次性事件(toast 用),与 phase 解耦,Observable 双写
   public enum PlaybackRecoveryEvent: Sendable {
       case switchingCDN(from: String, to: String, attempt: Int, max: Int)
       case retrying(attempt: Int, max: Int)
   }
   ```

2. View 层把 `phase` 渲染成具体文字 + 副标题:
   - "连接中 · 服务器响应慢..."
   - "重新加载 · 当前线路无响应"

3. CDN failover / managed retry 触发时,**复用现有 `attemptStallRecovery` / `attemptManagedPlaybackRetry` 里的 `PluginConsoleService.log()` 调用点**(`RoomInfoViewModel.swift:1037` / `:813`)旁边发 `recoveryEvent`,View 用 `.onChange` 弹 toast 1.5s:
   - "网络较慢,正在切换线路 (1/3)"

**过渡策略**
现有字段(`isLoading`/`playError`/`playErrorMessage`/`isFetchingPlayURL`)做成 `phase` 的 computed,先让 View 不用改;视图层后续逐个迁移读 `phase`。

**收益**:用户感觉系统在主动处理,不是"卡死"。客服反馈类问题应该会少。

**触点**:三端 VM 顶部状态字段、`StreamLoadingOverlay` 文案、`attemptStallRecovery`/`attemptManagedPlaybackRetry` 各发一次 event。

---

### ⑤ CDN 偏好学习

**问题**
进直播间永远从 `CDN[0]` 起,平台返回顺序未必反映用户当前的可达性。

**改动**
1. 新建 `CDNPreferenceStore`(`AngelLiveCore/Playback/CDNPreferenceStore.swift`,纯 `UserDefaults` 持久化):
   ```swift
   public struct CDNObservation: Codable, Sendable {
       var startupAttempts: Int
       var startupSuccesses: Int
       var avgFirstFrameMillis: Double
       var lastSuccessAt: Date?
   }

   // key: "\(liveType.rawValue):\(cdnHost)"
   public actor CDNPreferenceStore {
       public static let shared = CDNPreferenceStore()
       public func reorder(_ playArgs: [LiveQualityModel], for liveType: LiveType) -> [LiveQualityModel]
       public func recordSuccess(host: String, liveType: LiveType, firstFrameMs: Double)
       public func recordFailure(host: String, liveType: LiveType)
   }
   ```

2. 切入点:`updateCurrentRoomPlayArgs(_:)` `RoomInfoViewModel.swift:160` —
   ```swift
   self.currentRoomPlayArgs = await CDNPreferenceStore.shared
       .reorder(playArgs, for: currentRoom.liveType)
   ```

3. 评分:
   ```swift
   score = success_rate * 0.7 + (1 / max(avg_first_frame_ms, 500)) * 0.3
   ```
   样本 < 3 时按平台原顺序走,不动。

4. 观测信号(三端 VM 已有的回调里挂):
   - 成功:`KSPlayerLayerDelegate` 收到 `.readyToPlay`,记 first-frame 时长
   - 失败:`attemptStallRecovery` 触发 / `attemptManagedPlaybackRetry` 触发 / `playError` 非 nil

5. 数据有效期:`validityWindow = 7 days`,过期清掉(用户换网络环境历史数据失效)。

**已确认的边界**
- 用户手动 `changePlayUrl(cdnIndex:urlIndex:)` 不影响重排,仍按用户意图走 — 重排只发生在 `updateCurrentRoomPlayArgs` 这一次
- `nextCdnIndex()` 走 `(currentCdnIndex + 1) % args.count`,重排后逻辑仍正确
- UI 上展示的 CDN 标识用 `cdn.displayName` 或 `cdn.cdn`(host),不依赖 index,重排无副作用

**风险**:冷启动期数据稀疏 → 阈值过滤(样本 < 3 用原顺序)。
**位置**:`Shared/AngelLiveCore/Sources/AngelLiveCore/Playback/CDNPreferenceStore.swift`。

---

### ⑨ DevConsole 加 PlaybackTimeline

**思路**
DevConsole 已经有日志流(`PluginConsoleService.entries`)。补一个时间轴视图:
- 横轴:时间(进入直播间到现在)
- 纵轴:事件类型(URL set / state change / watchdog tick / refresh / CDN switch / Managed retry / Error)
- 点击事件展开详情

**实现选择(已比对)**
不复用 `PluginConsoleEntry`:它的语义是"插件 HTTP 请求",字段(url/method/headers/statusCode/HTTP 子请求)和播放事件不重叠。强塞需要把字段当 stringly-typed 用,后续扩展难看。

→ 新建 `PlaybackEventLog`(`AngelLiveCore/Playback/PlaybackEventLog.swift`):
```swift
public enum PlaybackEvent: Sendable {
    case urlChanged(URL)
    case stateChanged(KSPlayerState)
    case watchdogTick(bytesRead: Int64, playhead: TimeInterval)
    case stallTriggered(threshold: Int, attempt: Int)
    case cdnSwitch(from: Int, to: Int, reason: String)
    case managedRetry(attempt: Int, error: String)
    case errorReported(String)
    case recoveryBudgetExhausted
}

@Observable
public final class PlaybackEventLog {
    public static let shared = PlaybackEventLog()
    public private(set) var events: [(Date, PlaybackEvent)] = []  // 环形,cap=500
    public func record(_ event: PlaybackEvent)
    public func snapshot() -> [(Date, PlaybackEvent)]  // 导出 JSON 用
}
```

**双写策略**:`attemptStallRecovery` / `attemptManagedPlaybackRetry` 现有的 `PluginConsoleService.log()` 调用保留(后端日志可读),旁边加 `PlaybackEventLog.shared.record(...)`。新事件类型(URL set / state change)只往 PlaybackEventLog 写。

**视图**:`Shared/AngelLiveCore/.../DevConsole/PlaybackTimelineView.swift`,DevConsole 主界面加一个 tab。

**收益**
- 调参直接看曲线(stall 触发时 bytes/playhead 历史)
- 用户上报问题一键导出 timeline JSON(`PlaybackEventLog.shared.snapshot()`)
- DogFooding 价值大

**风险**:低,纯加性。

---

## 2. 通用基础 · Playback 命名空间(共享层)

`①②` 都要在三端 VM 各改一份。**不做 ⑥**(actor controller),但抽常量和纯类型,降低漂移。

**新建** `Shared/AngelLiveCore/Sources/AngelLiveCore/Playback/PlaybackTuning.swift`:
```swift
public enum PlaybackTuning {
    public static let stallBackoffSeconds: [Int] = [8, 16, 32]
    public static let stallPlayheadProgressTolerance: TimeInterval = 0.5
    public static let stallWatchdogTickNanos: UInt64 = 1_000_000_000
    public static let maxPlaybackRetries = 3
    public static let playbackRetryWindow: TimeInterval = 60
    public static let startupWatchdogTimeoutSeconds: TimeInterval = 12
    public static let startupWatchdogBytesProgressThreshold: Int64 = 16 * 1024

    public static func stallThreshold(for attempt: Int) -> Int {
        stallBackoffSeconds[min(attempt, stallBackoffSeconds.count - 1)]
    }
}
```

VM 和 View 各端读这里,三端 VM 内部仍保留各自的 `playbackRetryAttempts`/`stallNoChangeTicks` 状态(状态不抽,只抽配置)。

**收益**:① 改完后,三端 stall 阈值改动只动一处;startup watchdog 三端 View 同理。
**风险**:零(纯常量重定位)。
**估时**:0.5 天。

不是 ⑥ 那种 actor + protocol 的大手术,**只是把"应该 share 的常量"实际 share 一份**。

---

## 3. 不做的 5 项(放弃理由)

| 项 | 放弃理由 |
|---|---|
| ③ 失败前先降清晰度 | `LiveQualityModel` 缺 quality 排序规范(qn 数值跨平台不一致),前置工作量大;且"流畅 vs 高清"是用户偏好,不该 silent 改 |
| ④ 内核选择记忆 + 平台白名单 | `PlatformCapability` 语义是"插件能力探测",塞内核偏好会污染语义;现 KSAV/KSME fallback 链路已工作良好,ROI 不足 |
| ⑥ 三个 watchdog 合并成 Controller | 三端 VM diff 不只 watchdog(PlayerKernel/UA/弹幕设置等都差),抽 protocol 适配成本大于去重收益;§2 的最小共享层已经覆盖主要痛点 |
| ⑦ 网络质量探针 | 大多数直播 CDN 不允许 HEAD;64KB 探针在弱网下慢,跟实际起播差距小;不如 ⑤ 学历史数据 |
| ⑧ playArgs 预热 | 直播 token 有时效(30-300s 不等),缓存窗口窄;tvOS focus 收益大但仅一端,iOS long-press 与 Context Menu 冲突 |

---

## 4. 落地顺序

| # | 项 | 估时 | 前置 |
|---|---|---|---|
| 0 | §2 `PlaybackTuning` 命名空间 | 0.5d | - |
| 1 | ① stall 退避 | 0.5d | 0 |
| 2 | ⑨ `PlaybackEventLog` + Timeline View | 1.5d | 0 |
| 3 | ② `PlaybackPhase` + recoveryEvent | 1.5d | 1, 2 |
| 4 | ⑤ `CDNPreferenceStore` + 接入 | 2d | 2(借时间轴验证) |

**为什么 ⑨ 排前面**:① 和 ⑤ 都需要看数据调参,先把时间轴落了,后面调参不用瞎调。⑤ 上线后用 timeline 验证"重排是否真的命中常用 CDN"也方便。

**总估时**:约 1 周(单人)。

---

## 5. 度量

| 指标 | 含义 | 期望方向 | 数据源 |
|---|---|---|---|
| `time_to_first_frame_ms` | URL set 到 isPlaying=true 的耗时 | 下降 | PlaybackEventLog |
| `watchdog_refresh_count_per_session` | 单场观看里 startup watchdog 触发 refresh 的次数 | 下降至 0-1 | PlaybackEventLog |
| `stall_recovery_count_per_session` | 单场观看里 stall watchdog 触发 CDN/refresh 的次数 | 下降(随 ①) | PlaybackEventLog |
| `cdn_failover_success_rate` | failover 后 5s 内起播成功的比例 | 上升 | PlaybackEventLog + Bugsnag breadcrumb |
| `cdn_first_choice_hit_rate` | 进直播间用 `CDN[0]`(重排后)5s 内起播的比例 | 上升(随 ⑤) | PlaybackEventLog |
| `playback_abandon_rate` | 进入详情页但 30s 内未起播就退出的比例 | 下降 | 需新埋点(进入/退出回调) |

前 5 个由 ⑨ 完成后自动可查;最后一个需要在 `RoomInfoView.onDisappear` 加一行埋点。

---

## 6. 不在此规划内

- 播放器 UI 重设计(控制栏 / 弹幕 / 设置面板)
- 音频独立模式(audio-only fallback)
- 全屏 / PiP / AirPlay 现有问题
- 弹幕通道稳定性
- 三端 VM 整体合并(见 ⑥ 放弃理由)
