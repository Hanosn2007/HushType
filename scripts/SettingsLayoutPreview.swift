// Compile alongside SettingsChromeLayout.swift for a native visual smoke test.
// This target does not import HushType or access models, permissions or user data.
import SwiftUI

@main
struct SettingsLayoutPreview: App {
    var body: some Scene {
        Window("HushType 布局预览", id: "preview") {
            PreviewContent().frame(minWidth: 850, minHeight: 600)
                .modifier(SettingsToolbarChrome())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 950, height: 650)
    }
}

private struct PreviewContent: View {
    @State private var selection = "概览"
    @State private var search = ""
    private let sections = ["概览", "听写", "识别历史", "模型", "词典", "权限", "通用"]
    private let symbols = ["square.grid.2x2", "mic", "clock.arrow.circlepath", "cpu", "book", "checklist", "gear"]
    var body: some View {
        SettingsWindowShell(toggleLabel: "展开或收起侧边栏",
                            expandedLabel: "已展开", collapsedLabel: "已收起",
                            stabilizesDetailWidth: selection == "识别历史") {
            Form {
                Section {
                    Text("快速查看 HushType 和本地语音模型的状态。").foregroundStyle(.secondary)
                }
                if selection == "识别历史" {
                    ForEach(filteredIndices, id: \.self) { index in
                        HStack {
                            Text("\(100 - index)").font(.caption).foregroundStyle(.secondary).frame(width: 24)
                            Text("下午 6:19").foregroundStyle(.secondary)
                            Text(sampleText(index)).lineLimit(3)
                            Spacer()
                            Image(systemName: "doc.on.doc")
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: 20) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 32)).foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("就绪").bold()
                                Text("按 F5 开始听写。")
                                Text("正在运行的模型：布局预览（未加载模型）").font(.caption)
                            }
                            Spacer()
                            Button("从内存卸载") {}.disabled(true)
                        }.padding(.vertical, 8)
                    }
                    Section {
                        Label("如何听写", systemImage: "keyboard").bold()
                        Text("按 F5 开始录音，再按一次 F5 进行转写并将文本插入光标位置。")
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
                .background {
                    if selection == "识别历史" {
                        Color.clear.searchable(text: $search, placement: .toolbar, prompt: "搜索识别文字")
                    }
                }
        } sidebar: {
            List(selection: $selection) {
                Section {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, title in
                        Label(title, systemImage: symbols[index]).tag(title)
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
        } header: {
            HStack(spacing: 16) {
                SettingsNavigationButtons(
                    backDisabled: selection == sections.first,
                    forwardDisabled: selection == sections.last,
                    backLabel: "上一页", forwardLabel: "下一页",
                    back: { navigate(-1) }, forward: { navigate(1) }
                )
                Text(selection).font(.headline)
                Spacer(minLength: 12)
            }
        }
    }

    private var filteredIndices: [Int] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (0..<100).filter {
            query.isEmpty || "\(100 - $0) \(sampleText($0))"
                .localizedCaseInsensitiveContains(query)
        }
    }

    private func sampleText(_ index: Int) -> String {
        index.isMultiple(of: 3)
            ? "这是一条用于验证侧栏动画的长记录。展开和收起时，文字只按目标宽度排版一次，避免长句反复换行导致后续条目上下跳动。这个窗口使用模拟数据，不读取真实历史，也不加载语音模型。"
            : "用于验证历史列表展开收起的示例记录，不读取真实历史。"
    }

    private func navigate(_ offset: Int) {
        guard let current = sections.firstIndex(of: selection),
              sections.indices.contains(current + offset) else { return }
        selection = sections[current + offset]
    }
}
