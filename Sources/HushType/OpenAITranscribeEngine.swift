import Foundation
import Network
import os

private let openAITranscribeLog = Logger(
    subsystem: "com.felix.hushtype",
    category: "openAITranscribe"
)

/// Process-wide reachability signal for cloud dictation's cheap offline
/// preflight. An unknown path still proceeds to URLSession so startup races
/// cannot incorrectly reject a reachable network.
final class CloudDictationReachability: @unchecked Sendable {
    static let shared = CloudDictationReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var latestStatus: NWPath.Status?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.setStatus(path.status)
        }
        monitor.start(queue: DispatchQueue(label: "hushtype.cloudDictation.reachability"))
    }

    var isKnownOffline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestStatus == .unsatisfied
    }

    private func setStatus(_ status: NWPath.Status) {
        lock.lock()
        latestStatus = status
        lock.unlock()
    }
}

final class OpenAITranscribeEngine: TranscriptionEngine {
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let providerMaxSampleCount = 16_000 * 600
    private static let primer = "上週的簡報我已經更新到 Notion，請大家確認。"

    private let redirectDelegate: RedirectRefusingDelegate
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false

        let redirectDelegate = RedirectRefusingDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    var isLoaded: Bool { true }
    var maxSampleCount: Int? { Self.providerMaxSampleCount }

    func load(progressHandler: ((Double, String) -> Void)?) async throws {}

    func transcribe(audio: [Float], language: String?) async throws -> String {
        let apiKey: String
        let organization: String?
        switch OpenAIKeyStore.load() {
        case .ok(let key, let org), .unusualFormat(let key, let org):
            apiKey = key
            organization = org
        case .empty:
            throw TranscriptionError.noKey
        }

        guard audio.count <= Self.providerMaxSampleCount else {
            throw TranscriptionError.payloadTooLarge
        }
        guard !audio.isEmpty else { return "" }
        guard !CloudDictationReachability.shared.isKnownOffline else {
            throw TranscriptionError.network
        }

        let model = AppConfig.shared.cloudDictationModelOpenAI
        let boundary = "HushTypeBoundary-\(UUID().uuidString)"
        let wavData = WAVEncoder.encode(samples: audio)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let organization, !organization.isEmpty {
            request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            wavData: wavData,
            model: model,
            language: language
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw TranscriptionError.timeout
            }
            throw TranscriptionError.network
        } catch {
            throw TranscriptionError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network
        }

        guard (200..<300).contains(http.statusCode) else {
            logHTTPFailure(statusCode: http.statusCode, data: data)
            switch http.statusCode {
            case 401, 403:
                throw TranscriptionError.auth
            case 429:
                throw TranscriptionError.rateLimited(provider: "OpenAI")
            default:
                throw TranscriptionError.network
            }
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let rawTranscript = json["text"] as? String else {
            logHTTPFailure(statusCode: http.statusCode, data: data)
            throw TranscriptionError.malformedResponse
        }

        // Silent audio can echo the prompt primer instead of a transcript.
        if rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines) == Self.primer {
            return ""
        }

        return DictationPostProcessor.apply(rawTranscript)
    }

    private func makeMultipartBody(
        boundary: String,
        wavData: Data,
        model: String,
        language: String?
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        appendTextPart(name: "model", value: model, boundary: boundary, to: &body)
        appendTextPart(name: "response_format", value: "json", boundary: boundary, to: &body)
        switch language {
        case "english":
            appendTextPart(name: "language", value: "en", boundary: boundary, to: &body)
        case "japanese":
            appendTextPart(name: "language", value: "ja", boundary: boundary, to: &body)
        default:
            appendTextPart(name: "prompt", value: Self.primer, boundary: boundary, to: &body)
        }
        append("--\(boundary)--\r\n")

        return body
    }

    private func appendTextPart(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private func logHTTPFailure(statusCode: Int, data: Data) {
        let snippet = String(decoding: data.prefix(512), as: UTF8.self)
        openAITranscribeLog.error(
            "HTTP \(statusCode, privacy: .public): \(snippet, privacy: .private)"
        )
    }
}
