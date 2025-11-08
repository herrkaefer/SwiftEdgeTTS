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

    // MARK: - Hardcoded Voices Data

    /// Helper function to create EdgeTTSVoice objects
    private static func make(_ shortName: String, _ gender: String, _ contentCategories: String, _ voicePersonalities: String, _ locale: String) -> EdgeTTSVoice {
        return EdgeTTSVoice(
            shortName: shortName,
            gender: gender,
            contentCategories: contentCategories,
            voicePersonalities: voicePersonalities,
            locale: locale
        )
    }

    private static let hardcodedVoicesData: [String: [EdgeTTSVoice]] = [
        "af": [
            make("af-ZA-AdriNeural", "Female", "General", "Friendly, Positive", "af-ZA"),
            make("af-ZA-WillemNeural", "Male", "General", "Friendly, Positive", "af-ZA"),
        ],
        "af-za": [
            make("af-ZA-AdriNeural", "Female", "General", "Friendly, Positive", "af-ZA"),
            make("af-ZA-WillemNeural", "Male", "General", "Friendly, Positive", "af-ZA"),
        ],
        "am": [
            make("am-ET-AmehaNeural", "Male", "General", "Friendly, Positive", "am-ET"),
            make("am-ET-MekdesNeural", "Female", "General", "Friendly, Positive", "am-ET"),
        ],
        "am-et": [
            make("am-ET-AmehaNeural", "Male", "General", "Friendly, Positive", "am-ET"),
            make("am-ET-MekdesNeural", "Female", "General", "Friendly, Positive", "am-ET"),
        ],
        "ar": [
            make("ar-AE-FatimaNeural", "Female", "General", "Friendly, Positive", "ar-AE"),
            make("ar-AE-HamdanNeural", "Male", "General", "Friendly, Positive", "ar-AE"),
            make("ar-BH-AliNeural", "Male", "General", "Friendly, Positive", "ar-BH"),
            make("ar-BH-LailaNeural", "Female", "General", "Friendly, Positive", "ar-BH"),
            make("ar-DZ-AminaNeural", "Female", "General", "Friendly, Positive", "ar-DZ"),
            make("ar-DZ-IsmaelNeural", "Male", "General", "Friendly, Positive", "ar-DZ"),
            make("ar-EG-SalmaNeural", "Female", "General", "Friendly, Positive", "ar-EG"),
            make("ar-EG-ShakirNeural", "Male", "General", "Friendly, Positive", "ar-EG"),
            make("ar-IQ-BasselNeural", "Male", "General", "Friendly, Positive", "ar-IQ"),
            make("ar-IQ-RanaNeural", "Female", "General", "Friendly, Positive", "ar-IQ"),
            make("ar-JO-SanaNeural", "Female", "General", "Friendly, Positive", "ar-JO"),
            make("ar-JO-TaimNeural", "Male", "General", "Friendly, Positive", "ar-JO"),
            make("ar-KW-FahedNeural", "Male", "General", "Friendly, Positive", "ar-KW"),
            make("ar-KW-NouraNeural", "Female", "General", "Friendly, Positive", "ar-KW"),
            make("ar-LB-LaylaNeural", "Female", "General", "Friendly, Positive", "ar-LB"),
            make("ar-LB-RamiNeural", "Male", "General", "Friendly, Positive", "ar-LB"),
            make("ar-LY-ImanNeural", "Female", "General", "Friendly, Positive", "ar-LY"),
            make("ar-LY-OmarNeural", "Male", "General", "Friendly, Positive", "ar-LY"),
            make("ar-MA-JamalNeural", "Male", "General", "Friendly, Positive", "ar-MA"),
            make("ar-MA-MounaNeural", "Female", "General", "Friendly, Positive", "ar-MA"),
            make("ar-OM-AbdullahNeural", "Male", "General", "Friendly, Positive", "ar-OM"),
            make("ar-OM-AyshaNeural", "Female", "General", "Friendly, Positive", "ar-OM"),
            make("ar-QA-AmalNeural", "Female", "General", "Friendly, Positive", "ar-QA"),
            make("ar-QA-MoazNeural", "Male", "General", "Friendly, Positive", "ar-QA"),
            make("ar-SA-HamedNeural", "Male", "General", "Friendly, Positive", "ar-SA"),
            make("ar-SA-ZariyahNeural", "Female", "General", "Friendly, Positive", "ar-SA"),
            make("ar-SY-AmanyNeural", "Female", "General", "Friendly, Positive", "ar-SY"),
            make("ar-SY-LaithNeural", "Male", "General", "Friendly, Positive", "ar-SY"),
            make("ar-TN-HediNeural", "Male", "General", "Friendly, Positive", "ar-TN"),
            make("ar-TN-ReemNeural", "Female", "General", "Friendly, Positive", "ar-TN"),
            make("ar-YE-MaryamNeural", "Female", "General", "Friendly, Positive", "ar-YE"),
            make("ar-YE-SalehNeural", "Male", "General", "Friendly, Positive", "ar-YE"),
        ],
        "ar-ae": [
            make("ar-AE-FatimaNeural", "Female", "General", "Friendly, Positive", "ar-AE"),
            make("ar-AE-HamdanNeural", "Male", "General", "Friendly, Positive", "ar-AE"),
        ],
        "ar-bh": [
            make("ar-BH-AliNeural", "Male", "General", "Friendly, Positive", "ar-BH"),
            make("ar-BH-LailaNeural", "Female", "General", "Friendly, Positive", "ar-BH"),
        ],
        "ar-dz": [
            make("ar-DZ-AminaNeural", "Female", "General", "Friendly, Positive", "ar-DZ"),
            make("ar-DZ-IsmaelNeural", "Male", "General", "Friendly, Positive", "ar-DZ"),
        ],
        "ar-eg": [
            make("ar-EG-SalmaNeural", "Female", "General", "Friendly, Positive", "ar-EG"),
            make("ar-EG-ShakirNeural", "Male", "General", "Friendly, Positive", "ar-EG"),
        ],
        "ar-iq": [
            make("ar-IQ-BasselNeural", "Male", "General", "Friendly, Positive", "ar-IQ"),
            make("ar-IQ-RanaNeural", "Female", "General", "Friendly, Positive", "ar-IQ"),
        ],
        "ar-jo": [
            make("ar-JO-SanaNeural", "Female", "General", "Friendly, Positive", "ar-JO"),
            make("ar-JO-TaimNeural", "Male", "General", "Friendly, Positive", "ar-JO"),
        ],
        "ar-kw": [
            make("ar-KW-FahedNeural", "Male", "General", "Friendly, Positive", "ar-KW"),
            make("ar-KW-NouraNeural", "Female", "General", "Friendly, Positive", "ar-KW"),
        ],
        "ar-lb": [
            make("ar-LB-LaylaNeural", "Female", "General", "Friendly, Positive", "ar-LB"),
            make("ar-LB-RamiNeural", "Male", "General", "Friendly, Positive", "ar-LB"),
        ],
        "ar-ly": [
            make("ar-LY-ImanNeural", "Female", "General", "Friendly, Positive", "ar-LY"),
            make("ar-LY-OmarNeural", "Male", "General", "Friendly, Positive", "ar-LY"),
        ],
        "ar-ma": [
            make("ar-MA-JamalNeural", "Male", "General", "Friendly, Positive", "ar-MA"),
            make("ar-MA-MounaNeural", "Female", "General", "Friendly, Positive", "ar-MA"),
        ],
        "ar-om": [
            make("ar-OM-AbdullahNeural", "Male", "General", "Friendly, Positive", "ar-OM"),
            make("ar-OM-AyshaNeural", "Female", "General", "Friendly, Positive", "ar-OM"),
        ],
        "ar-qa": [
            make("ar-QA-AmalNeural", "Female", "General", "Friendly, Positive", "ar-QA"),
            make("ar-QA-MoazNeural", "Male", "General", "Friendly, Positive", "ar-QA"),
        ],
        "ar-sa": [
            make("ar-SA-HamedNeural", "Male", "General", "Friendly, Positive", "ar-SA"),
            make("ar-SA-ZariyahNeural", "Female", "General", "Friendly, Positive", "ar-SA"),
        ],
        "ar-sy": [
            make("ar-SY-AmanyNeural", "Female", "General", "Friendly, Positive", "ar-SY"),
            make("ar-SY-LaithNeural", "Male", "General", "Friendly, Positive", "ar-SY"),
        ],
        "ar-tn": [
            make("ar-TN-HediNeural", "Male", "General", "Friendly, Positive", "ar-TN"),
            make("ar-TN-ReemNeural", "Female", "General", "Friendly, Positive", "ar-TN"),
        ],
        "ar-ye": [
            make("ar-YE-MaryamNeural", "Female", "General", "Friendly, Positive", "ar-YE"),
            make("ar-YE-SalehNeural", "Male", "General", "Friendly, Positive", "ar-YE"),
        ],
        "az": [
            make("az-AZ-BabekNeural", "Male", "General", "Friendly, Positive", "az-AZ"),
            make("az-AZ-BanuNeural", "Female", "General", "Friendly, Positive", "az-AZ"),
        ],
        "az-az": [
            make("az-AZ-BabekNeural", "Male", "General", "Friendly, Positive", "az-AZ"),
            make("az-AZ-BanuNeural", "Female", "General", "Friendly, Positive", "az-AZ"),
        ],
        "bg": [
            make("bg-BG-BorislavNeural", "Male", "General", "Friendly, Positive", "bg-BG"),
            make("bg-BG-KalinaNeural", "Female", "General", "Friendly, Positive", "bg-BG"),
        ],
        "bg-bg": [
            make("bg-BG-BorislavNeural", "Male", "General", "Friendly, Positive", "bg-BG"),
            make("bg-BG-KalinaNeural", "Female", "General", "Friendly, Positive", "bg-BG"),
        ],
        "bn": [
            make("bn-BD-NabanitaNeural", "Female", "General", "Friendly, Positive", "bn-BD"),
            make("bn-BD-PradeepNeural", "Male", "General", "Friendly, Positive", "bn-BD"),
            make("bn-IN-BashkarNeural", "Male", "General", "Friendly, Positive", "bn-IN"),
            make("bn-IN-TanishaaNeural", "Female", "General", "Friendly, Positive", "bn-IN"),
        ],
        "bn-bd": [
            make("bn-BD-NabanitaNeural", "Female", "General", "Friendly, Positive", "bn-BD"),
            make("bn-BD-PradeepNeural", "Male", "General", "Friendly, Positive", "bn-BD"),
        ],
        "bn-in": [
            make("bn-IN-BashkarNeural", "Male", "General", "Friendly, Positive", "bn-IN"),
            make("bn-IN-TanishaaNeural", "Female", "General", "Friendly, Positive", "bn-IN"),
        ],
        "bs": [
            make("bs-BA-GoranNeural", "Male", "General", "Friendly, Positive", "bs-BA"),
            make("bs-BA-VesnaNeural", "Female", "General", "Friendly, Positive", "bs-BA"),
        ],
        "bs-ba": [
            make("bs-BA-GoranNeural", "Male", "General", "Friendly, Positive", "bs-BA"),
            make("bs-BA-VesnaNeural", "Female", "General", "Friendly, Positive", "bs-BA"),
        ],
        "ca": [
            make("ca-ES-EnricNeural", "Male", "General", "Friendly, Positive", "ca-ES"),
            make("ca-ES-JoanaNeural", "Female", "General", "Friendly, Positive", "ca-ES"),
        ],
        "ca-es": [
            make("ca-ES-EnricNeural", "Male", "General", "Friendly, Positive", "ca-ES"),
            make("ca-ES-JoanaNeural", "Female", "General", "Friendly, Positive", "ca-ES"),
        ],
        "cs": [
            make("cs-CZ-AntoninNeural", "Male", "General", "Friendly, Positive", "cs-CZ"),
            make("cs-CZ-VlastaNeural", "Female", "General", "Friendly, Positive", "cs-CZ"),
        ],
        "cs-cz": [
            make("cs-CZ-AntoninNeural", "Male", "General", "Friendly, Positive", "cs-CZ"),
            make("cs-CZ-VlastaNeural", "Female", "General", "Friendly, Positive", "cs-CZ"),
        ],
        "cy": [
            make("cy-GB-AledNeural", "Male", "General", "Friendly, Positive", "cy-GB"),
            make("cy-GB-NiaNeural", "Female", "General", "Friendly, Positive", "cy-GB"),
        ],
        "cy-gb": [
            make("cy-GB-AledNeural", "Male", "General", "Friendly, Positive", "cy-GB"),
            make("cy-GB-NiaNeural", "Female", "General", "Friendly, Positive", "cy-GB"),
        ],
        "da": [
            make("da-DK-ChristelNeural", "Female", "General", "Friendly, Positive", "da-DK"),
            make("da-DK-JeppeNeural", "Male", "General", "Friendly, Positive", "da-DK"),
        ],
        "da-dk": [
            make("da-DK-ChristelNeural", "Female", "General", "Friendly, Positive", "da-DK"),
            make("da-DK-JeppeNeural", "Male", "General", "Friendly, Positive", "da-DK"),
        ],
        "de": [
            make("de-AT-IngridNeural", "Female", "General", "Friendly, Positive", "de-AT"),
            make("de-AT-JonasNeural", "Male", "General", "Friendly, Positive", "de-AT"),
            make("de-CH-JanNeural", "Male", "General", "Friendly, Positive", "de-CH"),
            make("de-CH-LeniNeural", "Female", "General", "Friendly, Positive", "de-CH"),
            make("de-DE-AmalaNeural", "Female", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-ConradNeural", "Male", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-FlorianMultilingualNeural", "Male", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-KatjaNeural", "Female", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-KillianNeural", "Male", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-SeraphinaMultilingualNeural", "Female", "General", "Friendly, Positive", "de-DE"),
        ],
        "de-at": [
            make("de-AT-IngridNeural", "Female", "General", "Friendly, Positive", "de-AT"),
            make("de-AT-JonasNeural", "Male", "General", "Friendly, Positive", "de-AT"),
        ],
        "de-ch": [
            make("de-CH-JanNeural", "Male", "General", "Friendly, Positive", "de-CH"),
            make("de-CH-LeniNeural", "Female", "General", "Friendly, Positive", "de-CH"),
        ],
        "de-de": [
            make("de-DE-AmalaNeural", "Female", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-ConradNeural", "Male", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-FlorianMultilingualNeural", "Male", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-KatjaNeural", "Female", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-KillianNeural", "Male", "General", "Friendly, Positive", "de-DE"),
            make("de-DE-SeraphinaMultilingualNeural", "Female", "General", "Friendly, Positive", "de-DE"),
        ],
        "el": [
            make("el-GR-AthinaNeural", "Female", "General", "Friendly, Positive", "el-GR"),
            make("el-GR-NestorasNeural", "Male", "General", "Friendly, Positive", "el-GR"),
        ],
        "el-gr": [
            make("el-GR-AthinaNeural", "Female", "General", "Friendly, Positive", "el-GR"),
            make("el-GR-NestorasNeural", "Male", "General", "Friendly, Positive", "el-GR"),
        ],
        "en": [
            make("en-AU-NatashaNeural", "Female", "General", "Friendly, Positive", "en-AU"),
            make("en-AU-WilliamMultilingualNeural", "Male", "General", "Friendly, Positive", "en-AU"),
            make("en-CA-ClaraNeural", "Female", "General", "Friendly, Positive", "en-CA"),
            make("en-CA-LiamNeural", "Male", "General", "Friendly, Positive", "en-CA"),
            make("en-GB-LibbyNeural", "Female", "General", "Friendly, Positive", "en-GB"),
            make("en-GB-MaisieNeural", "Female", "General", "Friendly, Positive", "en-GB"),
            make("en-GB-RyanNeural", "Male", "General", "Friendly, Positive", "en-GB"),
            make("en-GB-SoniaNeural", "Female", "General", "Friendly, Positive", "en-GB"),
            make("en-GB-ThomasNeural", "Male", "General", "Friendly, Positive", "en-GB"),
            make("en-HK-SamNeural", "Male", "General", "Friendly, Positive", "en-HK"),
            make("en-HK-YanNeural", "Female", "General", "Friendly, Positive", "en-HK"),
            make("en-IE-ConnorNeural", "Male", "General", "Friendly, Positive", "en-IE"),
            make("en-IE-EmilyNeural", "Female", "General", "Friendly, Positive", "en-IE"),
            make("en-IN-NeerjaExpressiveNeural", "Female", "General", "Friendly, Positive", "en-IN"),
            make("en-IN-NeerjaNeural", "Female", "General", "Friendly, Positive", "en-IN"),
            make("en-IN-PrabhatNeural", "Male", "General", "Friendly, Positive", "en-IN"),
            make("en-KE-AsiliaNeural", "Female", "General", "Friendly, Positive", "en-KE"),
            make("en-KE-ChilembaNeural", "Male", "General", "Friendly, Positive", "en-KE"),
            make("en-NG-AbeoNeural", "Male", "General", "Friendly, Positive", "en-NG"),
            make("en-NG-EzinneNeural", "Female", "General", "Friendly, Positive", "en-NG"),
            make("en-NZ-MitchellNeural", "Male", "General", "Friendly, Positive", "en-NZ"),
            make("en-NZ-MollyNeural", "Female", "General", "Friendly, Positive", "en-NZ"),
            make("en-PH-JamesNeural", "Male", "General", "Friendly, Positive", "en-PH"),
            make("en-PH-RosaNeural", "Female", "General", "Friendly, Positive", "en-PH"),
            make("en-SG-LunaNeural", "Female", "General", "Friendly, Positive", "en-SG"),
            make("en-SG-WayneNeural", "Male", "General", "Friendly, Positive", "en-SG"),
            make("en-TZ-ElimuNeural", "Male", "General", "Friendly, Positive", "en-TZ"),
            make("en-TZ-ImaniNeural", "Female", "General", "Friendly, Positive", "en-TZ"),
            make("en-US-AnaNeural", "Female", "Cartoon, Conversation", "Cute", "en-US"),
            make("en-US-AndrewMultilingualNeural", "Male", "Conversation, Copilot", "Warm, Confident, Authentic, Honest", "en-US"),
            make("en-US-AndrewNeural", "Male", "Conversation, Copilot", "Warm, Confident, Authentic, Honest", "en-US"),
            make("en-US-AriaNeural", "Female", "News, Novel", "Positive, Confident", "en-US"),
            make("en-US-AvaMultilingualNeural", "Female", "Conversation, Copilot", "Expressive, Caring, Pleasant, Friendly", "en-US"),
            make("en-US-AvaNeural", "Female", "Conversation, Copilot", "Expressive, Caring, Pleasant, Friendly", "en-US"),
            make("en-US-BrianMultilingualNeural", "Male", "Conversation, Copilot", "Approachable, Casual, Sincere", "en-US"),
            make("en-US-BrianNeural", "Male", "Conversation, Copilot", "Approachable, Casual, Sincere", "en-US"),
            make("en-US-ChristopherNeural", "Male", "News, Novel", "Reliable, Authority", "en-US"),
            make("en-US-EmmaMultilingualNeural", "Female", "Conversation, Copilot", "Cheerful, Clear, Conversational", "en-US"),
            make("en-US-EmmaNeural", "Female", "Conversation, Copilot", "Cheerful, Clear, Conversational", "en-US"),
            make("en-US-EricNeural", "Male", "News, Novel", "Rational", "en-US"),
            make("en-US-GuyNeural", "Male", "News, Novel", "Passion", "en-US"),
            make("en-US-JennyNeural", "Female", "General", "Friendly, Considerate, Comfort", "en-US"),
            make("en-US-MichelleNeural", "Female", "News, Novel", "Friendly, Pleasant", "en-US"),
            make("en-US-RogerNeural", "Male", "News, Novel", "Lively", "en-US"),
            make("en-US-SteffanNeural", "Male", "News, Novel", "Rational", "en-US"),
            make("en-ZA-LeahNeural", "Female", "General", "Friendly, Positive", "en-ZA"),
            make("en-ZA-LukeNeural", "Male", "General", "Friendly, Positive", "en-ZA"),
        ],
        "en-au": [
            make("en-AU-NatashaNeural", "Female", "General", "Friendly, Positive", "en-AU"),
            make("en-AU-WilliamMultilingualNeural", "Male", "General", "Friendly, Positive", "en-AU"),
        ],
        "en-ca": [
            make("en-CA-ClaraNeural", "Female", "General", "Friendly, Positive", "en-CA"),
            make("en-CA-LiamNeural", "Male", "General", "Friendly, Positive", "en-CA"),
        ],
        "en-gb": [
            make("en-GB-LibbyNeural", "Female", "General", "Friendly, Positive", "en-GB"),
            make("en-GB-MaisieNeural", "Female", "General", "Friendly, Positive", "en-GB"),
            make("en-GB-RyanNeural", "Male", "General", "Friendly, Positive", "en-GB"),
            make("en-GB-SoniaNeural", "Female", "General", "Friendly, Positive", "en-GB"),
            make("en-GB-ThomasNeural", "Male", "General", "Friendly, Positive", "en-GB"),
        ],
        "en-hk": [
            make("en-HK-SamNeural", "Male", "General", "Friendly, Positive", "en-HK"),
            make("en-HK-YanNeural", "Female", "General", "Friendly, Positive", "en-HK"),
        ],
        "en-ie": [
            make("en-IE-ConnorNeural", "Male", "General", "Friendly, Positive", "en-IE"),
            make("en-IE-EmilyNeural", "Female", "General", "Friendly, Positive", "en-IE"),
        ],
        "en-in": [
            make("en-IN-NeerjaExpressiveNeural", "Female", "General", "Friendly, Positive", "en-IN"),
            make("en-IN-NeerjaNeural", "Female", "General", "Friendly, Positive", "en-IN"),
            make("en-IN-PrabhatNeural", "Male", "General", "Friendly, Positive", "en-IN"),
        ],
        "en-ke": [
            make("en-KE-AsiliaNeural", "Female", "General", "Friendly, Positive", "en-KE"),
            make("en-KE-ChilembaNeural", "Male", "General", "Friendly, Positive", "en-KE"),
        ],
        "en-ng": [
            make("en-NG-AbeoNeural", "Male", "General", "Friendly, Positive", "en-NG"),
            make("en-NG-EzinneNeural", "Female", "General", "Friendly, Positive", "en-NG"),
        ],
        "en-nz": [
            make("en-NZ-MitchellNeural", "Male", "General", "Friendly, Positive", "en-NZ"),
            make("en-NZ-MollyNeural", "Female", "General", "Friendly, Positive", "en-NZ"),
        ],
        "en-ph": [
            make("en-PH-JamesNeural", "Male", "General", "Friendly, Positive", "en-PH"),
            make("en-PH-RosaNeural", "Female", "General", "Friendly, Positive", "en-PH"),
        ],
        "en-sg": [
            make("en-SG-LunaNeural", "Female", "General", "Friendly, Positive", "en-SG"),
            make("en-SG-WayneNeural", "Male", "General", "Friendly, Positive", "en-SG"),
        ],
        "en-tz": [
            make("en-TZ-ElimuNeural", "Male", "General", "Friendly, Positive", "en-TZ"),
            make("en-TZ-ImaniNeural", "Female", "General", "Friendly, Positive", "en-TZ"),
        ],
        "en-us": [
            make("en-US-AnaNeural", "Female", "Cartoon, Conversation", "Cute", "en-US"),
            make("en-US-AndrewMultilingualNeural", "Male", "Conversation, Copilot", "Warm, Confident, Authentic, Honest", "en-US"),
            make("en-US-AndrewNeural", "Male", "Conversation, Copilot", "Warm, Confident, Authentic, Honest", "en-US"),
            make("en-US-AriaNeural", "Female", "News, Novel", "Positive, Confident", "en-US"),
            make("en-US-AvaMultilingualNeural", "Female", "Conversation, Copilot", "Expressive, Caring, Pleasant, Friendly", "en-US"),
            make("en-US-AvaNeural", "Female", "Conversation, Copilot", "Expressive, Caring, Pleasant, Friendly", "en-US"),
            make("en-US-BrianMultilingualNeural", "Male", "Conversation, Copilot", "Approachable, Casual, Sincere", "en-US"),
            make("en-US-BrianNeural", "Male", "Conversation, Copilot", "Approachable, Casual, Sincere", "en-US"),
            make("en-US-ChristopherNeural", "Male", "News, Novel", "Reliable, Authority", "en-US"),
            make("en-US-EmmaMultilingualNeural", "Female", "Conversation, Copilot", "Cheerful, Clear, Conversational", "en-US"),
            make("en-US-EmmaNeural", "Female", "Conversation, Copilot", "Cheerful, Clear, Conversational", "en-US"),
            make("en-US-EricNeural", "Male", "News, Novel", "Rational", "en-US"),
            make("en-US-GuyNeural", "Male", "News, Novel", "Passion", "en-US"),
            make("en-US-JennyNeural", "Female", "General", "Friendly, Considerate, Comfort", "en-US"),
            make("en-US-MichelleNeural", "Female", "News, Novel", "Friendly, Pleasant", "en-US"),
            make("en-US-RogerNeural", "Male", "News, Novel", "Lively", "en-US"),
            make("en-US-SteffanNeural", "Male", "News, Novel", "Rational", "en-US"),
        ],
        "en-za": [
            make("en-ZA-LeahNeural", "Female", "General", "Friendly, Positive", "en-ZA"),
            make("en-ZA-LukeNeural", "Male", "General", "Friendly, Positive", "en-ZA"),
        ],
        "es": [
            make("es-AR-ElenaNeural", "Female", "General", "Friendly, Positive", "es-AR"),
            make("es-AR-TomasNeural", "Male", "General", "Friendly, Positive", "es-AR"),
            make("es-BO-MarceloNeural", "Male", "General", "Friendly, Positive", "es-BO"),
            make("es-BO-SofiaNeural", "Female", "General", "Friendly, Positive", "es-BO"),
            make("es-CL-CatalinaNeural", "Female", "General", "Friendly, Positive", "es-CL"),
            make("es-CL-LorenzoNeural", "Male", "General", "Friendly, Positive", "es-CL"),
            make("es-CO-GonzaloNeural", "Male", "General", "Friendly, Positive", "es-CO"),
            make("es-CO-SalomeNeural", "Female", "General", "Friendly, Positive", "es-CO"),
            make("es-CR-JuanNeural", "Male", "General", "Friendly, Positive", "es-CR"),
            make("es-CR-MariaNeural", "Female", "General", "Friendly, Positive", "es-CR"),
            make("es-CU-BelkysNeural", "Female", "General", "Friendly, Positive", "es-CU"),
            make("es-CU-ManuelNeural", "Male", "General", "Friendly, Positive", "es-CU"),
            make("es-DO-EmilioNeural", "Male", "General", "Friendly, Positive", "es-DO"),
            make("es-DO-RamonaNeural", "Female", "General", "Friendly, Positive", "es-DO"),
            make("es-EC-AndreaNeural", "Female", "General", "Friendly, Positive", "es-EC"),
            make("es-EC-LuisNeural", "Male", "General", "Friendly, Positive", "es-EC"),
            make("es-ES-AlvaroNeural", "Male", "General", "Friendly, Positive", "es-ES"),
            make("es-ES-ElviraNeural", "Female", "General", "Friendly, Positive", "es-ES"),
            make("es-ES-XimenaNeural", "Female", "General", "Friendly, Positive", "es-ES"),
            make("es-GQ-JavierNeural", "Male", "General", "Friendly, Positive", "es-GQ"),
            make("es-GQ-TeresaNeural", "Female", "General", "Friendly, Positive", "es-GQ"),
            make("es-GT-AndresNeural", "Male", "General", "Friendly, Positive", "es-GT"),
            make("es-GT-MartaNeural", "Female", "General", "Friendly, Positive", "es-GT"),
            make("es-HN-CarlosNeural", "Male", "General", "Friendly, Positive", "es-HN"),
            make("es-HN-KarlaNeural", "Female", "General", "Friendly, Positive", "es-HN"),
            make("es-MX-DaliaNeural", "Female", "General", "Friendly, Positive", "es-MX"),
            make("es-MX-JorgeNeural", "Male", "General", "Friendly, Positive", "es-MX"),
            make("es-NI-FedericoNeural", "Male", "General", "Friendly, Positive", "es-NI"),
            make("es-NI-YolandaNeural", "Female", "General", "Friendly, Positive", "es-NI"),
            make("es-PA-MargaritaNeural", "Female", "General", "Friendly, Positive", "es-PA"),
            make("es-PA-RobertoNeural", "Male", "General", "Friendly, Positive", "es-PA"),
            make("es-PE-AlexNeural", "Male", "General", "Friendly, Positive", "es-PE"),
            make("es-PE-CamilaNeural", "Female", "General", "Friendly, Positive", "es-PE"),
            make("es-PR-KarinaNeural", "Female", "General", "Friendly, Positive", "es-PR"),
            make("es-PR-VictorNeural", "Male", "General", "Friendly, Positive", "es-PR"),
            make("es-PY-MarioNeural", "Male", "General", "Friendly, Positive", "es-PY"),
            make("es-PY-TaniaNeural", "Female", "General", "Friendly, Positive", "es-PY"),
            make("es-SV-LorenaNeural", "Female", "General", "Friendly, Positive", "es-SV"),
            make("es-SV-RodrigoNeural", "Male", "General", "Friendly, Positive", "es-SV"),
            make("es-US-AlonsoNeural", "Male", "General", "Friendly, Positive", "es-US"),
            make("es-US-PalomaNeural", "Female", "General", "Friendly, Positive", "es-US"),
            make("es-UY-MateoNeural", "Male", "General", "Friendly, Positive", "es-UY"),
            make("es-UY-ValentinaNeural", "Female", "General", "Friendly, Positive", "es-UY"),
            make("es-VE-PaolaNeural", "Female", "General", "Friendly, Positive", "es-VE"),
            make("es-VE-SebastianNeural", "Male", "General", "Friendly, Positive", "es-VE"),
        ],
        "es-ar": [
            make("es-AR-ElenaNeural", "Female", "General", "Friendly, Positive", "es-AR"),
            make("es-AR-TomasNeural", "Male", "General", "Friendly, Positive", "es-AR"),
        ],
        "es-bo": [
            make("es-BO-MarceloNeural", "Male", "General", "Friendly, Positive", "es-BO"),
            make("es-BO-SofiaNeural", "Female", "General", "Friendly, Positive", "es-BO"),
        ],
        "es-cl": [
            make("es-CL-CatalinaNeural", "Female", "General", "Friendly, Positive", "es-CL"),
            make("es-CL-LorenzoNeural", "Male", "General", "Friendly, Positive", "es-CL"),
        ],
        "es-co": [
            make("es-CO-GonzaloNeural", "Male", "General", "Friendly, Positive", "es-CO"),
            make("es-CO-SalomeNeural", "Female", "General", "Friendly, Positive", "es-CO"),
        ],
        "es-cr": [
            make("es-CR-JuanNeural", "Male", "General", "Friendly, Positive", "es-CR"),
            make("es-CR-MariaNeural", "Female", "General", "Friendly, Positive", "es-CR"),
        ],
        "es-cu": [
            make("es-CU-BelkysNeural", "Female", "General", "Friendly, Positive", "es-CU"),
            make("es-CU-ManuelNeural", "Male", "General", "Friendly, Positive", "es-CU"),
        ],
        "es-do": [
            make("es-DO-EmilioNeural", "Male", "General", "Friendly, Positive", "es-DO"),
            make("es-DO-RamonaNeural", "Female", "General", "Friendly, Positive", "es-DO"),
        ],
        "es-ec": [
            make("es-EC-AndreaNeural", "Female", "General", "Friendly, Positive", "es-EC"),
            make("es-EC-LuisNeural", "Male", "General", "Friendly, Positive", "es-EC"),
        ],
        "es-es": [
            make("es-ES-AlvaroNeural", "Male", "General", "Friendly, Positive", "es-ES"),
            make("es-ES-ElviraNeural", "Female", "General", "Friendly, Positive", "es-ES"),
            make("es-ES-XimenaNeural", "Female", "General", "Friendly, Positive", "es-ES"),
        ],
        "es-gq": [
            make("es-GQ-JavierNeural", "Male", "General", "Friendly, Positive", "es-GQ"),
            make("es-GQ-TeresaNeural", "Female", "General", "Friendly, Positive", "es-GQ"),
        ],
        "es-gt": [
            make("es-GT-AndresNeural", "Male", "General", "Friendly, Positive", "es-GT"),
            make("es-GT-MartaNeural", "Female", "General", "Friendly, Positive", "es-GT"),
        ],
        "es-hn": [
            make("es-HN-CarlosNeural", "Male", "General", "Friendly, Positive", "es-HN"),
            make("es-HN-KarlaNeural", "Female", "General", "Friendly, Positive", "es-HN"),
        ],
        "es-mx": [
            make("es-MX-DaliaNeural", "Female", "General", "Friendly, Positive", "es-MX"),
            make("es-MX-JorgeNeural", "Male", "General", "Friendly, Positive", "es-MX"),
        ],
        "es-ni": [
            make("es-NI-FedericoNeural", "Male", "General", "Friendly, Positive", "es-NI"),
            make("es-NI-YolandaNeural", "Female", "General", "Friendly, Positive", "es-NI"),
        ],
        "es-pa": [
            make("es-PA-MargaritaNeural", "Female", "General", "Friendly, Positive", "es-PA"),
            make("es-PA-RobertoNeural", "Male", "General", "Friendly, Positive", "es-PA"),
        ],
        "es-pe": [
            make("es-PE-AlexNeural", "Male", "General", "Friendly, Positive", "es-PE"),
            make("es-PE-CamilaNeural", "Female", "General", "Friendly, Positive", "es-PE"),
        ],
        "es-pr": [
            make("es-PR-KarinaNeural", "Female", "General", "Friendly, Positive", "es-PR"),
            make("es-PR-VictorNeural", "Male", "General", "Friendly, Positive", "es-PR"),
        ],
        "es-py": [
            make("es-PY-MarioNeural", "Male", "General", "Friendly, Positive", "es-PY"),
            make("es-PY-TaniaNeural", "Female", "General", "Friendly, Positive", "es-PY"),
        ],
        "es-sv": [
            make("es-SV-LorenaNeural", "Female", "General", "Friendly, Positive", "es-SV"),
            make("es-SV-RodrigoNeural", "Male", "General", "Friendly, Positive", "es-SV"),
        ],
        "es-us": [
            make("es-US-AlonsoNeural", "Male", "General", "Friendly, Positive", "es-US"),
            make("es-US-PalomaNeural", "Female", "General", "Friendly, Positive", "es-US"),
        ],
        "es-uy": [
            make("es-UY-MateoNeural", "Male", "General", "Friendly, Positive", "es-UY"),
            make("es-UY-ValentinaNeural", "Female", "General", "Friendly, Positive", "es-UY"),
        ],
        "es-ve": [
            make("es-VE-PaolaNeural", "Female", "General", "Friendly, Positive", "es-VE"),
            make("es-VE-SebastianNeural", "Male", "General", "Friendly, Positive", "es-VE"),
        ],
        "et": [
            make("et-EE-AnuNeural", "Female", "General", "Friendly, Positive", "et-EE"),
            make("et-EE-KertNeural", "Male", "General", "Friendly, Positive", "et-EE"),
        ],
        "et-ee": [
            make("et-EE-AnuNeural", "Female", "General", "Friendly, Positive", "et-EE"),
            make("et-EE-KertNeural", "Male", "General", "Friendly, Positive", "et-EE"),
        ],
        "fa": [
            make("fa-IR-DilaraNeural", "Female", "General", "Friendly, Positive", "fa-IR"),
            make("fa-IR-FaridNeural", "Male", "General", "Friendly, Positive", "fa-IR"),
        ],
        "fa-ir": [
            make("fa-IR-DilaraNeural", "Female", "General", "Friendly, Positive", "fa-IR"),
            make("fa-IR-FaridNeural", "Male", "General", "Friendly, Positive", "fa-IR"),
        ],
        "fi": [
            make("fi-FI-HarriNeural", "Male", "General", "Friendly, Positive", "fi-FI"),
            make("fi-FI-NooraNeural", "Female", "General", "Friendly, Positive", "fi-FI"),
        ],
        "fi-fi": [
            make("fi-FI-HarriNeural", "Male", "General", "Friendly, Positive", "fi-FI"),
            make("fi-FI-NooraNeural", "Female", "General", "Friendly, Positive", "fi-FI"),
        ],
        "fil": [
            make("fil-PH-AngeloNeural", "Male", "General", "Friendly, Positive", "fil-PH"),
            make("fil-PH-BlessicaNeural", "Female", "General", "Friendly, Positive", "fil-PH"),
        ],
        "fil-ph": [
            make("fil-PH-AngeloNeural", "Male", "General", "Friendly, Positive", "fil-PH"),
            make("fil-PH-BlessicaNeural", "Female", "General", "Friendly, Positive", "fil-PH"),
        ],
        "fr": [
            make("fr-BE-CharlineNeural", "Female", "General", "Friendly, Positive", "fr-BE"),
            make("fr-BE-GerardNeural", "Male", "General", "Friendly, Positive", "fr-BE"),
            make("fr-CA-AntoineNeural", "Male", "General", "Friendly, Positive", "fr-CA"),
            make("fr-CA-JeanNeural", "Male", "General", "Friendly, Positive", "fr-CA"),
            make("fr-CA-SylvieNeural", "Female", "General", "Friendly, Positive", "fr-CA"),
            make("fr-CA-ThierryNeural", "Male", "General", "Friendly, Positive", "fr-CA"),
            make("fr-CH-ArianeNeural", "Female", "General", "Friendly, Positive", "fr-CH"),
            make("fr-CH-FabriceNeural", "Male", "General", "Friendly, Positive", "fr-CH"),
            make("fr-FR-DeniseNeural", "Female", "General", "Friendly, Positive", "fr-FR"),
            make("fr-FR-EloiseNeural", "Female", "General", "Friendly, Positive", "fr-FR"),
            make("fr-FR-HenriNeural", "Male", "General", "Friendly, Positive", "fr-FR"),
            make("fr-FR-RemyMultilingualNeural", "Male", "General", "Friendly, Positive", "fr-FR"),
            make("fr-FR-VivienneMultilingualNeural", "Female", "General", "Friendly, Positive", "fr-FR"),
        ],
        "fr-be": [
            make("fr-BE-CharlineNeural", "Female", "General", "Friendly, Positive", "fr-BE"),
            make("fr-BE-GerardNeural", "Male", "General", "Friendly, Positive", "fr-BE"),
        ],
        "fr-ca": [
            make("fr-CA-AntoineNeural", "Male", "General", "Friendly, Positive", "fr-CA"),
            make("fr-CA-JeanNeural", "Male", "General", "Friendly, Positive", "fr-CA"),
            make("fr-CA-SylvieNeural", "Female", "General", "Friendly, Positive", "fr-CA"),
            make("fr-CA-ThierryNeural", "Male", "General", "Friendly, Positive", "fr-CA"),
        ],
        "fr-ch": [
            make("fr-CH-ArianeNeural", "Female", "General", "Friendly, Positive", "fr-CH"),
            make("fr-CH-FabriceNeural", "Male", "General", "Friendly, Positive", "fr-CH"),
        ],
        "fr-fr": [
            make("fr-FR-DeniseNeural", "Female", "General", "Friendly, Positive", "fr-FR"),
            make("fr-FR-EloiseNeural", "Female", "General", "Friendly, Positive", "fr-FR"),
            make("fr-FR-HenriNeural", "Male", "General", "Friendly, Positive", "fr-FR"),
            make("fr-FR-RemyMultilingualNeural", "Male", "General", "Friendly, Positive", "fr-FR"),
            make("fr-FR-VivienneMultilingualNeural", "Female", "General", "Friendly, Positive", "fr-FR"),
        ],
        "ga": [
            make("ga-IE-ColmNeural", "Male", "General", "Friendly, Positive", "ga-IE"),
            make("ga-IE-OrlaNeural", "Female", "General", "Friendly, Positive", "ga-IE"),
        ],
        "ga-ie": [
            make("ga-IE-ColmNeural", "Male", "General", "Friendly, Positive", "ga-IE"),
            make("ga-IE-OrlaNeural", "Female", "General", "Friendly, Positive", "ga-IE"),
        ],
        "gl": [
            make("gl-ES-RoiNeural", "Male", "General", "Friendly, Positive", "gl-ES"),
            make("gl-ES-SabelaNeural", "Female", "General", "Friendly, Positive", "gl-ES"),
        ],
        "gl-es": [
            make("gl-ES-RoiNeural", "Male", "General", "Friendly, Positive", "gl-ES"),
            make("gl-ES-SabelaNeural", "Female", "General", "Friendly, Positive", "gl-ES"),
        ],
        "gu": [
            make("gu-IN-DhwaniNeural", "Female", "General", "Friendly, Positive", "gu-IN"),
            make("gu-IN-NiranjanNeural", "Male", "General", "Friendly, Positive", "gu-IN"),
        ],
        "gu-in": [
            make("gu-IN-DhwaniNeural", "Female", "General", "Friendly, Positive", "gu-IN"),
            make("gu-IN-NiranjanNeural", "Male", "General", "Friendly, Positive", "gu-IN"),
        ],
        "he": [
            make("he-IL-AvriNeural", "Male", "General", "Friendly, Positive", "he-IL"),
            make("he-IL-HilaNeural", "Female", "General", "Friendly, Positive", "he-IL"),
        ],
        "he-il": [
            make("he-IL-AvriNeural", "Male", "General", "Friendly, Positive", "he-IL"),
            make("he-IL-HilaNeural", "Female", "General", "Friendly, Positive", "he-IL"),
        ],
        "hi": [
            make("hi-IN-MadhurNeural", "Male", "General", "Friendly, Positive", "hi-IN"),
            make("hi-IN-SwaraNeural", "Female", "General", "Friendly, Positive", "hi-IN"),
        ],
        "hi-in": [
            make("hi-IN-MadhurNeural", "Male", "General", "Friendly, Positive", "hi-IN"),
            make("hi-IN-SwaraNeural", "Female", "General", "Friendly, Positive", "hi-IN"),
        ],
        "hr": [
            make("hr-HR-GabrijelaNeural", "Female", "General", "Friendly, Positive", "hr-HR"),
            make("hr-HR-SreckoNeural", "Male", "General", "Friendly, Positive", "hr-HR"),
        ],
        "hr-hr": [
            make("hr-HR-GabrijelaNeural", "Female", "General", "Friendly, Positive", "hr-HR"),
            make("hr-HR-SreckoNeural", "Male", "General", "Friendly, Positive", "hr-HR"),
        ],
        "hu": [
            make("hu-HU-NoemiNeural", "Female", "General", "Friendly, Positive", "hu-HU"),
            make("hu-HU-TamasNeural", "Male", "General", "Friendly, Positive", "hu-HU"),
        ],
        "hu-hu": [
            make("hu-HU-NoemiNeural", "Female", "General", "Friendly, Positive", "hu-HU"),
            make("hu-HU-TamasNeural", "Male", "General", "Friendly, Positive", "hu-HU"),
        ],
        "id": [
            make("id-ID-ArdiNeural", "Male", "General", "Friendly, Positive", "id-ID"),
            make("id-ID-GadisNeural", "Female", "General", "Friendly, Positive", "id-ID"),
        ],
        "id-id": [
            make("id-ID-ArdiNeural", "Male", "General", "Friendly, Positive", "id-ID"),
            make("id-ID-GadisNeural", "Female", "General", "Friendly, Positive", "id-ID"),
        ],
        "is": [
            make("is-IS-GudrunNeural", "Female", "General", "Friendly, Positive", "is-IS"),
            make("is-IS-GunnarNeural", "Male", "General", "Friendly, Positive", "is-IS"),
        ],
        "is-is": [
            make("is-IS-GudrunNeural", "Female", "General", "Friendly, Positive", "is-IS"),
            make("is-IS-GunnarNeural", "Male", "General", "Friendly, Positive", "is-IS"),
        ],
        "it": [
            make("it-IT-DiegoNeural", "Male", "General", "Friendly, Positive", "it-IT"),
            make("it-IT-ElsaNeural", "Female", "General", "Friendly, Positive", "it-IT"),
            make("it-IT-GiuseppeMultilingualNeural", "Male", "General", "Friendly, Positive", "it-IT"),
            make("it-IT-IsabellaNeural", "Female", "General", "Friendly, Positive", "it-IT"),
        ],
        "it-it": [
            make("it-IT-DiegoNeural", "Male", "General", "Friendly, Positive", "it-IT"),
            make("it-IT-ElsaNeural", "Female", "General", "Friendly, Positive", "it-IT"),
            make("it-IT-GiuseppeMultilingualNeural", "Male", "General", "Friendly, Positive", "it-IT"),
            make("it-IT-IsabellaNeural", "Female", "General", "Friendly, Positive", "it-IT"),
        ],
        "iu": [
            make("iu-Cans-CA-SiqiniqNeural", "Female", "General", "Friendly, Positive", "iu-Cans-CA"),
            make("iu-Cans-CA-TaqqiqNeural", "Male", "General", "Friendly, Positive", "iu-Cans-CA"),
            make("iu-Latn-CA-SiqiniqNeural", "Female", "General", "Friendly, Positive", "iu-Latn-CA"),
            make("iu-Latn-CA-TaqqiqNeural", "Male", "General", "Friendly, Positive", "iu-Latn-CA"),
        ],
        "iu-cans-ca": [
            make("iu-Cans-CA-SiqiniqNeural", "Female", "General", "Friendly, Positive", "iu-Cans-CA"),
            make("iu-Cans-CA-TaqqiqNeural", "Male", "General", "Friendly, Positive", "iu-Cans-CA"),
        ],
        "iu-latn-ca": [
            make("iu-Latn-CA-SiqiniqNeural", "Female", "General", "Friendly, Positive", "iu-Latn-CA"),
            make("iu-Latn-CA-TaqqiqNeural", "Male", "General", "Friendly, Positive", "iu-Latn-CA"),
        ],
        "ja": [
            make("ja-JP-KeitaNeural", "Male", "General", "Friendly, Positive", "ja-JP"),
            make("ja-JP-NanamiNeural", "Female", "General", "Friendly, Positive", "ja-JP"),
        ],
        "ja-jp": [
            make("ja-JP-KeitaNeural", "Male", "General", "Friendly, Positive", "ja-JP"),
            make("ja-JP-NanamiNeural", "Female", "General", "Friendly, Positive", "ja-JP"),
        ],
        "jv": [
            make("jv-ID-DimasNeural", "Male", "General", "Friendly, Positive", "jv-ID"),
            make("jv-ID-SitiNeural", "Female", "General", "Friendly, Positive", "jv-ID"),
        ],
        "jv-id": [
            make("jv-ID-DimasNeural", "Male", "General", "Friendly, Positive", "jv-ID"),
            make("jv-ID-SitiNeural", "Female", "General", "Friendly, Positive", "jv-ID"),
        ],
        "ka": [
            make("ka-GE-EkaNeural", "Female", "General", "Friendly, Positive", "ka-GE"),
            make("ka-GE-GiorgiNeural", "Male", "General", "Friendly, Positive", "ka-GE"),
        ],
        "ka-ge": [
            make("ka-GE-EkaNeural", "Female", "General", "Friendly, Positive", "ka-GE"),
            make("ka-GE-GiorgiNeural", "Male", "General", "Friendly, Positive", "ka-GE"),
        ],
        "kk": [
            make("kk-KZ-AigulNeural", "Female", "General", "Friendly, Positive", "kk-KZ"),
            make("kk-KZ-DauletNeural", "Male", "General", "Friendly, Positive", "kk-KZ"),
        ],
        "kk-kz": [
            make("kk-KZ-AigulNeural", "Female", "General", "Friendly, Positive", "kk-KZ"),
            make("kk-KZ-DauletNeural", "Male", "General", "Friendly, Positive", "kk-KZ"),
        ],
        "km": [
            make("km-KH-PisethNeural", "Male", "General", "Friendly, Positive", "km-KH"),
            make("km-KH-SreymomNeural", "Female", "General", "Friendly, Positive", "km-KH"),
        ],
        "km-kh": [
            make("km-KH-PisethNeural", "Male", "General", "Friendly, Positive", "km-KH"),
            make("km-KH-SreymomNeural", "Female", "General", "Friendly, Positive", "km-KH"),
        ],
        "kn": [
            make("kn-IN-GaganNeural", "Male", "General", "Friendly, Positive", "kn-IN"),
            make("kn-IN-SapnaNeural", "Female", "General", "Friendly, Positive", "kn-IN"),
        ],
        "kn-in": [
            make("kn-IN-GaganNeural", "Male", "General", "Friendly, Positive", "kn-IN"),
            make("kn-IN-SapnaNeural", "Female", "General", "Friendly, Positive", "kn-IN"),
        ],
        "ko": [
            make("ko-KR-HyunsuMultilingualNeural", "Male", "General", "Friendly, Positive", "ko-KR"),
            make("ko-KR-InJoonNeural", "Male", "General", "Friendly, Positive", "ko-KR"),
            make("ko-KR-SunHiNeural", "Female", "General", "Friendly, Positive", "ko-KR"),
        ],
        "ko-kr": [
            make("ko-KR-HyunsuMultilingualNeural", "Male", "General", "Friendly, Positive", "ko-KR"),
            make("ko-KR-InJoonNeural", "Male", "General", "Friendly, Positive", "ko-KR"),
            make("ko-KR-SunHiNeural", "Female", "General", "Friendly, Positive", "ko-KR"),
        ],
        "lo": [
            make("lo-LA-ChanthavongNeural", "Male", "General", "Friendly, Positive", "lo-LA"),
            make("lo-LA-KeomanyNeural", "Female", "General", "Friendly, Positive", "lo-LA"),
        ],
        "lo-la": [
            make("lo-LA-ChanthavongNeural", "Male", "General", "Friendly, Positive", "lo-LA"),
            make("lo-LA-KeomanyNeural", "Female", "General", "Friendly, Positive", "lo-LA"),
        ],
        "lt": [
            make("lt-LT-LeonasNeural", "Male", "General", "Friendly, Positive", "lt-LT"),
            make("lt-LT-OnaNeural", "Female", "General", "Friendly, Positive", "lt-LT"),
        ],
        "lt-lt": [
            make("lt-LT-LeonasNeural", "Male", "General", "Friendly, Positive", "lt-LT"),
            make("lt-LT-OnaNeural", "Female", "General", "Friendly, Positive", "lt-LT"),
        ],
        "lv": [
            make("lv-LV-EveritaNeural", "Female", "General", "Friendly, Positive", "lv-LV"),
            make("lv-LV-NilsNeural", "Male", "General", "Friendly, Positive", "lv-LV"),
        ],
        "lv-lv": [
            make("lv-LV-EveritaNeural", "Female", "General", "Friendly, Positive", "lv-LV"),
            make("lv-LV-NilsNeural", "Male", "General", "Friendly, Positive", "lv-LV"),
        ],
        "mk": [
            make("mk-MK-AleksandarNeural", "Male", "General", "Friendly, Positive", "mk-MK"),
            make("mk-MK-MarijaNeural", "Female", "General", "Friendly, Positive", "mk-MK"),
        ],
        "mk-mk": [
            make("mk-MK-AleksandarNeural", "Male", "General", "Friendly, Positive", "mk-MK"),
            make("mk-MK-MarijaNeural", "Female", "General", "Friendly, Positive", "mk-MK"),
        ],
        "ml": [
            make("ml-IN-MidhunNeural", "Male", "General", "Friendly, Positive", "ml-IN"),
            make("ml-IN-SobhanaNeural", "Female", "General", "Friendly, Positive", "ml-IN"),
        ],
        "ml-in": [
            make("ml-IN-MidhunNeural", "Male", "General", "Friendly, Positive", "ml-IN"),
            make("ml-IN-SobhanaNeural", "Female", "General", "Friendly, Positive", "ml-IN"),
        ],
        "mn": [
            make("mn-MN-BataaNeural", "Male", "General", "Friendly, Positive", "mn-MN"),
            make("mn-MN-YesuiNeural", "Female", "General", "Friendly, Positive", "mn-MN"),
        ],
        "mn-mn": [
            make("mn-MN-BataaNeural", "Male", "General", "Friendly, Positive", "mn-MN"),
            make("mn-MN-YesuiNeural", "Female", "General", "Friendly, Positive", "mn-MN"),
        ],
        "mr": [
            make("mr-IN-AarohiNeural", "Female", "General", "Friendly, Positive", "mr-IN"),
            make("mr-IN-ManoharNeural", "Male", "General", "Friendly, Positive", "mr-IN"),
        ],
        "mr-in": [
            make("mr-IN-AarohiNeural", "Female", "General", "Friendly, Positive", "mr-IN"),
            make("mr-IN-ManoharNeural", "Male", "General", "Friendly, Positive", "mr-IN"),
        ],
        "ms": [
            make("ms-MY-OsmanNeural", "Male", "General", "Friendly, Positive", "ms-MY"),
            make("ms-MY-YasminNeural", "Female", "General", "Friendly, Positive", "ms-MY"),
        ],
        "ms-my": [
            make("ms-MY-OsmanNeural", "Male", "General", "Friendly, Positive", "ms-MY"),
            make("ms-MY-YasminNeural", "Female", "General", "Friendly, Positive", "ms-MY"),
        ],
        "mt": [
            make("mt-MT-GraceNeural", "Female", "General", "Friendly, Positive", "mt-MT"),
            make("mt-MT-JosephNeural", "Male", "General", "Friendly, Positive", "mt-MT"),
        ],
        "mt-mt": [
            make("mt-MT-GraceNeural", "Female", "General", "Friendly, Positive", "mt-MT"),
            make("mt-MT-JosephNeural", "Male", "General", "Friendly, Positive", "mt-MT"),
        ],
        "my": [
            make("my-MM-NilarNeural", "Female", "General", "Friendly, Positive", "my-MM"),
            make("my-MM-ThihaNeural", "Male", "General", "Friendly, Positive", "my-MM"),
        ],
        "my-mm": [
            make("my-MM-NilarNeural", "Female", "General", "Friendly, Positive", "my-MM"),
            make("my-MM-ThihaNeural", "Male", "General", "Friendly, Positive", "my-MM"),
        ],
        "nb": [
            make("nb-NO-FinnNeural", "Male", "General", "Friendly, Positive", "nb-NO"),
            make("nb-NO-PernilleNeural", "Female", "General", "Friendly, Positive", "nb-NO"),
        ],
        "nb-no": [
            make("nb-NO-FinnNeural", "Male", "General", "Friendly, Positive", "nb-NO"),
            make("nb-NO-PernilleNeural", "Female", "General", "Friendly, Positive", "nb-NO"),
        ],
        "ne": [
            make("ne-NP-HemkalaNeural", "Female", "General", "Friendly, Positive", "ne-NP"),
            make("ne-NP-SagarNeural", "Male", "General", "Friendly, Positive", "ne-NP"),
        ],
        "ne-np": [
            make("ne-NP-HemkalaNeural", "Female", "General", "Friendly, Positive", "ne-NP"),
            make("ne-NP-SagarNeural", "Male", "General", "Friendly, Positive", "ne-NP"),
        ],
        "nl": [
            make("nl-BE-ArnaudNeural", "Male", "General", "Friendly, Positive", "nl-BE"),
            make("nl-BE-DenaNeural", "Female", "General", "Friendly, Positive", "nl-BE"),
            make("nl-NL-ColetteNeural", "Female", "General", "Friendly, Positive", "nl-NL"),
            make("nl-NL-FennaNeural", "Female", "General", "Friendly, Positive", "nl-NL"),
            make("nl-NL-MaartenNeural", "Male", "General", "Friendly, Positive", "nl-NL"),
        ],
        "nl-be": [
            make("nl-BE-ArnaudNeural", "Male", "General", "Friendly, Positive", "nl-BE"),
            make("nl-BE-DenaNeural", "Female", "General", "Friendly, Positive", "nl-BE"),
        ],
        "nl-nl": [
            make("nl-NL-ColetteNeural", "Female", "General", "Friendly, Positive", "nl-NL"),
            make("nl-NL-FennaNeural", "Female", "General", "Friendly, Positive", "nl-NL"),
            make("nl-NL-MaartenNeural", "Male", "General", "Friendly, Positive", "nl-NL"),
        ],
        "pl": [
            make("pl-PL-MarekNeural", "Male", "General", "Friendly, Positive", "pl-PL"),
            make("pl-PL-ZofiaNeural", "Female", "General", "Friendly, Positive", "pl-PL"),
        ],
        "pl-pl": [
            make("pl-PL-MarekNeural", "Male", "General", "Friendly, Positive", "pl-PL"),
            make("pl-PL-ZofiaNeural", "Female", "General", "Friendly, Positive", "pl-PL"),
        ],
        "ps": [
            make("ps-AF-GulNawazNeural", "Male", "General", "Friendly, Positive", "ps-AF"),
            make("ps-AF-LatifaNeural", "Female", "General", "Friendly, Positive", "ps-AF"),
        ],
        "ps-af": [
            make("ps-AF-GulNawazNeural", "Male", "General", "Friendly, Positive", "ps-AF"),
            make("ps-AF-LatifaNeural", "Female", "General", "Friendly, Positive", "ps-AF"),
        ],
        "pt": [
            make("pt-BR-AntonioNeural", "Male", "General", "Friendly, Positive", "pt-BR"),
            make("pt-BR-FranciscaNeural", "Female", "General", "Friendly, Positive", "pt-BR"),
            make("pt-BR-ThalitaMultilingualNeural", "Female", "General", "Friendly, Positive", "pt-BR"),
            make("pt-PT-DuarteNeural", "Male", "General", "Friendly, Positive", "pt-PT"),
            make("pt-PT-RaquelNeural", "Female", "General", "Friendly, Positive", "pt-PT"),
        ],
        "pt-br": [
            make("pt-BR-AntonioNeural", "Male", "General", "Friendly, Positive", "pt-BR"),
            make("pt-BR-FranciscaNeural", "Female", "General", "Friendly, Positive", "pt-BR"),
            make("pt-BR-ThalitaMultilingualNeural", "Female", "General", "Friendly, Positive", "pt-BR"),
        ],
        "pt-pt": [
            make("pt-PT-DuarteNeural", "Male", "General", "Friendly, Positive", "pt-PT"),
            make("pt-PT-RaquelNeural", "Female", "General", "Friendly, Positive", "pt-PT"),
        ],
        "ro": [
            make("ro-RO-AlinaNeural", "Female", "General", "Friendly, Positive", "ro-RO"),
            make("ro-RO-EmilNeural", "Male", "General", "Friendly, Positive", "ro-RO"),
        ],
        "ro-ro": [
            make("ro-RO-AlinaNeural", "Female", "General", "Friendly, Positive", "ro-RO"),
            make("ro-RO-EmilNeural", "Male", "General", "Friendly, Positive", "ro-RO"),
        ],
        "ru": [
            make("ru-RU-DmitryNeural", "Male", "General", "Friendly, Positive", "ru-RU"),
            make("ru-RU-SvetlanaNeural", "Female", "General", "Friendly, Positive", "ru-RU"),
        ],
        "ru-ru": [
            make("ru-RU-DmitryNeural", "Male", "General", "Friendly, Positive", "ru-RU"),
            make("ru-RU-SvetlanaNeural", "Female", "General", "Friendly, Positive", "ru-RU"),
        ],
        "si": [
            make("si-LK-SameeraNeural", "Male", "General", "Friendly, Positive", "si-LK"),
            make("si-LK-ThiliniNeural", "Female", "General", "Friendly, Positive", "si-LK"),
        ],
        "si-lk": [
            make("si-LK-SameeraNeural", "Male", "General", "Friendly, Positive", "si-LK"),
            make("si-LK-ThiliniNeural", "Female", "General", "Friendly, Positive", "si-LK"),
        ],
        "sk": [
            make("sk-SK-LukasNeural", "Male", "General", "Friendly, Positive", "sk-SK"),
            make("sk-SK-ViktoriaNeural", "Female", "General", "Friendly, Positive", "sk-SK"),
        ],
        "sk-sk": [
            make("sk-SK-LukasNeural", "Male", "General", "Friendly, Positive", "sk-SK"),
            make("sk-SK-ViktoriaNeural", "Female", "General", "Friendly, Positive", "sk-SK"),
        ],
        "sl": [
            make("sl-SI-PetraNeural", "Female", "General", "Friendly, Positive", "sl-SI"),
            make("sl-SI-RokNeural", "Male", "General", "Friendly, Positive", "sl-SI"),
        ],
        "sl-si": [
            make("sl-SI-PetraNeural", "Female", "General", "Friendly, Positive", "sl-SI"),
            make("sl-SI-RokNeural", "Male", "General", "Friendly, Positive", "sl-SI"),
        ],
        "so": [
            make("so-SO-MuuseNeural", "Male", "General", "Friendly, Positive", "so-SO"),
            make("so-SO-UbaxNeural", "Female", "General", "Friendly, Positive", "so-SO"),
        ],
        "so-so": [
            make("so-SO-MuuseNeural", "Male", "General", "Friendly, Positive", "so-SO"),
            make("so-SO-UbaxNeural", "Female", "General", "Friendly, Positive", "so-SO"),
        ],
        "sq": [
            make("sq-AL-AnilaNeural", "Female", "General", "Friendly, Positive", "sq-AL"),
            make("sq-AL-IlirNeural", "Male", "General", "Friendly, Positive", "sq-AL"),
        ],
        "sq-al": [
            make("sq-AL-AnilaNeural", "Female", "General", "Friendly, Positive", "sq-AL"),
            make("sq-AL-IlirNeural", "Male", "General", "Friendly, Positive", "sq-AL"),
        ],
        "sr": [
            make("sr-RS-NicholasNeural", "Male", "General", "Friendly, Positive", "sr-RS"),
            make("sr-RS-SophieNeural", "Female", "General", "Friendly, Positive", "sr-RS"),
        ],
        "sr-rs": [
            make("sr-RS-NicholasNeural", "Male", "General", "Friendly, Positive", "sr-RS"),
            make("sr-RS-SophieNeural", "Female", "General", "Friendly, Positive", "sr-RS"),
        ],
        "su": [
            make("su-ID-JajangNeural", "Male", "General", "Friendly, Positive", "su-ID"),
            make("su-ID-TutiNeural", "Female", "General", "Friendly, Positive", "su-ID"),
        ],
        "su-id": [
            make("su-ID-JajangNeural", "Male", "General", "Friendly, Positive", "su-ID"),
            make("su-ID-TutiNeural", "Female", "General", "Friendly, Positive", "su-ID"),
        ],
        "sv": [
            make("sv-SE-MattiasNeural", "Male", "General", "Friendly, Positive", "sv-SE"),
            make("sv-SE-SofieNeural", "Female", "General", "Friendly, Positive", "sv-SE"),
        ],
        "sv-se": [
            make("sv-SE-MattiasNeural", "Male", "General", "Friendly, Positive", "sv-SE"),
            make("sv-SE-SofieNeural", "Female", "General", "Friendly, Positive", "sv-SE"),
        ],
        "sw": [
            make("sw-KE-RafikiNeural", "Male", "General", "Friendly, Positive", "sw-KE"),
            make("sw-KE-ZuriNeural", "Female", "General", "Friendly, Positive", "sw-KE"),
            make("sw-TZ-DaudiNeural", "Male", "General", "Friendly, Positive", "sw-TZ"),
            make("sw-TZ-RehemaNeural", "Female", "General", "Friendly, Positive", "sw-TZ"),
        ],
        "sw-ke": [
            make("sw-KE-RafikiNeural", "Male", "General", "Friendly, Positive", "sw-KE"),
            make("sw-KE-ZuriNeural", "Female", "General", "Friendly, Positive", "sw-KE"),
        ],
        "sw-tz": [
            make("sw-TZ-DaudiNeural", "Male", "General", "Friendly, Positive", "sw-TZ"),
            make("sw-TZ-RehemaNeural", "Female", "General", "Friendly, Positive", "sw-TZ"),
        ],
        "ta": [
            make("ta-IN-PallaviNeural", "Female", "General", "Friendly, Positive", "ta-IN"),
            make("ta-IN-ValluvarNeural", "Male", "General", "Friendly, Positive", "ta-IN"),
            make("ta-LK-KumarNeural", "Male", "General", "Friendly, Positive", "ta-LK"),
            make("ta-LK-SaranyaNeural", "Female", "General", "Friendly, Positive", "ta-LK"),
            make("ta-MY-KaniNeural", "Female", "General", "Friendly, Positive", "ta-MY"),
            make("ta-MY-SuryaNeural", "Male", "General", "Friendly, Positive", "ta-MY"),
            make("ta-SG-AnbuNeural", "Male", "General", "Friendly, Positive", "ta-SG"),
            make("ta-SG-VenbaNeural", "Female", "General", "Friendly, Positive", "ta-SG"),
        ],
        "ta-in": [
            make("ta-IN-PallaviNeural", "Female", "General", "Friendly, Positive", "ta-IN"),
            make("ta-IN-ValluvarNeural", "Male", "General", "Friendly, Positive", "ta-IN"),
        ],
        "ta-lk": [
            make("ta-LK-KumarNeural", "Male", "General", "Friendly, Positive", "ta-LK"),
            make("ta-LK-SaranyaNeural", "Female", "General", "Friendly, Positive", "ta-LK"),
        ],
        "ta-my": [
            make("ta-MY-KaniNeural", "Female", "General", "Friendly, Positive", "ta-MY"),
            make("ta-MY-SuryaNeural", "Male", "General", "Friendly, Positive", "ta-MY"),
        ],
        "ta-sg": [
            make("ta-SG-AnbuNeural", "Male", "General", "Friendly, Positive", "ta-SG"),
            make("ta-SG-VenbaNeural", "Female", "General", "Friendly, Positive", "ta-SG"),
        ],
        "te": [
            make("te-IN-MohanNeural", "Male", "General", "Friendly, Positive", "te-IN"),
            make("te-IN-ShrutiNeural", "Female", "General", "Friendly, Positive", "te-IN"),
        ],
        "te-in": [
            make("te-IN-MohanNeural", "Male", "General", "Friendly, Positive", "te-IN"),
            make("te-IN-ShrutiNeural", "Female", "General", "Friendly, Positive", "te-IN"),
        ],
        "th": [
            make("th-TH-NiwatNeural", "Male", "General", "Friendly, Positive", "th-TH"),
            make("th-TH-PremwadeeNeural", "Female", "General", "Friendly, Positive", "th-TH"),
        ],
        "th-th": [
            make("th-TH-NiwatNeural", "Male", "General", "Friendly, Positive", "th-TH"),
            make("th-TH-PremwadeeNeural", "Female", "General", "Friendly, Positive", "th-TH"),
        ],
        "tr": [
            make("tr-TR-AhmetNeural", "Male", "General", "Friendly, Positive", "tr-TR"),
            make("tr-TR-EmelNeural", "Female", "General", "Friendly, Positive", "tr-TR"),
        ],
        "tr-tr": [
            make("tr-TR-AhmetNeural", "Male", "General", "Friendly, Positive", "tr-TR"),
            make("tr-TR-EmelNeural", "Female", "General", "Friendly, Positive", "tr-TR"),
        ],
        "uk": [
            make("uk-UA-OstapNeural", "Male", "General", "Friendly, Positive", "uk-UA"),
            make("uk-UA-PolinaNeural", "Female", "General", "Friendly, Positive", "uk-UA"),
        ],
        "uk-ua": [
            make("uk-UA-OstapNeural", "Male", "General", "Friendly, Positive", "uk-UA"),
            make("uk-UA-PolinaNeural", "Female", "General", "Friendly, Positive", "uk-UA"),
        ],
        "ur": [
            make("ur-IN-GulNeural", "Female", "General", "Friendly, Positive", "ur-IN"),
            make("ur-IN-SalmanNeural", "Male", "General", "Friendly, Positive", "ur-IN"),
            make("ur-PK-AsadNeural", "Male", "General", "Friendly, Positive", "ur-PK"),
            make("ur-PK-UzmaNeural", "Female", "General", "Friendly, Positive", "ur-PK"),
        ],
        "ur-in": [
            make("ur-IN-GulNeural", "Female", "General", "Friendly, Positive", "ur-IN"),
            make("ur-IN-SalmanNeural", "Male", "General", "Friendly, Positive", "ur-IN"),
        ],
        "ur-pk": [
            make("ur-PK-AsadNeural", "Male", "General", "Friendly, Positive", "ur-PK"),
            make("ur-PK-UzmaNeural", "Female", "General", "Friendly, Positive", "ur-PK"),
        ],
        "uz": [
            make("uz-UZ-MadinaNeural", "Female", "General", "Friendly, Positive", "uz-UZ"),
            make("uz-UZ-SardorNeural", "Male", "General", "Friendly, Positive", "uz-UZ"),
        ],
        "uz-uz": [
            make("uz-UZ-MadinaNeural", "Female", "General", "Friendly, Positive", "uz-UZ"),
            make("uz-UZ-SardorNeural", "Male", "General", "Friendly, Positive", "uz-UZ"),
        ],
        "vi": [
            make("vi-VN-HoaiMyNeural", "Female", "General", "Friendly, Positive", "vi-VN"),
            make("vi-VN-NamMinhNeural", "Male", "General", "Friendly, Positive", "vi-VN"),
        ],
        "vi-vn": [
            make("vi-VN-HoaiMyNeural", "Female", "General", "Friendly, Positive", "vi-VN"),
            make("vi-VN-NamMinhNeural", "Male", "General", "Friendly, Positive", "vi-VN"),
        ],
        "zh": [
            make("zh-CN-XiaoxiaoNeural", "Female", "News, Novel", "Warm", "zh-CN"),
            make("zh-CN-XiaoyiNeural", "Female", "Cartoon, Novel", "Lively", "zh-CN"),
            make("zh-CN-YunjianNeural", "Male", "Sports, Novel", "Passion", "zh-CN"),
            make("zh-CN-YunxiNeural", "Male", "Novel", "Lively, Sunshine", "zh-CN"),
            make("zh-CN-YunxiaNeural", "Male", "Cartoon, Novel", "Cute", "zh-CN"),
            make("zh-CN-YunyangNeural", "Male", "News", "Professional, Reliable", "zh-CN"),
            make("zh-CN-liaoning-XiaobeiNeural", "Female", "Dialect", "Humorous", "zh-CN"),
            make("zh-CN-shaanxi-XiaoniNeural", "Female", "Dialect", "Bright", "zh-CN"),
            make("zh-HK-HiuGaaiNeural", "Female", "General", "Friendly, Positive", "zh-HK"),
            make("zh-HK-HiuMaanNeural", "Female", "General", "Friendly, Positive", "zh-HK"),
            make("zh-HK-WanLungNeural", "Male", "General", "Friendly, Positive", "zh-HK"),
            make("zh-TW-HsiaoChenNeural", "Female", "General", "Friendly, Positive", "zh-TW"),
            make("zh-TW-HsiaoYuNeural", "Female", "General", "Friendly, Positive", "zh-TW"),
            make("zh-TW-YunJheNeural", "Male", "General", "Friendly, Positive", "zh-TW"),
        ],
        "zh-cn": [
            make("zh-CN-XiaoxiaoNeural", "Female", "News, Novel", "Warm", "zh-CN"),
            make("zh-CN-XiaoyiNeural", "Female", "Cartoon, Novel", "Lively", "zh-CN"),
            make("zh-CN-YunjianNeural", "Male", "Sports, Novel", "Passion", "zh-CN"),
            make("zh-CN-YunxiNeural", "Male", "Novel", "Lively, Sunshine", "zh-CN"),
            make("zh-CN-YunxiaNeural", "Male", "Cartoon, Novel", "Cute", "zh-CN"),
            make("zh-CN-YunyangNeural", "Male", "News", "Professional, Reliable", "zh-CN"),
            make("zh-CN-liaoning-XiaobeiNeural", "Female", "Dialect", "Humorous", "zh-CN"),
            make("zh-CN-shaanxi-XiaoniNeural", "Female", "Dialect", "Bright", "zh-CN"),
        ],
        "zh-hk": [
            make("zh-HK-HiuGaaiNeural", "Female", "General", "Friendly, Positive", "zh-HK"),
            make("zh-HK-HiuMaanNeural", "Female", "General", "Friendly, Positive", "zh-HK"),
            make("zh-HK-WanLungNeural", "Male", "General", "Friendly, Positive", "zh-HK"),
        ],
        "zh-tw": [
            make("zh-TW-HsiaoChenNeural", "Female", "General", "Friendly, Positive", "zh-TW"),
            make("zh-TW-HsiaoYuNeural", "Female", "General", "Friendly, Positive", "zh-TW"),
            make("zh-TW-YunJheNeural", "Male", "General", "Friendly, Positive", "zh-TW"),
        ],
        "zu": [
            make("zu-ZA-ThandoNeural", "Female", "General", "Friendly, Positive", "zu-ZA"),
            make("zu-ZA-ThembaNeural", "Male", "General", "Friendly, Positive", "zu-ZA"),
        ],
        "zu-za": [
            make("zu-ZA-ThandoNeural", "Female", "General", "Friendly, Positive", "zu-ZA"),
            make("zu-ZA-ThembaNeural", "Male", "General", "Friendly, Positive", "zu-ZA"),
        ],
    ]

    // MARK: - Helper Functions

    /// Normalize language code to lowercase
    private static func normalizeLanguageCode(_ code: String) -> String {
        return code.lowercased()
    }

    // MARK: - Public API

    public func getAvailableVoices(languageCode: String?) async throws -> [String: [EdgeTTSVoice]] {
        // If no language code filter, return all voices directly
        guard let filterCode = languageCode else {
            return Self.hardcodedVoicesData
        }

        // Normalize filter code and do exact match lookup
        let normalizedFilter = Self.normalizeLanguageCode(filterCode)

        // Return exact match only
        if let voices = Self.hardcodedVoicesData[normalizedFilter] {
            return [normalizedFilter: voices]
        }

        return [:]
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

