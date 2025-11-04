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
    func synthesize(text: String, voice: String, outputURL: URL) async throws -> URL
    func synthesizeMultiple(texts: [String], voice: String, outputDirectory: URL) async throws -> [URL?]
    func getAvailableVoices() async throws -> [EdgeTTSVoice]
}
```

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



