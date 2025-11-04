import Foundation

/// Public protocol for Edge-TTS client
@available(macOS 12.0, iOS 15.0, *)
public protocol EdgeTTSClient {
    /// Synthesize text to audio file
    /// - Parameters:
    ///   - text: The text to synthesize
    ///   - voice: The voice identifier (e.g., "en-US-JennyNeural")
    ///   - outputURL: The URL where the audio file should be saved
    ///   - rate: Optional speech rate adjustment (e.g., "+50%", "-50%"). Default is "+0%"
    ///   - volume: Optional volume adjustment (e.g., "+50%", "-50%"). Default is "+0%"
    ///   - pitch: Optional pitch adjustment (e.g., "+50Hz", "-50Hz"). Default is "+0Hz"
    /// - Returns: The URL of the generated audio file
    func synthesize(text: String, voice: String, outputURL: URL, rate: String?, volume: String?, pitch: String?) async throws -> URL

    /// Synthesize multiple texts to audio files
    /// - Parameters:
    ///   - texts: Array of texts to synthesize
    ///   - voice: The voice identifier
    ///   - outputDirectory: Directory where audio files should be saved
    ///   - rate: Optional speech rate adjustment (e.g., "+50%", "-50%"). Default is "+0%"
    ///   - volume: Optional volume adjustment (e.g., "+50%", "-50%"). Default is "+0%"
    ///   - pitch: Optional pitch adjustment (e.g., "+50Hz", "-50Hz"). Default is "+0Hz"
    /// - Returns: Array of URLs for generated audio files (nil for failed ones)
    func synthesizeMultiple(texts: [String], voice: String, outputDirectory: URL, rate: String?, volume: String?, pitch: String?) async throws -> [URL?]

    /// Get available voices from Edge-TTS
    /// - Returns: Array of available voices
    func getAvailableVoices() async throws -> [EdgeTTSVoice]
}

/// Protocol extension to provide default parameter values for backward compatibility
@available(macOS 12.0, iOS 15.0, *)
extension EdgeTTSClient {
    /// Synthesize text to audio file (with default prosody parameters)
    /// - Parameters:
    ///   - text: The text to synthesize
    ///   - voice: The voice identifier (e.g., "en-US-JennyNeural")
    ///   - outputURL: The URL where the audio file should be saved
    /// - Returns: The URL of the generated audio file
    public func synthesize(text: String, voice: String, outputURL: URL) async throws -> URL {
        return try await synthesize(text: text, voice: voice, outputURL: outputURL, rate: nil, volume: nil, pitch: nil)
    }

    /// Synthesize multiple texts to audio files (with default prosody parameters)
    /// - Parameters:
    ///   - texts: Array of texts to synthesize
    ///   - voice: The voice identifier
    ///   - outputDirectory: Directory where audio files should be saved
    /// - Returns: Array of URLs for generated audio files (nil for failed ones)
    public func synthesizeMultiple(texts: [String], voice: String, outputDirectory: URL) async throws -> [URL?] {
        return try await synthesizeMultiple(texts: texts, voice: voice, outputDirectory: outputDirectory, rate: nil, volume: nil, pitch: nil)
    }
}

/// Edge-TTS Voice model
@available(macOS 12.0, iOS 15.0, *)
public struct EdgeTTSVoice: Codable {
    public let name: String
    public let shortName: String
    public let gender: String
    public let locale: String
    public let sampleRate: String
    public let voiceType: String
    public let status: String
    public let wordsPerMinute: String?
    public let friendlyName: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case shortName = "ShortName"
        case gender = "Gender"
        case locale = "Locale"
        case sampleRate = "SampleRate"
        case voiceType = "VoiceType"
        case status = "Status"
        case wordsPerMinute = "WordsPerMinute"
        case friendlyName = "FriendlyName"
    }

    public init(name: String, shortName: String, gender: String, locale: String, sampleRate: String, voiceType: String, status: String, wordsPerMinute: String? = nil, friendlyName: String? = nil) {
        self.name = name
        self.shortName = shortName
        self.gender = gender
        self.locale = locale
        self.sampleRate = sampleRate
        self.voiceType = voiceType
        self.status = status
        self.wordsPerMinute = wordsPerMinute
        self.friendlyName = friendlyName
    }
}

/// Edge-TTS specific errors
@available(macOS 12.0, iOS 15.0, *)
public enum EdgeTTSError: Error, LocalizedError {
    case synthesisFailed
    case invalidVoice
    case networkError(Error)
    case invalidResponse
    case fileWriteFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .synthesisFailed:
            return "Audio synthesis failed"
        case .invalidVoice:
            return "Invalid voice identifier"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .fileWriteFailed(let error):
            return "Failed to write audio file: \(error.localizedDescription)"
        }
    }
}

