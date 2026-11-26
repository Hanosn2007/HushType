# macOS 语音识别与滚动模糊实验记录

这三项独立原型在 2026 年 9 月于 Apple Silicon、macOS 26.6.2 上验证。下文保留当时观察到的行为、可复用的实现和验证边界。两项语音实验使用同一套 Apple 草稿事件，第二项额外加入 Qwen 重识别。本文中的耗时来自当时的实验记录。

## Native Speech Lab · Apple 实时草稿（9 月 21 日）

文件回放将真人录音解码后按约 100 ms 一块实时投递。系统音频与麦克风入口共用识别会话。实验固定 `zh_CN`，在取得支持的 locale 后按下列方式启用标点、可修订结果和音频时间范围。

```swift
let module = DictationTranscriber(
    locale: locale,
    contentHints: [],
    transcriptionOptions: [.punctuation],
    reportingOptions: [.volatileResults, .frequentFinalization],
    attributeOptions: [.audioTimeRange]
)
```

界面用新事件替换时间重叠的草稿，定稿单独累积。有一次定稿句号时长为零，恰好与下一句共享起点。合并时比较定稿的起点和终点，才能在替换下一句时保住这个句号。[事件与合并源码](Transcript.swift)

停止捕获后先排空输入队列，再将转换器里的最后一帧交给识别器。原型中的关键调用顺序如下。正式会话还设有 30 秒超时，遇错会记录失败并取消，导出时保留未定稿标记。

```swift
if let tail = try converter?.flush() { try feed(tail) }
continuation?.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
try await resultTask?.value
```

即时草稿的体验通过了当时的人工试用，定稿准确性仍有限。一段中文里，正确的草稿“皮毛”在定稿时变成“品吗”。另一段中英混说录音出现英文术语遗漏。将 19.11 秒中文样例在同一会话循环七次，共输入 133.77 秒，收到 601 个结果事件，其中 10 个定稿、3 个为零时长句号。停止后 0.518 秒完成收尾，草稿清空。长时间自然对话、不同口音和设备切换仍待验证。

## Two Stage Speech Lab · Apple 草稿与 Qwen 分段替换（9 月 22 日）

两路使用同一条 16 kHz 单声道样本时间轴。一路持续显示 Apple 草稿，另一路复用 HushType 字幕的 FIFO、Silero VAD 分段与 Qwen 推理队列。Qwen 完成一个非空片段后，仅替换该段覆盖的文字。后续 Apple 修订可以更新尚未覆盖的范围。停止时依次排空 FIFO、提交 VAD 最后一个不足窗长的片段，并等待两路完成。

- 有字词时间时，按最大重叠时长确定归属，标点跟随前词。只有整句时间且草稿横跨已替换区时，另行显示完整的待对齐文字。Qwen 失败或返回空文本时保留原生结果。
- 一次回放中，Qwen 已输出句尾的“的”，Apple 却把该字放在段尾之后。去重须同时满足原生词已定稿、处于句尾、所属段已替换、词完全位于段尾后 120 ms 内、文字与替换结果尾部相同。异词、远离边界的词、尚在修订的词、独立下一句都应保留。[合并实现](TwoStageTranscript.swift) · [边界回放用例](MergeChecks.swift)

| 当时的文件回放 | 强识别处理期间的原生更新次数 | FIFO 最大积压 | 丢样本 | 停止到两路完成 |
| --- | ---: | ---: | ---: | ---: |
| 中文 19.11 秒 | 17 | 0.3 秒 | 0 | 0.034 秒 |
| 中英混说 14.91 秒 | 13 | 0.5 秒 | 0 | 0.043 秒 |
| 数字 18.48 秒 | 20 | 0.4 秒 | 0 | 0.047 秒 |
| 英文约 11 秒 | 7 | 0.4 秒 | 0 | 0.037 秒 |
| 同一中文片段循环四遍，76.44 秒 | 79 | 1.2 秒 | 0 | 0.054 秒 |

“处理期间”包括提交、排队和推理。另一次冷首轮中文的首个 Qwen 段耗时约 2.98 秒，积压一度达到 3.1 秒。强识别修正了部分近音词及英文术语，10 秒强切仍可能截词。这些样例没有整体准确率统计。独立签名变体只用于检查更新前后签名身份的一致性；跨更新的实际权限保留仍待验证。

在本目录可独立回放合并用例，无需语音模型、音频或输入权限。

```sh
out=$(mktemp -d)
swiftc Transcript.swift TwoStageTranscript.swift MergeChecks.swift -o "$out/check-merge"
"$out/check-merge"
```

## NativePrivateRetune · 随滚动调整原生模糊（9 月 8 日）

左栏固定半径 18，使用线性遮罩；右栏按各自滚动视图的速度调整半径。两栏各有独立的滚动采样和计时器。默认右栏在静止时使用半径 30，快速滚动时趋向 10.5。顶部遮罩强度 0.10，覆盖高度由 72 pt 加 24 pt 尾部组成。编译默认值用于复现实验。

**实测中最容易遗漏的是滤镜刷新。** 复用已经挂载的 `CAFilter` 时，滑块数字变化，画面仍可能维持原有模糊；把同一对象重新赋给 `filters` 也曾复现这个问题。有效顺序是每次创建新的 `variableBlur`，在关闭隐式动画的事务里写入半径、缓存遮罩和 `inputNormalizeEdges`，再把它挂到 `CABackdropLayer.filters`。尺寸、强度或曲线变化时重建遮罩，滚动只更新半径和滤镜实例。静止时编辑最大半径也要重新计算目标值。

速度按 1800 pt/s 归一化，经过 smoothstep 映射到半径。滚动时速度和平滑半径的时间常数分别为 0.10 和 0.16 秒。停滚 0.10 秒后以 30 Hz 更新，速度和半径分别以 0.25 和 0.24 秒时间常数回稳，达到阈值后停止计时。人工窗口验收确认了手动调参与滚动减弱、停止恢复的效果。可用左栏作固定对照，先静止调右栏最大半径至零，再恢复默认、快速滚动并停下。最终最优参数及其他 macOS 版本上的私有接口兼容性仍待评估。[冻结 Demo 源码](NativePrivateRetuneDemo.swift) · [产品滚动模糊配置](../../SCROLL_BLUR_CONFIGURATION.md)

在 macOS 上，从本目录编译并检查默认值、速度映射和运行时滤镜状态。人工检查画面时直接启动同一可执行文件。

```sh
out=$(mktemp -d)
swiftc -O -parse-as-library -framework AppKit -framework SwiftUI -framework QuartzCore NativePrivateRetuneDemo.swift -o "$out/NativePrivateRetune"
"$out/NativePrivateRetune" --self-test
```
