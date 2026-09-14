import Foundation

extension ProcessingProfile {
    func requireAvailableModels(
        speechAvailable: (String) -> Bool,
        textAvailable: () -> Bool
    ) throws {
        guard speechAvailable(modelID) else {
            throw ProfileError.modelUnavailable(LocalModelCatalog.descriptor(for: modelID)?.title ?? modelID)
        }
        if llm.polish || llm.translate, !textAvailable() {
            throw ProfileError.modelUnavailable(LocalTextModelDescriptor.qwen3FourBit.displayName)
        }
    }

    func requireAvailableModels(loadedSpeechModelID: String?) throws {
        try requireAvailableModels(speechAvailable: { id in
            id == loadedSpeechModelID || LocalModelCatalog.descriptor(for: id).map(LocalModelCatalog.isInstalled) == true
        }, textAvailable: {
            guard let catalog = try? LocalTextModelCatalog() else { return false }
            if case .installed = catalog.installation() { return true }
            return false
        })
    }
}

extension LocalModelLibrary {
    func profileTitle(_ id: String, loadedID: String?) -> String {
        let name = LocalModelCatalog.descriptor(for: id)?.title ?? id
        let available = id == loadedID || installedModels.contains { $0.id == id }
        return available ? name : name + " " + L10n.string("profiles.unavailable", fallback: "(Unavailable)")
    }
}
