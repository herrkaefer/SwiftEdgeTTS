import XCTest
@testable import SwiftEdgeTTS

@available(macOS 12.0, iOS 15.0, *)
final class EdgeTTSServiceTests: XCTestCase {

    var service: EdgeTTSService!
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        service = EdgeTTSService()

        // Create temporary directory for test outputs
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftEdgeTTSTests")
            .appendingPathComponent(UUID().uuidString)

        try? FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    override func tearDown() {
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)
        service = nil
        super.tearDown()
    }

    func testGetAvailableVoices() async throws {
        do {
            let voices = try await service.getAvailableVoices()

            XCTAssertFalse(voices.isEmpty, "Should return at least one voice")

            // Check that voices have required properties
            let firstVoice = try XCTUnwrap(voices.first)
            XCTAssertFalse(firstVoice.name.isEmpty, "Voice should have a name")
            XCTAssertFalse(firstVoice.locale.isEmpty, "Voice should have a locale")
        } catch EdgeTTSError.networkError(let error as NSError) where error.code == 401 {
            throw XCTSkip("Voices API returned 401; skipping test due to service restrictions")
        } catch EdgeTTSError.invalidResponse {
            throw XCTSkip("Voices API changed response format; skipping test")
        }
    }

    func testSynthesizeText() async throws {
        let text = "Hello, this is a test."
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("test.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertEqual(resultURL, outputURL, "Should return the output URL")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "Audio file should be created"
        )

        // Check file size (should not be empty)
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Audio file should not be empty")
    }

    func testSynthesizeMultipleTexts() async throws {
        let texts = [
            "First test sentence.",
            "Second test sentence.",
            "Third test sentence."
        ]
        let voice = "en-US-JennyNeural"

        let results = try await service.synthesizeMultiple(
            texts: texts,
            voice: voice,
            outputDirectory: tempDirectory
        )

        XCTAssertEqual(results.count, texts.count, "Should return same number of results as inputs")

        // Check that files were created
        let fileCount = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "mp3" }.count

        XCTAssertGreaterThanOrEqual(fileCount, texts.count, "Should create at least one audio file per text")
    }

    func testSynthesizeWithInvalidVoice() async throws {
        let text = "Test"
        let invalidVoice = "invalid-voice-name"
        let outputURL = tempDirectory.appendingPathComponent("test.mp3")

        // This might succeed or fail depending on Edge-TTS API behavior
        // We just want to ensure it doesn't crash
        do {
            _ = try await service.synthesize(
                text: text,
                voice: invalidVoice,
                outputURL: outputURL
            )
        } catch {
            // Expected to potentially fail with invalid voice
            XCTAssertTrue(error is EdgeTTSError, "Should throw EdgeTTSError")
        }
    }

    func testSynthesizeEmptyText() async throws {
        let text = ""
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("test.mp3")

        // Empty text should fail validation
        do {
            _ = try await service.synthesize(
                text: text,
                voice: voice,
                outputURL: outputURL
            )
            XCTFail("Should throw error for empty text")
        } catch {
            XCTAssertTrue(error is EdgeTTSError, "Should throw EdgeTTSError for empty text")
        }
    }

    // MARK: - Multi-language Tests

    func testSynthesizeChineseMandarin() async throws {
        let text = "你好，世界！这是一个中文语音测试。"
        let voice = "zh-CN-XiaoxiaoNeural"
        let outputURL = tempDirectory.appendingPathComponent("chinese_mandarin.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Chinese audio file should be created")
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Chinese audio file should not be empty")
    }

    func testSynthesizeChineseTraditional() async throws {
        let text = "你好，世界！這是一個繁體中文語音測試。"
        let voice = "zh-TW-HsiaoChenNeural"
        let outputURL = tempDirectory.appendingPathComponent("chinese_traditional.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Traditional Chinese audio file should be created")
    }

    func testSynthesizeJapanese() async throws {
        let text = "こんにちは、世界！これは日本語の音声テストです。"
        let voice = "ja-JP-NanamiNeural"
        let outputURL = tempDirectory.appendingPathComponent("japanese.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Japanese audio file should be created")
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Japanese audio file should not be empty")
    }

    func testSynthesizeSpanish() async throws {
        let text = "Hola, mundo. Esta es una prueba de voz en español."
        let voice = "es-ES-ElviraNeural"
        let outputURL = tempDirectory.appendingPathComponent("spanish.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Spanish audio file should be created")
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Spanish audio file should not be empty")
    }

    func testSynthesizeFrench() async throws {
        let text = "Bonjour, le monde. Ceci est un test de voix en français."
        let voice = "fr-FR-DeniseNeural"
        let outputURL = tempDirectory.appendingPathComponent("french.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "French audio file should be created")
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "French audio file should not be empty")
    }

    func testSynthesizeGerman() async throws {
        let text = "Hallo, Welt. Dies ist ein deutscher Sprachtest."
        let voice = "de-DE-KatjaNeural"
        let outputURL = tempDirectory.appendingPathComponent("german.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "German audio file should be created")
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "German audio file should not be empty")
    }

    func testSynthesizeKorean() async throws {
        let text = "안녕하세요, 세계! 이것은 한국어 음성 테스트입니다."
        let voice = "ko-KR-SunHiNeural"
        let outputURL = tempDirectory.appendingPathComponent("korean.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Korean audio file should be created")
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Korean audio file should not be empty")
    }

    func testSynthesizeItalian() async throws {
        let text = "Ciao, mondo. Questo è un test vocale in italiano."
        let voice = "it-IT-ElsaNeural"
        let outputURL = tempDirectory.appendingPathComponent("italian.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Italian audio file should be created")
    }

    func testSynthesizePortuguese() async throws {
        let text = "Olá, mundo. Este é um teste de voz em português."
        let voice = "pt-BR-FranciscaNeural"
        let outputURL = tempDirectory.appendingPathComponent("portuguese.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Portuguese audio file should be created")
    }

    func testSynthesizeRussian() async throws {
        let text = "Привет, мир! Это тест голоса на русском языке."
        let voice = "ru-RU-SvetlanaNeural"
        let outputURL = tempDirectory.appendingPathComponent("russian.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Russian audio file should be created")
    }

    // MARK: - Edge Cases

    func testSynthesizeWithSpecialCharacters() async throws {
        let text = "Hello & goodbye! <test> \"quotes\" 'apostrophes'"
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("special_chars.mp3")

        // Should handle special characters without crashing
        do {
            let resultURL = try await service.synthesize(
                text: text,
                voice: voice,
                outputURL: outputURL
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Should handle special characters")
        } catch {
            // Some special characters might cause issues, but shouldn't crash
            XCTAssertTrue(error is EdgeTTSError, "Should throw EdgeTTSError if it fails")
        }
    }

    func testSynthesizeWithEmoji() async throws {
        let text = "Hello 😊 World 🌍 Test"
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("emoji.mp3")

        // Should handle emoji gracefully
        do {
            let resultURL = try await service.synthesize(
                text: text,
                voice: voice,
                outputURL: outputURL
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Should handle emoji")
        } catch {
            // Emoji might not be supported, but shouldn't crash
            XCTAssertTrue(error is EdgeTTSError, "Should throw EdgeTTSError if it fails")
        }
    }

    func testSynthesizeWithWhitespaceOnly() async throws {
        let text = "   \n\t  "
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("whitespace.mp3")

        // Should fail validation for whitespace-only text
        do {
            _ = try await service.synthesize(
                text: text,
                voice: voice,
                outputURL: outputURL
            )
            XCTFail("Should throw error for whitespace-only text")
        } catch {
            XCTAssertTrue(error is EdgeTTSError, "Should throw EdgeTTSError for whitespace-only text")
        }
    }

    func testSynthesizeWithEmptyVoice() async throws {
        let text = "Test"
        let voice = ""
        let outputURL = tempDirectory.appendingPathComponent("test.mp3")

        // Should fail validation for empty voice
        do {
            _ = try await service.synthesize(
                text: text,
                voice: voice,
                outputURL: outputURL
            )
            XCTFail("Should throw error for empty voice")
        } catch EdgeTTSError.invalidVoice {
            // Expected
        } catch {
            XCTFail("Should throw invalidVoice error, got \(error)")
        }
    }

    func testSynthesizeMultipleWithEmptyArray() async throws {
        let texts: [String] = []
        let voice = "en-US-JennyNeural"

        let results = try await service.synthesizeMultiple(
            texts: texts,
            voice: voice,
            outputDirectory: tempDirectory
        )

        XCTAssertEqual(results.count, 0, "Should return empty array for empty input")
    }

    // MARK: - Prosody Parameters Tests

    func testSynthesizeWithRate() async throws {
        let text = "Hello, this is a test with slower rate."
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("test_rate.mp3")

        let resultURL = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL,
            rate: "-50%",
            volume: nil,
            pitch: nil
        )

        XCTAssertEqual(resultURL, outputURL, "Should return the output URL")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "Audio file should be created"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Audio file should not be empty")
    }

    func testSynthesizeWithVolume() async throws {
        let text = "Hello, this is a test with lower volume."
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("test_volume.mp3")

        _ = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL,
            rate: nil,
            volume: "-50%",
            pitch: nil
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "Audio file should be created"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Audio file should not be empty")
    }

    func testSynthesizeWithPitch() async throws {
        let text = "Hello, this is a test with lower pitch."
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("test_pitch.mp3")

        _ = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL,
            rate: nil,
            volume: nil,
            pitch: "-50Hz"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "Audio file should be created"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Audio file should not be empty")
    }

    func testSynthesizeWithAllProsodyParameters() async throws {
        let text = "Hello, this is a test with all prosody parameters adjusted."
        let voice = "en-US-JennyNeural"
        let outputURL = tempDirectory.appendingPathComponent("test_all_prosody.mp3")

        _ = try await service.synthesize(
            text: text,
            voice: voice,
            outputURL: outputURL,
            rate: "+25%",
            volume: "+10%",
            pitch: "+20Hz"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "Audio file should be created"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Audio file should not be empty")
    }

    func testSynthesizeMultipleWithProsodyParameters() async throws {
        let texts = [
            "First test sentence.",
            "Second test sentence.",
            "Third test sentence."
        ]
        let voice = "en-US-JennyNeural"

        let results = try await service.synthesizeMultiple(
            texts: texts,
            voice: voice,
            outputDirectory: tempDirectory,
            rate: "-30%",
            volume: nil,
            pitch: nil
        )

        XCTAssertEqual(results.count, texts.count, "Should return same number of results as inputs")

        let fileCount = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "mp3" }.count

        XCTAssertGreaterThanOrEqual(fileCount, texts.count, "Should create at least one audio file per text")
    }

    func testSynthesizeMultipleWithDifferentLanguages() async throws {
        let texts = [
            "Hello, world!",
            "你好，世界！",
            "こんにちは、世界！",
            "Hola, mundo!"
        ]
        let voices = [
            "en-US-JennyNeural",
            "zh-CN-XiaoxiaoNeural",
            "ja-JP-NanamiNeural",
            "es-ES-ElviraNeural"
        ]

        // Test each language separately
        for (index, text) in texts.enumerated() {
            let voice = voices[index]
            let outputURL = tempDirectory.appendingPathComponent("multi_lang_\(index).mp3")

            let resultURL = try await service.synthesize(
                text: text,
                voice: voice,
                outputURL: outputURL
            )

            XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Should create file for \(voice)")
        }
    }

    func testGetVoicesFiltersByLanguage() async throws {
        do {
            let voices = try await service.getAvailableVoices()

            // Test that we can find voices for multiple languages
            let englishVoices = voices.filter { $0.locale.hasPrefix("en") }
            let chineseVoices = voices.filter { $0.locale.hasPrefix("zh") }
            let japaneseVoices = voices.filter { $0.locale.hasPrefix("ja") }

            XCTAssertFalse(englishVoices.isEmpty, "Should have English voices")
            XCTAssertFalse(chineseVoices.isEmpty, "Should have Chinese voices")
            XCTAssertFalse(japaneseVoices.isEmpty, "Should have Japanese voices")

            // Test voice properties
            if let englishVoice = englishVoices.first {
                XCTAssertFalse(englishVoice.name.isEmpty, "Voice should have name")
                XCTAssertFalse(englishVoice.shortName.isEmpty, "Voice should have shortName")
                XCTAssertFalse(englishVoice.gender.isEmpty, "Voice should have gender")
            }
        } catch EdgeTTSError.networkError(let error as NSError) where error.code == 401 {
            throw XCTSkip("Voices API returned 401; skipping test due to service restrictions")
        } catch EdgeTTSError.invalidResponse {
            throw XCTSkip("Voices API changed response format; skipping test")
        }
    }
}

