// wtx-transcribe — on-device speech-to-text for the Watch Pilot hub.
//
// Drives Apple's SpeechAnalyzer / SpeechTranscriber stack (macOS 26+). Everything
// happens on the Mac mini: no network, no API key, no one-minute ceiling, and it
// runs from a bare command line binary (no .app bundle, no Info.plist, no TCC
// prompt) so the FastAPI hub can shell out to it.
//
// Usage:
//   wtx-transcribe --input voice.m4a [--format txt|json] [--locale pt-BR] [--timeout 120]
//   wtx-transcribe --list-locales
//   wtx-transcribe --install-assets [--locale pt-BR]
//
// Exit codes: 0 ok · 2 usage · 3 transcriber unavailable · 4 assets missing
//             5 audio/read error · 6 timeout.

import AVFoundation
import Foundation
import Speech

// MARK: - Argument parsing

struct Options {
    var input: String?
    var format = "txt"
    var locale: String?
    var timeout: Double = 120
    var listLocales = false
    var installAssets = false
}

func usage() -> Never {
    FileHandle.standardError.write(
        """
        usage: wtx-transcribe --input <audio> [--format txt|json] [--locale <id>] [--timeout <seconds>]
               wtx-transcribe --list-locales
               wtx-transcribe --install-assets [--locale <id>]

        """.data(using: .utf8)!
    )
    exit(2)
}

func parse(_ argv: [String]) -> Options {
    var options = Options()
    var index = 1
    while index < argv.count {
        let flag = argv[index]
        func value() -> String {
            index += 1
            guard index < argv.count else { usage() }
            return argv[index]
        }
        switch flag {
        case "--input": options.input = value()
        case "--format": options.format = value()
        case "--locale": options.locale = value()
        case "--timeout": options.timeout = Double(value()) ?? 120
        case "--list-locales": options.listLocales = true
        case "--install-assets": options.installAssets = true
        case "-h", "--help": usage()
        default:
            FileHandle.standardError.write("unknown option: \(flag)\n".data(using: .utf8)!)
            usage()
        }
        index += 1
    }
    return options
}

// MARK: - Helpers

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func resolveLocale(_ requested: String?) async -> Locale? {
    let wants = Locale(identifier: requested ?? Locale.current.identifier)
    if let exact = await SpeechTranscriber.supportedLocale(equivalentTo: wants) {
        return exact
    }
    // Fall back through the user's preferred languages, then Portuguese, then English.
    for candidate in Locale.preferredLanguages.map({ Locale(identifier: $0) }) {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
            return match
        }
    }
    let supported = await SpeechTranscriber.supportedLocales
    for wanted in ["pt-BR", "pt-PT", "en-US", "en-GB"] {
        if let match = supported.first(where: { $0.identifier == wanted }) ?? supported.first(where: {
            $0.language.languageCode == Locale(identifier: wanted).language.languageCode
        }) {
            return match
        }
    }
    return supported.first
}

func ensureAssets(for transcriber: SpeechTranscriber) async -> Bool {
    let status = await AssetInventory.status(forModules: [transcriber])
    switch status {
    case .installed:
        return true
    case .unsupported:
        return false
    case .supported, .downloading:
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
                return await AssetInventory.status(forModules: [transcriber]) == .installed
            }
        } catch {
            FileHandle.standardError.write(
                "asset install failed: \(error.localizedDescription)\n".data(using: .utf8)!
            )
        }
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    @unknown default:
        return false
    }
}

/// Collect every result segment until the sequence ends or the element is final.
func collect(_ transcriber: SpeechTranscriber) async throws -> [(String, Double, Double)] {
    var segments: [(String, Double, Double)] = []
    for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let start = result.range.start.seconds
        let end = CMTimeRangeGetEnd(result.range).seconds
        if !text.isEmpty {
            segments.append((text, start.isFinite ? start : 0, end.isFinite ? end : 0))
        }
        if result.isFinal { break }
    }
    return segments
}

func encodeJSON(_ payload: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
}

// MARK: - Entry point

@main
struct WTXTranscribe {
    static func main() async {
        let options = parse(CommandLine.arguments)
        let started = Date()

        if options.listLocales {
            let supported = await SpeechTranscriber.supportedLocales
            let installed = await SpeechTranscriber.installedLocales
            print(encodeJSON([
                "available": SpeechTranscriber.isAvailable,
                "maximum_reserved": AssetInventory.maximumReservedLocales,
                "supported": supported.map(\.identifier).sorted(),
                "installed": installed.map(\.identifier).sorted(),
            ]))
            exit(0)
        }

        guard SpeechTranscriber.isAvailable else {
            fail("SpeechTranscriber is not available on this system", code: 3)
        }

        guard let requestedLocale = await resolveLocale(options.locale) else {
            fail("no supported locale found", code: 4)
        }

        let transcriber = SpeechTranscriber(locale: requestedLocale, preset: .transcription)

        if options.installAssets {
            let ready = await ensureAssets(for: transcriber)
            print(encodeJSON(["locale": requestedLocale.identifier, "assets": ready ? "installed" : "missing"]))
            exit(ready ? 0 : 4)
        }

        guard let input = options.input else { usage() }
        let url = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("input not found: \(url.path)", code: 5)
        }

        guard await ensureAssets(for: transcriber) else {
            fail("speech assets unavailable for \(requestedLocale.identifier)", code: 4)
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            fail("cannot open audio: \(error.localizedDescription)", code: 5)
        }

        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime),
                finishAfterFile: true
            )
        } catch {
            fail("cannot start analyzer: \(error.localizedDescription)", code: 3)
        }

        var segments: [(String, Double, Double)] = []
        let timeout = options.timeout

        await withTaskGroup(of: [(String, Double, Double)].self) { group in
            group.addTask {
                do { return try await collect(transcriber) } catch { return [] }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            if let first = await group.next() {
                segments = first
            }
            group.cancelAll()
        }
        _ = analyzer

        let text = segments.map(\.0).joined(separator: " ")
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let timedOut = text.isEmpty && elapsed >= Int(timeout * 1000) - 500

        if options.format == "json" {
            print(encodeJSON([
                "text": text,
                "locale": requestedLocale.identifier,
                "elapsed_ms": elapsed,
                "segments": segments.map { ["text": $0.0, "start": $0.1, "end": $0.2] },
                "engine": "SpeechAnalyzer/SpeechTranscriber",
            ]))
        } else {
            print(text)
        }

        if timedOut { exit(6) }
        exit(text.isEmpty ? 5 : 0)
    }
}
