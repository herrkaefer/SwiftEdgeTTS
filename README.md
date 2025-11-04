# SwiftEdgeTTS

[![CI](https://github.com/herrkaefer/SwiftEdgeTTS/actions/workflows/ci.yml/badge.svg)](https://github.com/herrkaefer/SwiftEdgeTTS/actions/workflows/ci.yml)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fherrkaefer%2FSwiftEdgeTTS%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/herrkaefer/SwiftEdgeTTS)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fherrkaefer%2FSwiftEdgeTTS%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/herrkaefer/SwiftEdgeTTS)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Swift Package for Microsoft Edge Text-to-Speech (TTS) API integration. This package provides a clean, simple interface to generate high-quality audio files from text using Edge-TTS without any Python dependencies.

## Features

- ✅ **Pure Swift implementation** - no external dependencies or Python required
- ✅ **Simple, clean API** - easy to use async/await interface
- ✅ **400+ neural voices** across 100+ languages and locales
- ✅ **High-quality MP3 audio** output (24kHz, 48kbitrate)
- ✅ **Automatic SSML generation** with proper XML escaping
- ✅ **Adjustable speech parameters** - rate, volume, and pitch control
- ✅ **Thread-safe** token caching and clock synchronization
- ✅ **iOS 15+** and **macOS 12+** support
- ✅ **Comprehensive error handling** with detailed error types

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/herrkaefer/SwiftEdgeTTS.git", from: "1.0.0")
]
```

Or in Xcode:
1. File → Add Packages...
2. Enter the repository URL: `https://github.com/herrkaefer/SwiftEdgeTTS.git`
3. Select the version or branch

## Quick Start

### Basic Usage

```swift
import SwiftEdgeTTS

// Create a TTS service instance
let ttsService = EdgeTTSService()

// Synthesize text to audio file
let outputURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("output.mp3")

do {
    let audioURL = try await ttsService.synthesize(
        text: "Hello, world!",
        voice: "en-US-JennyNeural",
        outputURL: outputURL
    )
    print("Audio saved to: \(audioURL.path)")
} catch {
    print("Error: \(error)")
}
```

### Adjusting Speech Parameters

You can customize the speech rate, volume, and pitch:

```swift
// Slower speech rate
let audioURL = try await ttsService.synthesize(
    text: "Hello, world!",
    voice: "en-US-JennyNeural",
    outputURL: outputURL,
    rate: "-50%",      // 50% slower
    volume: nil,
    pitch: nil
)

// Lower volume
let audioURL = try await ttsService.synthesize(
    text: "Hello, world!",
    voice: "en-US-JennyNeural",
    outputURL: outputURL,
    rate: nil,
    volume: "-50%",    // 50% quieter
    pitch: nil
)

// Lower pitch
let audioURL = try await ttsService.synthesize(
    text: "Hello, world!",
    voice: "en-US-JennyNeural",
    outputURL: outputURL,
    rate: nil,
    volume: nil,
    pitch: "-50Hz"     // 50Hz lower pitch
)

// All parameters together
let audioURL = try await ttsService.synthesize(
    text: "Hello, world!",
    voice: "en-US-JennyNeural",
    outputURL: outputURL,
    rate: "+25%",      // 25% faster
    volume: "+10%",    // 10% louder
    pitch: "+20Hz"     // 20Hz higher pitch
)
```

### Batch Synthesis

Generate multiple audio files at once:

```swift
let texts = [
    "First sentence.",
    "Second sentence.",
    "Third sentence."
]

let outputDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("audio")

let results = try await ttsService.synthesizeMultiple(
    texts: texts,
    voice: "en-US-JennyNeural",
    outputDirectory: outputDirectory
)

// With prosody parameters
let results = try await ttsService.synthesizeMultiple(
    texts: texts,
    voice: "en-US-JennyNeural",
    outputDirectory: outputDirectory,
    rate: "-30%",      // Slower speech rate
    volume: nil,
    pitch: nil
)

// Process results (nil indicates a failed synthesis)
for (index, url) in results.enumerated() {
    if let url = url {
        print("File \(index + 1) saved: \(url.path)")
    } else {
        print("File \(index + 1) failed to generate")
    }
}
```

### Get Available Voices

Discover available voices and filter by language:

```swift
let voices = try await ttsService.getAvailableVoices()

// Filter by language
let chineseVoices = voices.filter { $0.locale.hasPrefix("zh") }
let englishVoices = voices.filter { $0.locale.hasPrefix("en") }

// Print voice information
for voice in chineseVoices.prefix(5) {
    print("\(voice.name) - \(voice.locale) - \(voice.gender)")
}
```

### Multi-language Examples

```swift
// Chinese (Mandarin)
try await ttsService.synthesize(
    text: "你好，世界！",
    voice: "zh-CN-XiaoxiaoNeural",
    outputURL: chineseURL
)

// Japanese
try await ttsService.synthesize(
    text: "こんにちは、世界！",
    voice: "ja-JP-NanamiNeural",
    outputURL: japaneseURL
)

// Spanish
try await ttsService.synthesize(
    text: "Hola, mundo.",
    voice: "es-ES-ElviraNeural",
    outputURL: spanishURL
)

// French
try await ttsService.synthesize(
    text: "Bonjour, le monde.",
    voice: "fr-FR-DeniseNeural",
    outputURL: frenchURL
)

// German
try await ttsService.synthesize(
    text: "Hallo, Welt.",
    voice: "de-DE-KatjaNeural",
    outputURL: germanURL
)
```

## API Reference

### `EdgeTTSClient` Protocol

```swift
protocol EdgeTTSClient {
    func synthesize(text: String, voice: String, outputURL: URL, rate: String?, volume: String?, pitch: String?) async throws -> URL
    func synthesizeMultiple(texts: [String], voice: String, outputDirectory: URL, rate: String?, volume: String?, pitch: String?) async throws -> [URL?]
    func getAvailableVoices() async throws -> [EdgeTTSVoice]
}
```

**Prosody Parameters:**
- `rate`: Optional speech rate adjustment (e.g., `"+50%"`, `"-50%"`). Default is `"+0%"`
- `volume`: Optional volume adjustment (e.g., `"+50%"`, `"-50%"`). Default is `"+0%"`
- `pitch`: Optional pitch adjustment (e.g., `"+50Hz"`, `"-50Hz"`). Default is `"+0Hz"`

For backward compatibility, the protocol extension provides convenience methods without prosody parameters that use default values.

### `EdgeTTSService`

The default implementation of `EdgeTTSClient`.

```swift
let client = EdgeTTSService()
```

### Error Handling

The package uses `EdgeTTSError` for error handling:

```swift
enum EdgeTTSError: Error {
    case synthesisFailed
    case invalidVoice
    case networkError(Error)
    case invalidResponse
    case fileWriteFailed(Error)
}
```

Example:

```swift
do {
    let audioURL = try await client.synthesize(
        text: "Hello",
        voice: "en-US-JennyNeural",
        outputURL: outputURL
    )
} catch EdgeTTSError.synthesisFailed {
    print("Synthesis failed")
} catch EdgeTTSError.networkError(let error) {
    print("Network error: \(error)")
} catch {
    print("Unknown error: \(error)")
}
```

## Speech Parameters

### Rate, Volume, and Pitch

You can adjust the speech rate, volume, and pitch using the optional parameters:

- **Rate**: Controls speech speed. Format: `"+X%"` (faster) or `"-X%"` (slower)
  - Examples: `"+50%"` (50% faster), `"-50%"` (50% slower)

- **Volume**: Controls speech volume. Format: `"+X%"` (louder) or `"-X%"` (quieter)
  - Examples: `"+50%"` (50% louder), `"-50%"` (50% quieter)

- **Pitch**: Controls voice pitch. Format: `"+XHz"` (higher) or `"-XHz"` (lower)
  - Examples: `"+50Hz"` (50Hz higher), `"-50Hz"` (50Hz lower)

These parameters are optional and default to `"+0%"` (rate/volume) or `"+0Hz"` (pitch) if not specified. All parameters use SSML prosody tags internally, similar to the Python [edge-tts](https://github.com/rany2/edge-tts) library.

## Voice Selection

Voices follow the format: `{locale}-{VoiceName}Neural`

### Popular Voice Examples

#### English
- `en-US-JennyNeural` - English (US), Female
- `en-US-GuyNeural` - English (US), Male
- `en-GB-LibbyNeural` - English (UK), Female
- `en-AU-NatashaNeural` - English (Australia), Female

#### Chinese
- `zh-CN-XiaoxiaoNeural` - Chinese (Mandarin), Female
- `zh-CN-YunjianNeural` - Chinese (Mandarin), Male
- `zh-TW-HsiaoChenNeural` - Chinese (Taiwan), Female
- `zh-HK-HiuGaaiNeural` - Chinese (Hong Kong), Female

#### Japanese
- `ja-JP-NanamiNeural` - Japanese, Female
- `ja-JP-KeitaNeural` - Japanese, Male

#### Other Languages
- `es-ES-ElviraNeural` - Spanish (Spain), Female
- `fr-FR-DeniseNeural` - French, Female
- `de-DE-KatjaNeural` - German, Female
- `ko-KR-SunHiNeural` - Korean, Female
- `it-IT-ElsaNeural` - Italian, Female
- `pt-BR-FranciscaNeural` - Portuguese (Brazil), Female
- `ru-RU-SvetlanaNeural` - Russian, Female

Use `getAvailableVoices()` to discover all available voices for your use case.

## Error Handling

The package provides detailed error types for better error handling:

```swift
do {
    let audioURL = try await ttsService.synthesize(
        text: "Hello",
        voice: "en-US-JennyNeural",
        outputURL: outputURL
    )
} catch EdgeTTSError.synthesisFailed {
    print("Audio synthesis failed")
} catch EdgeTTSError.invalidVoice {
    print("Invalid voice identifier")
} catch EdgeTTSError.networkError(let error) {
    print("Network error: \(error.localizedDescription)")
} catch EdgeTTSError.fileWriteFailed(let error) {
    print("Failed to write file: \(error.localizedDescription)")
} catch {
    print("Unknown error: \(error)")
}
```

## Custom URLSession

You can provide a custom `URLSession` for advanced configuration (proxy, timeouts, etc.):

```swift
let configuration = URLSessionConfiguration.default
configuration.timeoutIntervalForRequest = 30
configuration.timeoutIntervalForResource = 60

let customSession = URLSession(configuration: configuration)
let ttsService = EdgeTTSService(session: customSession)
```

## Requirements

- iOS 15.0+ / macOS 12.0+
- Swift 5.9+

## Acknowledgments

This work has been inspired by the Python [edge-tts](https://github.com/rany2/edge-tts) library by rany2.

## License

MIT License

Copyright (c) 2024 SwiftEdgeTTS Contributors



