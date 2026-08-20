import SwiftUI
import AppKit

/// Layout skeleton for the Dictation Engine settings window (design canvas
/// "Engine Settings Window"). All state is local `@State` placeholders; every
/// dead control carries a `// WIRE:` comment naming what will bind there in a
/// later task. No AppConfig reads, no key-store calls.
struct DictationEngineSettingsView: View {
    // Engine radio group. WIRE: bind to AppConfig.shared.dictationEngine.
    @State private var engine: String = "local"

    // OpenAI model picker. WIRE: bind to AppConfig.shared.dictationOpenAIModel.
    @State private var openAIModel: String = "gpt-4o-mini-transcribe"

    // Gemini model picker. WIRE: bind to AppConfig.shared.dictationGeminiModel.
    @State private var geminiModel: String = "gemini-3.7-flash"

    // Daily spend warning threshold. WIRE: bind to AppConfig.shared.cloudDailyCapDollars.
    @State private var dailyCap: Double = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            Divider().padding(.vertical, 12)
            sectionEngine
            Divider().padding(.vertical, 12)
            sectionGuardrails
            Divider().padding(.vertical, 12)
            sectionAPIKeys
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, alignment: .topLeading)
    }

    // MARK: - Sections

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Dictation Engine", systemImage: "mic.fill")
                .font(.headline)
            Text("Choose where speech becomes text. Local is private and free. Cloud engines send audio directly to the provider using your own API key — no relay, no HushType server in the middle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionEngine: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Engine", systemImage: "cpu")
                .font(.headline)

            // WIRE: bind selection to AppConfig.shared.dictationEngine.
            Picker("", selection: $engine) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local (Qwen3-ASR)")
                    Text("Private · Free · ~2.1 GB RAM when loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag("local")

                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenAI Cloud")
                    Text("~$0.003–0.0045/min by model · No model RAM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("Model:")
                        Picker("", selection: $openAIModel) {
                            Text("gpt-4o-mini-transcribe (recommended)").tag("gpt-4o-mini-transcribe")
                            Text("gpt-transcribe").tag("gpt-transcribe")
                        }
                        .labelsHidden()
                        .disabled(engine != "openai") // WIRE: enabled only when this engine is selected
                    }
                }
                .tag("openai")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemini Cloud")
                    Text("Free tier, then ~$0.0006–0.0014/min by model · No model RAM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("Model:")
                        Picker("", selection: $geminiModel) {
                            Text("gemini-3.7-flash (quality)").tag("gemini-3.7-flash")
                            Text("gemini-3.5-flash-lite (budget)").tag("gemini-3.5-flash-lite")
                        }
                        .labelsHidden()
                        .disabled(engine != "gemini") // WIRE: enabled only when this engine is selected
                    }
                }
                .tag("gemini")
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            Text("While a cloud engine is selected the speech model stays unloaded. The iOS companion server always uses the local model.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionGuardrails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cost guardrails", systemImage: "dollarsign.circle")
                .font(.headline)

            HStack {
                Text("Warn me when daily spend hits:")
                Stepper(value: $dailyCap, in: 0.5...100.0, step: 0.5) {
                    Text(String(format: "$%.2f", dailyCap))
                        .frame(minWidth: 60, alignment: .trailing)
                        .monospacedDigit()
                }
            }

            HStack {
                // WIRE: replace with formatted line from
                // CloudUsageTracker.shared.snapshot() (dictation vs translated
                // caption split).
                Text("Today's cloud usage: $0.00 total — dictation $0.00 (0 min), translated caption $0.00 (0 min)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset counter") {
                    // WIRE: call CloudUsageTracker.shared.resetDailyCounter() and refresh the usage line.
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var sectionAPIKeys: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("API keys", systemImage: "key.fill")
                .font(.headline)

            apiKeySubsection(provider: "OpenAI", path: "~/Library/Application Support/HushType/openai.json")
            apiKeySubsection(provider: "Gemini", path: "~/Library/Application Support/HushType/gemini.json")
        }
    }

    private func apiKeySubsection(provider: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider).font(.body.bold())
            Text(path)
                // WIRE: OpenAIKeyStore.displayPath / GeminiKeyStore.displayPath
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Open file in TextEdit") {
                    // WIRE: OpenAIKeyStore.openInDefaultEditor() /
                    // GeminiKeyStore.openInDefaultEditor()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer()
            }
            // WIRE: key status line from OpenAIKeyStore.load() /
            // GeminiKeyStore.load() (mirrors LiveCaptionEngineSettingsModel).
            Text("Status: —")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}