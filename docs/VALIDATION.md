# 验证记录

日期：2026-10-25（RC1 构建与安装物验证）；2026-10-26（主分支源码与测试验证）。此文件区分已验证与仍待验证的边界。

## 2026-10-26：当前主分支（PR1–7 已合入）

`main`（`5574ba5`）包含 PR1–7；PR7 分支头部 `1ad2d33` 与压缩提交 `5574ba5` 内容一致。自动化测试共 46 项 XCTest：PauseCore 21 项（Decision 16 + Archive 5），Pause 25 项（Cloud 契约 3 + SessionEngine 17 + ContextDwell 5）。

- [PR7 分支头部 CI](https://github.com/geraldpeng6/interval-mac/actions/runs/40222770898)（头部 `1ad2d33`）通过全部 46 项；此前的 [PR6 CI](https://github.com/geraldpeng6/interval-mac/actions/runs/40222161841)、[PR5 CI](https://github.com/geraldpeng6/interval-mac/actions/runs/40219974828) 同样通过。
- 2026-10-26 本机另以隔离进程独立复跑全部 46 项，0 失败。
- 本轮修复要点（可在源码核对）：
  - 护眼记分要求屏幕不可用满 20 秒；不可用满 300 秒（锁屏/睡眠等）会清零连续屏幕时长并重置暴露与近期打字峰值，空闲满 300 秒走同样的重置路径。这是记分重置行为，不代表休息或锻炼完成（`Sources/PauseCore/DecisionEngine.swift`）。
  - 云端 200 响应体不符合约定信封或 allow/defer 取值时，解码器抛出类型化的 `invalidResponse` 并回退本地判断（`Sources/Pause/CloudAdvisor.swift`；源码注释把截断传输列入此类情形）。
  - 用户主动暂停优先于屏幕丢失与计时间隙，自动暂停在屏幕恢复后自行解除（`Sources/Pause/SessionEngine.swift`）；重复“开始一组活动”由 `Sources/Pause/AppStore.swift` 的 `startSession()` 会话状态守卫阻止，RootView 仅把按钮置为 disabled。
  - “清除数据”先取消在途云端咨询，再删除钥匙串 Key 与本地数据文件，全部删除成功后才重置偏好、历史、监测与会话（`Sources/Pause/AppStore.swift` 的 `eraseData()`）。任一删除失败会保留偏好与统计，但取消已发生、Key 可能已删除；不同资源之间没有原子回滚。此顺序只有静态审查，没有注入真实钥匙串失败的运行时回归。
  - 情境停留计时在停止监测、锁屏、睡眠或采样间隔超过 30 秒时归零，返回后从 0 重新累计（`Sources/Pause/ContextDwell.swift`）。
  - 1 秒间隔、0.2 秒容差的计时器加入 `.common` 模式，菜单追踪期间会话计时与监测采样继续（`Sources/Pause/AppStore.swift`）。
- 覆盖方式：ContextDwell（纯停留追踪器）与 SessionEngine（会话时钟模型）是两个相互独立、均有 XCTest 覆盖的模型；Sensors 与 AppStore 的通知/菜单/钥匙串接线仅静态审查，不是端到端验证。Foundation 合成探针（200 毫秒内默认模式约 0 次、common 模式约 10 次）只验证平台调度语义，不是菜单端到端测试。

## 仍未验证（截至 2026-10-26）

以下路径在本轮范围内没有实际执行：

- 原生窗口与菜单栏：未完成窗口视觉验收、按钮与菜单栏交互、完整活动计时、关闭窗口后恢复、重启持久化。
- 系统权限与输入事件：输入监控需用户在 macOS 系统设置单独授权；真实键盘事件尚未端到端验证。会议/影音分类与麦克风状态需要真实使用场景抽查，单元测试只证明给定信号下的决策逻辑。
- 云端与网络：未填写用户的云端 HTTPS 模型和 Key，未进行真实供应商在线请求。云端响应/安全地址契约已测，网络失败回退本地结果。
- 主分支修复未随任何已发布的安装物分发（见下方 RC1 历史记录）。

## 历史记录：2026-10-25 RC1 自动化与本地构建

以下为 RC1（`a1d1add`）时的验证快照，测试计数与部分行为已被主分支后续开发取代。

本机为 Apple Silicon arm64，Xcode 工具链 Swift 6.4。`./scripts/check.sh` 当时共 17 项 XCTest 测试通过，0 失败（PauseCore 15 项，云端契约 2 项）。

覆盖契约：

- 输入间隙与持续输入；手动/自动会议、影音、全屏和输入设备保护。
- 禁用分类、提醒冷却、稍后、跨午夜安静时段及禁用动作。
- 近期高输入负荷影响手腕提醒；完成单动作只清相关暴露。
- 休眠/长时间缺席不增加使用时长。
- 显式学习模式与持续分心；用户分类覆盖；每日目标影响时机。
- 真实磁盘原子保存、30 天保留、0600 权限、损坏文件保持不变。
- 配置边界与顺序；系统时区切换保留当天统计；新偏好字段缺失时兼容旧记录。
- HTTPS 地址验证、URL 凭据/参数拒绝、云服务响应只能为 allow/defer。

时区缺陷的回归测试在修复前丢失 3 次活动和 3,600 秒，断言失败；改为稳定的 `YYYY-MM-DD` 日标识后通过。此前审查还定位到提醒会因鼠标移动而消失的问题，现仅因保护条件或学习情境结束而撤回。

补充：修复前移除旧记录中的新增提示音字段会触发 `keyNotFound`，现以默认值兼容，记录不丢失。采样、自动保存、近期按键窗口、情境停留、提醒冷却与稍后全部采用单调时间；日历时钟只用于日标识与安静时段。

原生 `TodayView` 已用 SwiftUI ImageRenderer 离屏渲染检查明暗外观，图片见 `docs/images/`。它不支持完整 NavigationSplitView 的 AppKit 宿主，因此不作为真实窗口交互证明。

## 历史记录：2026-10-25 RC1 安装物

`./scripts/package.sh` 在非云同步的临时目录组装 `.app`，生成原生 arm64 release，校验代码签名与二进制架构，生成 ZIP / DMG / SHA256。DMG 包含应用及 Applications 入口。

默认发布是 **ad-hoc 签名、未公证**，不能将签名校验通过描述为 Gatekeeper 或 Apple 公证通过。

GitHub macOS 15 arm64 / Swift 6.1.2 CI 早期一次运行中，打包的架构验证因旧版 `lipo` 要求输入文件在前的参数顺序而失败；`a1d1add`（即 RC1 标签提交）把 `lipo` 改为输入文件在前的标准顺序修复了此问题。[修正后的 CI 运行](https://github.com/geraldpeng6/interval-mac/actions/runs/40195521418)（头部 `a1d1add`）成功：全部 17 项测试、arm64 打包与资产上传均通过，RC1 安装物由该运行产出。

[v1.0.0-rc.1 预发布](https://github.com/geraldpeng6/interval-mac/releases/tag/v1.0.0-rc.1) 指向 `a1d1add2d29bb97028bbe102a8624341d5f19228`，已上传 DMG、ZIP、SHA256SUMS。通过 GitHub 重新下载全部附件后，两个安装物的 SHA256 检查通过，下载 ZIP 解包后的签名和 arm64 架构检查通过。

该构建曾安装到本机 `~/Applications/Interval.app`；本记录不担保安装后该文件未被用户改动。2026-10-25 深夜至 2026-10-26 本轮既未更新已安装应用，也未发布新的版本或资产，该安装物不包含主分支后续修复。预发布不表示已完成待验证项目。
