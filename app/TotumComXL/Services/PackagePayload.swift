import Compression
import Foundation

/// Пакет установки macOS (.pkg) — архив, в который можно войти.
///
/// Плоский пакет — это xar: оглавление Distribution, ресурсы установщика и вложенные пакеты
/// с Bom, PackageInfo, Payload и Scripts. Payload и Scripts — архивы cpio без расширения;
/// внутри них лежит то, что пакет установит, и сценарии установки. Старый пакет-«бандл» —
/// обычная папка, в него панель входит и так.
enum InstallerPackage {
    /// Плоский пакет: файл, не папка.
    static func isFlatPackage(_ item: FileItem) -> Bool {
        !item.isDirectory && isPackagePath(item.path)
    }

    static func isPackagePath(_ path: String) -> Bool {
        ["pkg", "mpkg", "xar"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Payload и Scripts внутри пакета — архивы, хоть и без расширения.
    static func isPackageArchiveEntry(name: String) -> Bool {
        name == "Payload" || name == "Scripts"
    }
}

/// Payload в упаковке pbzx — так его пишут Apple и многие установщики (Tailscale среди них).
///
/// libarchive pbzx не читает: это не архив, а нарезка. Подпись «pbzx», восемь байт флагов, и
/// дальше куски: восемь байт флагов, восемь байт длины и сам кусок — поток xz (или те же байты
/// без сжатия, когда сжатие не помогло). Бит 24 во флагах — «за этим куском есть ещё». Склеенные
/// развёрнутые куски — обычный cpio, а его libarchive читает.
enum PackagePayload {
    enum Failure: Error, LocalizedError {
        case notPBZX, truncated, corrupt

        var errorDescription: String? { L("archive.pkg.payloadBroken") }
    }

    private static let magic = Data("pbzx".utf8)
    private static let xzMagic = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
    private static let moreChunks: UInt64 = 1 << 24

    /// Начинается ли файл с подписи pbzx.
    static func isPBZX(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == magic
    }

    /// Развернуть pbzx в cpio по пути `output`.
    static func unpack(atPath path: String, to output: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        guard data.starts(with: magic) else { throw Failure.notPBZX }
        guard FileManager.default.createFile(atPath: output, contents: nil),
              let out = FileHandle(forWritingAtPath: output) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: output])
        }
        do {
            defer { try? out.close() }
            var offset = magic.count
            var flags = try bigEndian64(data, at: &offset)
            while flags & moreChunks != 0 {
                flags = try bigEndian64(data, at: &offset)
                let length = try bigEndian64(data, at: &offset)
                guard length <= UInt64(data.count - offset) else { throw Failure.truncated }
                let start = data.startIndex + offset
                let chunk = data[start ..< start + Int(length)]
                offset += Int(length)
                if chunk.starts(with: xzMagic) {
                    try decodeXZ(chunk, into: out)
                } else {
                    try out.write(contentsOf: chunk)
                }
            }
        } catch {
            try? FileManager.default.removeItem(atPath: output)
            throw error
        }
    }

    private static func bigEndian64(_ data: Data, at offset: inout Int) throws -> UInt64 {
        guard data.count - offset >= 8 else { throw Failure.truncated }
        var value: UInt64 = 0
        for byte in data[data.startIndex + offset ..< data.startIndex + offset + 8] {
            value = value << 8 | UInt64(byte)
        }
        offset += 8
        return value
    }

    /// Один поток xz — системным Compression (LZMA у него и есть xz).
    private static func decodeXZ(_ chunk: Data, into out: FileHandle) throws {
        let capacity = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
                == COMPRESSION_STATUS_OK else { throw Failure.corrupt }
        defer { compression_stream_destroy(stream) }

        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = source
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = capacity
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = capacity - stream.pointee.dst_size
                if produced > 0 {
                    try out.write(contentsOf: Data(bytesNoCopy: buffer, count: produced, deallocator: .none))
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // Ни байта ни внутрь, ни наружу — поток оборвался, дальше будет то же.
                    if produced == 0 && stream.pointee.src_size == 0 { throw Failure.truncated }
                case COMPRESSION_STATUS_END:
                    return
                default:
                    throw Failure.corrupt
                }
            }
        }
    }
}
