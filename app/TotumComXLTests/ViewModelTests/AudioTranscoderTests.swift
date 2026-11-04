import AVFoundation
import XCTest
@testable import TotumComXLApp

/// Звук, которого macOS не знает (WMA, RealAudio, DTS, VOC), переводится во FLAC, и системный
/// проигрыватель — тот, которым играет просмотрщик, — принимает результат. Играть звук
/// проверка не играет: ей хватает того, что проигрыватель готов.
///
/// ffmpeg — сборка scripts/fetch-ffmpeg.sh в third_party (её же кладёт в бандл launch.sh).
final class AudioTranscoderTests: XCTestCase {

    private let root = FileManager.default.currentDirectoryPath
    private var fixtures: String { root + "/app/TotumComXLTests/Fixtures/Audio/" }
    private var helper: String { root + "/third_party/ffmpeg/ffmpeg" }
    private var cache: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw XCTSkip("ffmpeg не собран — scripts/fetch-ffmpeg.sh")
        }
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("звук-\(UUID().uuidString)")
        let helper = helper
        AudioTranscoder.helperPath = { helper }
        AudioTranscoder.cacheDirectory = cache
        AudioTranscoder.cacheLimit = 1 << 30
    }

    override func tearDown() {
        if let cache { try? FileManager.default.removeItem(at: cache) }
        AudioTranscoder.helperPath = { AudioTranscoder.bundledPath }
        AudioTranscoder.cacheDirectory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.fcxl.filecommander")
            .appendingPathComponent("Audio")
        AudioTranscoder.cacheLimit = 1 << 30
        super.tearDown()
    }

    func test_какиеФайлыПереводятся() {
        XCTAssertTrue(AudioTranscoder.needsTranscoding("/a/песня.wma"))
        XCTAssertTrue(AudioTranscoder.needsTranscoding("/a/ПЕСНЯ.WMA"))
        XCTAssertTrue(AudioTranscoder.needsTranscoding("/a/альбом.ape"))
        XCTAssertFalse(AudioTranscoder.needsTranscoding("/a/песня.mp3"), "MP3 macOS играет сама")
        XCTAssertFalse(AudioTranscoder.needsTranscoding("/a/песня.flac"))
    }

    /// Каждый файл — во FLAC, и проигрыватель готов его играть, той же длины.
    func test_переведённоеИграетСистемныйПроигрыватель() async throws {
        for (name, seconds) in [("tone.wma", 1.0), ("tone.ra", 1.0), ("tone.dts", 0.4), ("tone.voc", 1.0)] {
            let playable = try await AudioTranscoder.transcode(URL(fileURLWithPath: fixtures + name))
            XCTAssertEqual(playable.pathExtension, "flac", name)
            let asset = AVURLAsset(url: playable)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, seconds, accuracy: 0.1, name)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1, name)
            let item = await AVPlayerItem(asset: asset)
            let player = await AVPlayer(playerItem: item)
            let ready = await waitUntilReady(item)
            XCTAssertTrue(ready, "\(name): проигрыватель готов играть")
            _ = player
        }
    }

    func test_второйРазБерётсяГотовое_изменённыйПереводитсяЗаново() async throws {
        let copy = cache.appendingPathComponent("копия.wma")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: fixtures + "tone.wma", toPath: copy.path)
        let first = try await AudioTranscoder.transcode(copy)

        AudioTranscoder.helperPath = { nil }        // без ffmpeg — значит, только из запаса
        let again = try await AudioTranscoder.transcode(copy)
        XCTAssertEqual(again, first)

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: copy.path)
        XCTAssertNotEqual(AudioTranscoder.cacheURL(for: copy), first, "файл изменился — перевод другой")
        do {
            _ = try await AudioTranscoder.transcode(copy)
            XCTFail("изменённый файл без ffmpeg перевести нельзя")
        } catch AudioTranscoder.Failure.noHelper {
        }
    }

    func test_битыйФайл_понятнаяОшибка_иНичегоНеОсталось() async throws {
        let broken = cache.appendingPathComponent("битый.wma")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("это не звук".utf8).write(to: broken)
        do {
            _ = try await AudioTranscoder.transcode(broken)
            XCTFail("битый файл не переводится")
        } catch let failure as AudioTranscoder.Failure {
            XCTAssertTrue(failure.errorDescription?.hasPrefix(String(format: L("viewer.audio.failed"), "")) ?? false,
                          failure.errorDescription ?? "")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".flac") }
        XCTAssertEqual(left, [], "недоделанный перевод убран")
    }

    func test_запасНеРастётСверхПредела_староеУходит() async throws {
        let old = try await AudioTranscoder.transcode(URL(fileURLWithPath: fixtures + "tone.wma"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: old.path)
        let size = try XCTUnwrap(try old.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        AudioTranscoder.cacheLimit = Int64(size) + 10
        let fresh = try await AudioTranscoder.transcode(URL(fileURLWithPath: fixtures + "tone.voc"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "новое осталось")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "старое ушло")
    }

    private func waitUntilReady(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<50 {
            let status = await item.status
            if status == .readyToPlay { return true }
            if status == .failed { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
