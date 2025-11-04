import Foundation
import CryptoKit

/// Swift implementation of Edge-TTS without Python dependencies
/// Directly calls Microsoft's Edge TTS API endpoints
@available(macOS 12.0, iOS 15.0, *)
public final class EdgeTTSService: EdgeTTSClient {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private static let appId = UUID().uuidString
    private static let clientId = UUID().uuidString
    private static let tokenCache = TokenCache()
    private static let tokenTTL: TimeInterval = 600

    // Thread-safe token cache using actor
    private actor TokenCache {
        var clockSkewSeconds: TimeInterval = 0
        var cachedToken: String?
        var tokenFetchedAt: Date?

        func getToken() -> (token: String?, fetchedAt: Date?) {
            return (cachedToken, tokenFetchedAt)
        }

        func setToken(_ token: String, fetchedAt: Date) {
            self.cachedToken = token
            self.tokenFetchedAt = fetchedAt
        }

        func setClockSkew(_ skew: TimeInterval) {
            self.clockSkewSeconds = skew
        }

        func getClockSkew() -> TimeInterval {
            return clockSkewSeconds
        }
    }

    // Edge-TTS API endpoints
    private let authURL = "https://edge.microsoft.com/translate/auth"
    private static let voicesBaseURL = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list"
    private static let synthesizeBaseURL = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "1-130.0.2849.68"
    private static let windowsEpochOffset: TimeInterval = 11644473600
    private static let baseHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
        "Accept-Encoding": "gzip, deflate, br",
        "Accept-Language": "en-US,en;q=0.9"
    ]
    private static let websocketHeaders: [String: String] = [
        "Pragma": "no-cache",
        "Cache-Control": "no-cache",
        "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"
    ]

    private static let rfc2616Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static let edgeTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter
    }()

    private func fetchAuthToken(forceRefresh: Bool = false) async throws -> String {
        // Thread-safe token cache check using actor
        if !forceRefresh {
            let (token, fetchedAt) = await Self.tokenCache.getToken()
            if let token = token, let fetchedAt = fetchedAt,
               Date().timeIntervalSince(fetchedAt) < Self.tokenTTL {
                return token
            }
        }

        var request = URLRequest(url: URL(string: authURL)!)
        request.httpMethod = "GET"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36 Edg/121.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://edge.microsoft.com", forHTTPHeaderField: "Origin")
        request.setValue("https://edge.microsoft.com/translate", forHTTPHeaderField: "Referer")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw EdgeTTSError.networkError(NSError(domain: "EdgeTTS", code: (response as? HTTPURLResponse)?.statusCode ?? -1))
            }

            // Adjust clock skew based on server time
            await adjustClockSkew(from: httpResponse)

            guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw EdgeTTSError.invalidResponse
            }

            // Thread-safe token cache update using actor
            await Self.tokenCache.setToken(token, fetchedAt: Date())
            return token
        } catch {
            if error is EdgeTTSError {
                throw error
            }
            throw EdgeTTSError.networkError(error)
        }
    }

    private func adjustClockSkew(from response: HTTPURLResponse) async {
        guard let dateString = response.value(forHTTPHeaderField: "Date"),
              let serverDate = Self.rfc2616Formatter.date(from: dateString) else {
            return
        }
        let clientDate = Date().timeIntervalSince1970
        let skew = serverDate.timeIntervalSince1970 - clientDate
        // Thread-safe clock skew update using actor
        await Self.tokenCache.setClockSkew(skew)
    }

    private func generateSecMsGecToken() async -> String {
        // Thread-safe clock skew read using actor
        let clockSkew = await Self.tokenCache.getClockSkew()
        let current = Date().timeIntervalSince1970 + clockSkew
        var ticks = current + Self.windowsEpochOffset
        ticks -= fmod(ticks, 300)
        ticks *= 10_000_000 // convert seconds to 100-nanosecond intervals
        let payload = String(format: "%.0f%@", ticks, Self.trustedClientToken)
        let hash = SHA256.hash(data: Data(payload.utf8))
        return hash.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Public API

    public func synthesize(text: String, voice: String, outputURL: URL, rate: String? = nil, volume: String? = nil, pitch: String? = nil) async throws -> URL {
        // Input validation
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EdgeTTSError.synthesisFailed
        }
        guard !voice.isEmpty else {
            throw EdgeTTSError.invalidVoice
        }

        do {
            let audioData = try await synthesizeViaWebSocket(text: text, voice: voice, rate: rate, volume: volume, pitch: pitch)

            guard !audioData.isEmpty else {
                throw EdgeTTSError.synthesisFailed
            }

            // Ensure directory exists
            let directory = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

            try audioData.write(to: outputURL)
            return outputURL
        } catch let error as EdgeTTSError {
            throw error
        } catch {
            // File write errors should be wrapped appropriately
            if (error as NSError).domain == NSCocoaErrorDomain {
                throw EdgeTTSError.fileWriteFailed(error)
            }
            throw EdgeTTSError.synthesisFailed
        }
    }

    public func synthesizeMultiple(texts: [String], voice: String, outputDirectory: URL, rate: String? = nil, volume: String? = nil, pitch: String? = nil) async throws -> [URL?] {
        // Input validation
        guard !texts.isEmpty else {
            return []
        }
        guard !voice.isEmpty else {
            throw EdgeTTSError.invalidVoice
        }

        // Ensure directory exists
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)

        var results: [URL?] = []

        for text in texts {
            do {
                let filename = UUID().uuidString + ".mp3"
                let outputURL = outputDirectory.appendingPathComponent(filename)
                let url = try await synthesize(text: text, voice: voice, outputURL: outputURL, rate: rate, volume: volume, pitch: pitch)
                results.append(url)
            } catch {
                results.append(nil)
            }
        }

        return results
    }

    public func getAvailableVoices() async throws -> [EdgeTTSVoice] {
        let token = try? await fetchAuthToken()

        var components = URLComponents(string: Self.voicesBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "trustedclienttoken", value: token ?? "1"),
            URLQueryItem(name: "Sec-MS-GEC", value: await generateSecMsGecToken()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: Self.secMsGecVersion)
        ]

        guard let url = components.url else {
            throw EdgeTTSError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://edge.microsoft.com", forHTTPHeaderField: "Origin")
        request.setValue("https://edge.microsoft.com/translate", forHTTPHeaderField: "Referer")
        request.setValue(Self.appId, forHTTPHeaderField: "X-Search-AppId")
        request.setValue(Self.clientId, forHTTPHeaderField: "X-Search-ClientId")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw EdgeTTSError.networkError(NSError(domain: "EdgeTTS", code: (response as? HTTPURLResponse)?.statusCode ?? -1))
            }

            // Adjust clock skew based on server time
            await adjustClockSkew(from: httpResponse)

            let voices = try JSONDecoder().decode([EdgeTTSVoice].self, from: data)
            return voices
        } catch {
            if error is EdgeTTSError {
                throw error
            }
            if error is DecodingError {
                throw EdgeTTSError.invalidResponse
            }
            throw EdgeTTSError.networkError(error)
        }
    }

    // MARK: - Private Implementation

    private func synthesizeViaWebSocket(text: String, voice: String, rate: String?, volume: String?, pitch: String?) async throws -> Data {
        let ssml = createSSML(text: text, voice: voice, rate: rate, volume: volume, pitch: pitch)

        let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var components = URLComponents(string: Self.synthesizeBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: Self.trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: await generateSecMsGecToken()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: Self.secMsGecVersion),
            URLQueryItem(name: "ConnectionId", value: connectionId)
        ]

        guard let url = components.url else {
            throw EdgeTTSError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        for (key, value) in Self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in Self.websocketHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.webSocketTask(with: request)
        task.resume()

        do {
            try await sendSpeechConfig(on: task)
            try await sendSSML(ssml, on: task)

            var audioBuffer = Data()

            receiveLoop: while true {
                let message = try await task.receive()
                switch message {
                case .string(let textMessage):
                    let headers = parseHeaders(from: textMessage)
                    if let path = headers["Path"] {
                        if path == "turn.end" {
                            break receiveLoop
                        }
                        // Ignore other textual events (turn.start, response, audio.metadata)
                    }
                case .data(let binaryData):
                    if let audioChunk = extractAudioChunk(from: binaryData) {
                        audioBuffer.append(audioChunk)
                    }
                @unknown default:
                    break receiveLoop
                }
            }

            task.cancel(with: .goingAway, reason: nil)
            return audioBuffer
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw EdgeTTSError.networkError(error)
        }
    }

    private func sendSpeechConfig(on task: URLSessionWebSocketTask) async throws {
        let timestamp = Self.edgeTimestampFormatter.string(from: Date())
        let payload = "{" +
            "\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}" +
            "\r\n"
        let message = "X-Timestamp:\(timestamp)\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "Path:speech.config\r\n\r\n" +
            payload
        try await task.send(.string(message))
    }

    private func sendSSML(_ ssml: String, on task: URLSessionWebSocketTask) async throws {
        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let timestamp = Self.edgeTimestampFormatter.string(from: Date())
        let message = "X-RequestId:\(requestId)\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            "X-Timestamp:\(timestamp)Z\r\n" +
            "Path:ssml\r\n\r\n" +
            ssml
        try await task.send(.string(message))
    }

    private func parseHeaders(from raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = raw.components(separatedBy: "\r\n")
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator])
            let valueStart = line.index(after: separator)
            let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    private func extractAudioChunk(from data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let headerLength = Int(data[0]) << 8 | Int(data[1])
        guard headerLength >= 0, data.count >= headerLength + 2 else { return nil }

        let headerStart = data.index(data.startIndex, offsetBy: 2)
        let headerEnd = data.index(headerStart, offsetBy: headerLength)
        let headerData = data[headerStart..<headerEnd]

        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let headers = parseHeaders(from: headerString)
        guard headers["Path"] == "audio" else { return nil }

        let bodyStart = headerEnd
        let audioData = data[bodyStart...]
        return audioData.isEmpty ? nil : Data(audioData)
    }

    /// Create SSML (Speech Synthesis Markup Language) for the text
    private func createSSML(text: String, voice: String, rate: String?, volume: String?, pitch: String?) -> String {
        // Escape XML special characters (must escape & first to avoid double-escaping)
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")

        // Extract locale before sanitizing voice name (voice format: locale-VoiceName)
        let locale = extractLocale(fromVoice: voice) ?? "en-US"

        // Sanitize voice name to prevent XML injection (voice names should not contain special chars anyway)
        let escapedVoice = voice
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")

        // Sanitize prosody parameters to prevent XML injection
        let sanitizedRate = sanitizeProsodyValue(rate ?? "+0%")
        let sanitizedVolume = sanitizeProsodyValue(volume ?? "+0%")
        let sanitizedPitch = sanitizeProsodyValue(pitch ?? "+0Hz")

        // Single-line minimal SSML with required namespaces and one voice/prosody block (per edge-tts 7.2.1 behavior)
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xmlns:mstts='http://www.w3.org/2001/mstts' xml:lang='\(locale)'><voice name='\(escapedVoice)'><prosody rate='\(sanitizedRate)' pitch='\(sanitizedPitch)' volume='\(sanitizedVolume)'>\(escapedText)</prosody></voice></speak>"
    }

    /// Sanitize prosody parameter values to prevent XML injection
    private func sanitizeProsodyValue(_ value: String) -> String {
        // Remove XML special characters and keep only safe characters (+, -, 0-9, %, Hz, ., etc.)
        return value
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    /// Extract locale like "en-US" from voices like "en-US-GuyNeural"
    private func extractLocale(fromVoice voice: String) -> String? {
        let parts = voice.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return parts[0] + "-" + parts[1]
    }
}

