import AppKit

/// Per-session cloud dictation consent alert (spec §6.3).
///
/// Before the FIRST cloud dictation utterance of every app session (per
/// provider), the app asks the user for consent. The choice is remembered in
/// memory only — deliberately NOT persisted; every relaunch re-asks once per
/// provider.
@MainActor
final class CloudDictationOnboardingAlert {
    static let shared = CloudDictationOnboardingAlert()

    enum Provider: String { case openai = "OpenAI", gemini = "Google Gemini" }
    enum Choice { case proceed, revertToLocal }

    /// In-memory grants for THIS app session only. No UserDefaults, no files.
    private var grantedProviders: Set<Provider> = []

    private init() {}

    /// True if consent was already granted for this provider THIS app session.
    func hasConsent(for provider: Provider) -> Bool {
        grantedProviders.contains(provider)
    }

    /// Present the modal consent alert (caller must already be off the CGEvent
    /// tap callback and on the main actor). Records an in-memory grant on
    /// .proceed. Returns the user's choice.
    func requestConsent(for provider: Provider) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Send audio to \(provider.rawValue)?"
        alert.informativeText = informativeText(for: provider)
        alert.addButton(withTitle: "Use \(provider.rawValue)") // default button
        alert.addButton(withTitle: "Use Local Instead")

        let choice: Choice = (alert.runModal() == .alertFirstButtonReturn)
            ? .proceed
            : .revertToLocal
        if choice == .proceed {
            grantedProviders.insert(provider)
        }
        return choice
    }

    private func informativeText(for provider: Provider) -> String {
        let base = "HushType will send this recording directly to \(provider.rawValue) for transcription, using your own API key. There is no relay server — audio goes straight from your Mac to the provider. Your daily cloud-spend warning applies."
        if provider == .gemini {
            return base + " On Google's free tier, Google may use submitted audio to improve its products. The paid tier does not."
        }
        return base
    }
}
