import AVFoundation
import Foundation

/// Film and sound AVFoundation can write back: the file is put together anew from its own
/// tracks, sample for sample, nothing re-encoded.
///
/// Anew, and not just exported: an export of the file itself carries every note across even
/// when told to carry none. A composition holds only what was put in it — the picture, the
/// sound, the subtitles — so the notes stay behind, and so do the tracks of timed notes beside
/// them (a camera's GPS track among them).
enum MediaScrubber {

    static func remux(from path: String, to target: String,
                      scope: MetadataScrubber.Scope) async throws {
        let name = MetadataScrubber.fileName(path)
        guard let type = fileType(forExtension: (path as NSString).pathExtension) else {
            throw MetadataScrubber.Failure.unreadable(name)
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let composition = AVMutableComposition()
        let wanted: [AVMediaType] = scope == .everything
            ? [.video, .audio, .subtitle, .closedCaption]
            : [.video, .audio, .subtitle, .closedCaption, .timecode, .text]
        var essential = 0
        do {
            for track in try await asset.load(.tracks) where wanted.contains(track.mediaType) {
                let range = try await track.load(.timeRange)
                guard let copy = composition.addMutableTrack(
                    withMediaType: track.mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                do {
                    try copy.insertTimeRange(range, of: track, at: range.start)
                } catch {
                    composition.removeTrack(copy)
                    // The picture and the sound are the film; a subtitle that will not come
                    // along is not worth failing over.
                    if track.mediaType == .video || track.mediaType == .audio { throw error }
                    continue
                }
                // Which way is up, which language — the track's own, not notes about anyone.
                copy.preferredTransform = try await track.load(.preferredTransform)
                copy.languageCode = try await track.load(.languageCode)
                copy.extendedLanguageTag = try await track.load(.extendedLanguageTag)
                copy.isEnabled = try await track.load(.isEnabled)
                if track.mediaType == .video || track.mediaType == .audio { essential += 1 }
            }
        } catch {
            throw MetadataScrubber.Failure.unreadable(name)
        }
        guard essential > 0 else { throw MetadataScrubber.Failure.unreadable(name) }

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetPassthrough),
              await session.compatibleFileTypes.contains(type) else {
            throw MetadataScrubber.Failure.unwritable(name)
        }
        switch scope {
        case .everything:
            session.metadata = []
        case .place:
            let notes = (try? await asset.load(.metadata)) ?? []
            session.metadata = notes.filter { !isPlace($0) }
        }
        do {
            try await session.export(to: URL(fileURLWithPath: target), as: type)
        } catch {
            throw MetadataScrubber.Failure.unwritable(name)
        }
    }

    /// The container to write, by the name the file already has.
    static func fileType(forExtension ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mov", "qt": return .mov
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "3gp": return .mobile3GPP
        case "3g2": return .mobile3GPP2
        case "m4a", "m4r": return .m4a
        case "wav", "wave": return .wav
        case "aif", "aiff": return .aiff
        case "aifc": return .aifc
        case "caf": return .caf
        default: return nil
        }
    }

    /// Where it was filmed — in any of the ways QuickTime, iTunes and 3GPP write it down.
    static func isPlace(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        let id = (item.identifier?.rawValue ?? "").lowercased()
        return id.contains("location") || id.hasSuffix("/%a9xyz") || id.hasSuffix("/loci")
    }
}

/// Sound whose tags are glued on, not woven in: ID3 and its kin at the ends of an MP3 or a raw
/// AAC stream, the metadata blocks at the head of a FLAC. Cutting them off leaves the sound
/// itself exactly as it was.
enum TagScrubber {

    static func writeWithoutID3(from path: String, to target: String) throws {
        let name = MetadataScrubber.fileName(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        else { throw MetadataScrubber.Failure.unreadable(name) }
        let bytes = [UInt8](data)
        guard let sound = soundRange(bytes) else { throw MetadataScrubber.Failure.unreadable(name) }
        do {
            try Data(bytes[sound]).write(to: URL(fileURLWithPath: target), options: .withoutOverwriting)
        } catch {
            throw MetadataScrubber.Failure.unwritable(name)
        }
    }

    static func writeWithoutFLACTags(from path: String, to target: String) throws {
        let name = MetadataScrubber.fileName(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
              let clean = flacWithoutTags([UInt8](data)) else {
            throw MetadataScrubber.Failure.unreadable(name)
        }
        do {
            try Data(clean).write(to: URL(fileURLWithPath: target), options: .withoutOverwriting)
        } catch {
            throw MetadataScrubber.Failure.unwritable(name)
        }
    }

    /// Where the sound is, once every tag at either end is cut off: ID3v2 at the head (more
    /// than one, sometimes), and at the tail ID3v1 with its extended block, an appended ID3v2,
    /// APE and Lyrics3. Nil when nothing would be left.
    static func soundRange(_ b: [UInt8]) -> Range<Int>? {
        var start = 0
        while let size = id3v2Size(b, at: start), start + size <= b.count { start += size }

        var end = b.count
        var cut = true
        while cut {
            cut = false
            if end - start >= 128, Binary.matches(b, end - 128, "TAG") {
                end -= 128
                if end - start >= 227, Binary.matches(b, end - 227, "TAG+") { end -= 227 }
                cut = true
            }
            if end - start >= 10, Binary.matches(b, end - 10, "3DI"),
               let size = syncsafe(b, end - 4), end - start >= size + 20 {
                end -= size + 20
                cut = true
            }
            if end - start >= 32, Binary.matches(b, end - 32, "APETAGEX"),
               let size = Binary.u32(b, end - 20, bigEndian: false),
               let flags = Binary.u32(b, end - 12, bigEndian: false) {
                let whole = size + (flags & 0x8000_0000 != 0 ? 32 : 0)
                if end - start >= whole { end -= whole; cut = true }
            }
            if end - start >= 15, Binary.matches(b, end - 9, "LYRICS200"),
               let digits = Binary.ascii(b, end - 15, 6), let size = Int(digits),
               end - start >= size + 15 {
                end -= size + 15
                cut = true
            }
        }
        return start < end ? start..<end : nil
    }

    /// The length of the ID3v2 tag at `i`, footer included; nil when none starts there.
    private static func id3v2Size(_ b: [UInt8], at i: Int) -> Int? {
        guard Binary.matches(b, i, "ID3"), i + 10 <= b.count, b[i + 3] < 0xFF, b[i + 4] < 0xFF,
              let size = syncsafe(b, i + 6) else { return nil }
        return 10 + size + (b[i + 5] & 0x10 != 0 ? 10 : 0)
    }

    /// ID3's 28-bit number written seven bits to a byte.
    private static func syncsafe(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= b.count, b[i..<(i + 4)].allSatisfy({ $0 < 0x80 }) else { return nil }
        return b[i..<(i + 4)].reduce(0) { $0 << 7 | Int($1) }
    }

    /// FLAC: "fLaC", metadata blocks, then the frames. The stream's own description stays —
    /// STREAMINFO, the seek table, the CD's cue sheet; the tags, the cover pictures, the
    /// programs' private blocks and the padding go.
    static func flacWithoutTags(_ b: [UInt8]) -> [UInt8]? {
        let head = soundRange(b)?.lowerBound ?? 0   // an ID3 some programs put in front
        guard Binary.matches(b, head, "fLaC") else { return nil }
        var kept: [[UInt8]] = []
        var i = head + 4
        var last = false
        while !last {
            guard i + 4 <= b.count, let length = Binary.u24(b, i + 1), i + 4 + length <= b.count
            else { return nil }
            last = b[i] & 0x80 != 0
            let type = b[i] & 0x7F
            if [0, 3, 5].contains(type) { kept.append(Array(b[i..<(i + 4 + length)])) }
            i += 4 + length
        }
        guard !kept.isEmpty, kept[0][0] & 0x7F == 0 else { return nil }   // STREAMINFO first
        for k in kept.indices { kept[k][0] &= 0x7F }
        kept[kept.count - 1][0] |= 0x80
        // An ID3v1 some taggers glue to the end of a FLAC as well.
        let frames = Array(b[i...])
        let sound = soundRange(frames).map { Array(frames[$0]) } ?? frames
        return Array("fLaC".utf8) + kept.flatMap { $0 } + sound
    }
}
