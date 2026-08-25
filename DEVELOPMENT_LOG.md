# HushType 开发日志

## 2026-08-25：运行中覆盖 App 导致输入冻结与权限误报

### 症状

用户在正常使用 HushType 时，键盘、触控板和光标短暂全部失效；屏幕仍在刷新。随后出现 HushType 自定义的“辅助功能权限已失效”弹窗，提示重新启用权限并重启应用。弹窗出现后输入恢复。

### 已确认证据链

1. 旧实例 PID `95958` 于 `17:55` 启动。
2. `18:03` 构建流程原地覆盖了仍在运行的 `HushType.app`。
3. TCC 随后将旧进程识别为 `<ID of InvalidCode>`，导致旧实例的代码签名身份失效。
4. `18:10:29.792`：旧实例的 Event Tap 报 `disabled by timeout`。
5. `18:10:30.875`：HushType 尝试通过 `CGEvent.tapCreate` 重建 Event Tap 失败，并将失败误判为辅助功能权限失效。
6. 旧实例退出后，新 PID `99890` 启动；辅助功能权限和 Event Tap 均恢复正常。

结论：这次输入冻结与 HushType 的全局 Event Tap 生命周期直接相关，根因是更新/构建时原地替换运行中的 App，使旧进程变成 InvalidCode。权限弹窗是后续的误报，不代表用户实际撤销了辅助功能权限。

### 后续检索关键词

优先检索以下关键词及其相邻时间窗口：

- `InvalidCode`
- `disabled by timeout`
- `CGEvent.tapCreate`
- `Event Tap`
- `AXIsProcessTrusted`
- `accessibility permission`
- `辅助功能权限已失效`
- `HushType.app`、`PID`、`TCC`、`WindowServer`

### 以后排查顺序

1. 先确认是否发生过构建、安装或替换 App，并核对运行 PID、启动时间、当前 Bundle/代码签名身份。
2. 再查 TCC、`InvalidCode` 和 Event Tap 的系统日志，确认是代码签名失效、超时、用户禁用，还是权限确实被撤销。
3. 检查 `CGEvent.tapCreate` 的返回结果和 Event Tap 禁用原因；不能仅凭 `AXIsProcessTrusted() == false` 判定权限丢失。
4. 最后才检查用户是否在系统设置中关闭了 HushType 的辅助功能权限，并决定是否显示权限引导。

### 开发规约

- 禁止原地覆盖正在运行的 `HushType.app`。
- 构建产物必须先输出到 staging 路径；确认旧实例退出后，再执行原子替换或安装。
- 更新流程必须区分“真实辅助功能权限缺失”和“运行中的旧实例因代码签名身份失效/被替换而失效”。后者不得显示为普通权限丢失。
- Event Tap 失效时必须记录具体原因，并在重建失败后保留可诊断状态，避免把所有失败统一映射成权限弹窗。
- 对涉及全局输入监听的改动，优先验证：运行中构建/替换、权限变化、Event Tap 超时、应用退出和重启这几条生命周期路径。

