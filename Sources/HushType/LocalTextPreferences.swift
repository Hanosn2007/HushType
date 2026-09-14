import Foundation
import NaturalLanguage

extension LocalTextLanguage: Identifiable {
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        }
    }
}

enum LocalTextPreferences {
    static let captionTranslationKey = "hushtype.localText.captionTranslation"
    static let captionTargetKey = "hushtype.localText.captionTarget"
    static let selectionTargetKey = "hushtype.localText.selectionTarget"
    static let didChange = Notification.Name("HushTypeLocalTextPreferencesDidChange")

    static var translatesCaptions: Bool { UserDefaults.standard.bool(forKey: captionTranslationKey) }
    static var captionTarget: LocalTextLanguage {
        UserDefaults.standard.string(forKey: captionTargetKey).flatMap(LocalTextLanguage.init(rawValue:)) ?? .simplifiedChinese
    }

    static func selectionTarget(for text: String) -> LocalTextLanguage {
        if let raw = UserDefaults.standard.string(forKey: selectionTargetKey),
           let target = LocalTextLanguage(rawValue: raw) { return target }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .simplifiedChinese, .traditionalChinese: return .english
        default: return .simplifiedChinese
        }
    }
}

/// Text requests take turns across selected-text actions and caption sessions.
/// The lower service also joins the global speech/text compute gate. Neither
/// construction nor transform ever downloads weights implicitly.
enum LocalTextResources {
    static let service = Result { try LocalTextModelService() }
    private static let requestQueue = LocalMLXComputeGate()

    static func transform(_ request: LocalTextRequest, loadIfNeeded: Bool = true) async throws -> String {
        try await requestQueue.run {
            let service = try Self.service.get()
            if loadIfNeeded, !(await service.status()).isLoaded {
                try await service.load()
            }
            return try await service.transform(request)
        }
    }
}
