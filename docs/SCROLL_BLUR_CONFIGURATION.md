# Preview 调试页与动态滚动模糊配置

配置入口：`Sources/HushType/Settings/SettingsScrollBlurConfiguration.swift`；UI入口：同目录 `SettingsDebugView.swift`。`SettingsChromeLayout.swift` 的 `BackdropView` 在创建时读取配置，并监听 UserDefaults 变化在主线程重新应用，调试页修改即时生效。

2026-09-08 已连同用户验收的原生历史列表接入实际 Swift 仓库。此状态不代表已发布。

用户最新决定取代此前“隐藏配置、不暴露UI”：版本号包含 preview 时，侧栏显示“调试”；正式版隐藏该入口，保留后端配置及读写代码。调试页提供开关、最小/最大半径、恢复默认、当前版本/配置状态，以及打开系统 Console 查看 `com.felix.hushtype` 日志的入口。新手引导仍只显示权限页。

## 开关和自动范围

| UserDefaults key | 默认及规则 |
| --- | --- |
| `hushtype.preview.scrollBlur.enabled` | 版本号包含preview时默认true，正式版默认false；显式布尔值可覆盖 |
| `hushtype.preview.scrollBlur.minimumRadius` | 快滚半径默认10.5 |
| `hushtype.preview.scrollBlur.maximumRadius` | 静止/慢速半径默认30；关闭自动变化时也使用此值 |

半径是CAFilter的inputRadius参数，**不是屏幕上的实际模糊半径**。既有遮罩alpha仍是底0→顶0.1，独立遮色层保持原参数。读取值必须有限，限制在0...60；端点反序时排序。缺失/无效值回退默认。

`SettingsChromeLayout.swift` 使用 `NSScrollView.didLiveScrollNotification` 的位移/时间估计真实滚动速度，布局/锚点补偿产生的 bounds 变化不驱动模糊。普通无 phase 鼠标滚轮的通知已通过独立 AppKit 运行检查。

每个 backdrop 只接收其面板范围内可见滚动 viewport 的通知；嵌套编辑器归属其所在面板。侧栏和正文各自保留速度、半径和回落计时器，不能仅按同一 window 过滤而相互驱动。

侧栏保留单块完整原生玻璃。子 CABackdropLayer 以半径0捕获背景，先按内缩圆角裁切；父 CALayer 再应用 variableBlur，最终按同一内缩区域裁输出。此顺序来自用户已验收的独立圆角输入 Demo，替代未验收的双玻璃拆分候选。右侧正文保持既有 backdrop 模糊路径。

调试页新增默认收起的“模糊边缘”板块。`hushtype.preview.scrollBlur.edgeInsetPixels` 默认2，范围0...100，单位是backing渲染像素。每个窗口按当前backingScaleFactor换算：1×为2pt、2×为1pt；跨屏和调试修改即时更新。只调模糊输入及输出边界，不改变玻璃本身或已有染色边界。

用户实测1×、2×下2px均无明显白线扩散，1px仍有边缘线。Mac内屏/直连外屏实看满意，截图及Sidecar角部色纹原因未定位。染色横向色带已定位到独立染色路径，原生高精度渐变另行处理；窗口开合/最小化期间暂关模糊并缓动恢复明确暂缓。本次集成仍需应用内视觉验收，不等于发布。

速度0–1800pt/s 经 smoothstep 连续映射到最大–最小半径；速度低通时间常数0.10s，滚动时半径响应0.16s。停止输入0.10s后启动30Hz收敛计时器，速度以0.25s时间常数衰减、半径以0.24s响应回到最大值；速度≤1pt/s且半径距离最大值≤0.02时停止计时器。持续输入推迟计时器，不在静止时一直运行。

复用radiusMask，不随每个滚动事件重画遮罩。新滚动容器首次出现或窗口布局变化时才重新检查滚动条位置；普通offset变化不遍历全视图树。这取代旧的700/220pt/s两档触发逻辑。没有确认 App Store 内部机制，也未测量GPU节省比例。

## 手动配置（不自动执行）

调试页“侧栏滚动测试”新增开关 `hushtype.preview.sidebarScrollTest.enabled`，默认false。仅Preview可开启，追加100个无点击功能的填充行，不写入真实导航/历史。关闭立即移除；正式版即使残留true也不渲染。用于确认左侧自身滚动驱动模糊、右侧滚动不联动。

用户发现两阶段模糊在刚打开时短暂黑块，要求先在独立“打开预热实验”Demo测试；主应用尚未接入预热修复。该Demo采用250ms低透明度采样预热和200ms渐显，实际效果待用户验证。

实际应用使用domain `com.felix.hushtype`：

```sh
defaults read com.felix.hushtype hushtype.preview.scrollBlur.enabled
defaults write com.felix.hushtype hushtype.preview.scrollBlur.enabled -bool false
defaults write com.felix.hushtype hushtype.preview.scrollBlur.minimumRadius -float 10.5
defaults write com.felix.hushtype hushtype.preview.scrollBlur.maximumRadius -float 30
```

要恢复默认，优先使用调试页“恢复默认”；也可用`defaults delete`删除对应key（外部命令修改后若进程未收到通知，则重启生效）。独立验证窗口使用自己的domain，不与实际应用共享偏好。

## 验证边界

用户先确认最终文字自动适应（当时不代表模糊验收），随后查看完整候选并于2026-09-08确认当前效果、授权发布Preview14。41项Release定点测试通过，包含默认 Preview 启用、正式版隐藏入口、参数范围、连续单调映射及平滑收敛。真实自动更新后的运行行为仍通过实际升级验证。
