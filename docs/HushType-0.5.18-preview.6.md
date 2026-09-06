# HushType 0.5.18 Preview 6

- 修复 Preview 5 选择 iPhone、AirPods 等无线输入后可能立即闪退的问题。
- 保留录音中关闭 Mac 蓝牙时的“连接断开”检测，但不再创建受蓝牙隐私保护的控制器对象，也不新增蓝牙权限请求。
- 当前系统若不再提供兼容的只读电源状态接口，会安全退回原有的 CoreAudio／AVFoundation 健康检查，不会因此终止应用。

顶栏状态项已由 Thaw 正确识别；若图标不可见，请在 Thaw 中将 HushType 从“隐藏”区域移到“可见”区域。
