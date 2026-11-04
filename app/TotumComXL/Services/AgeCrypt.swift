import CryptoKit
import FCXLScrypt
import Foundation

/// The age file format, v1 (age-encryption.org/v1), password flavour — implemented here on
/// CryptoKit + our own scrypt, because the machine has neither `age` nor `gpg` to lean on.
/// Files written here open with the standard `age` tool and vice versa: scrypt recipient
/// stanza, ChaCha20-Poly1305-wrapped file key, HMAC-sealed header, 64 KiB STREAM chunks.
///
/// Only the passphrase recipient is spoken. A file locked to an X25519 key is honestly
/// refused as such, not mistaken for a wrong password.
enum AgeCrypt {

    static let fileExtension = "age"

    /// scrypt work factor for NEW files — 2^18, the same default the age CLI uses.
    static let defaultWorkFactor = 18
    /// Refuse to even try beyond this: 2^20 already means a gigabyte of scrypt arena, and a
    /// hostile header could name 2^60 to freeze the machine.
    private static let maxWorkFactor = 20

    private static let chunkSize = 64 * 1024
    private static let versionLine = "age-encryption.org/v1"

    enum AgeError: LocalizedError {
        case notAgeFile
        case keyLocked          // X25519 recipient — needs a key, not a password
        case wrongPassword
        case corrupted
        case tooExpensive
        case cancelled
        case internalFailure

        var errorDescription: String? {
            switch self {
            case .notAgeFile: return L("age.error.notAge")
            case .keyLocked: return L("age.error.keyLocked")
            case .wrongPassword: return L("age.error.wrongPassword")
            case .corrupted: return L("age.error.corrupted")
            case .tooExpensive: return L("age.error.tooExpensive")
            case .cancelled: return L("age.error.cancelled")
            case .internalFailure: return L("age.error.internal")
            }
        }
    }

    // MARK: - Encrypt

    static func encrypt(input: String, output: String, password: String,
                        workFactor: Int = defaultWorkFactor,
                        isCancelled: () -> Bool = { false },
                        progress: (Double) -> Void = { _ in }) throws {
        let fileKey = randomBytes(16)
        let salt = randomBytes(16)
        let wrapKey = try scrypt(password: password, salt: salt, workFactor: workFactor)
        let wrapped = try seal(fileKey, key: wrapKey, chunkNonce: Data(count: 12))

        var header = Data("\(versionLine)\n-> scrypt \(b64(salt)) \(workFactor)\n\(b64(wrapped))\n---".utf8)
        let mac = headerMAC(header: header, fileKey: fileKey)
        header.append(Data(" \(b64(mac))\n".utf8))

        let totalBytes = fileSize(input)

        guard let reader = FileHandle(forReadingAtPath: input) else { throw AgeError.internalFailure }
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: output, contents: nil)
        guard let writer = FileHandle(forWritingAtPath: output) else { throw AgeError.internalFailure }
        var finished = false
        defer {
            try? writer.close()
            // A cancelled or failed run must not leave a half-written .age behind.
            if !finished { try? FileManager.default.removeItem(atPath: output) }
        }

        try writer.write(contentsOf: header)
        let payloadNonce = randomBytes(16)
        try writer.write(contentsOf: payloadNonce)
        let payloadKey = hkdf(fileKey: fileKey, salt: payloadNonce, info: "payload")

        // One chunk of lookahead so the LAST chunk is known when it is sealed — its nonce
        // carries the final-chunk flag. An empty file is one empty final chunk.
        var counter: UInt64 = 0
        var done: UInt64 = 0
        var current = try reader.read(upToCount: chunkSize) ?? Data()
        while true {
            if isCancelled() { throw AgeError.cancelled }
            let next = try reader.read(upToCount: chunkSize) ?? Data()
            let isFinal = next.isEmpty
            let sealed = try seal(current, key: payloadKey,
                                  chunkNonce: chunkNonce(counter: counter, final: isFinal))
            try writer.write(contentsOf: sealed)
            done += UInt64(current.count)
            if totalBytes > 0 { progress(Double(done) / Double(totalBytes)) }
            if isFinal { break }
            current = next
            counter += 1
        }
        finished = true
    }

    // MARK: - Decrypt

    static func decrypt(input: String, output: String, password: String,
                        isCancelled: () -> Bool = { false },
                        progress: (Double) -> Void = { _ in }) throws {
        guard let reader = FileHandle(forReadingAtPath: input) else { throw AgeError.internalFailure }
        defer { try? reader.close() }

        // The header of a single-recipient file is a couple hundred bytes; 64 KiB of slack
        // costs nothing and covers any legal amount of stanza wrapping.
        let head = try reader.read(upToCount: 64 * 1024) ?? Data()
        let parsed = try parseHeader(head)
        let wrapKey = try scrypt(password: password, salt: parsed.salt,
                                 workFactor: parsed.workFactor)
        guard let fileKey = try? open(parsed.wrappedKey, key: wrapKey,
                                      chunkNonce: Data(count: 12)) else {
            throw AgeError.wrongPassword
        }
        // Password proven right — from here on any mismatch means a damaged or forged file.
        let macKey = hkdf(fileKey: fileKey, salt: Data(), info: "header")
        guard HMAC<SHA256>.isValidAuthenticationCode(
            parsed.mac, authenticating: parsed.macInput,
            using: SymmetricKey(data: macKey)) else {
            throw AgeError.corrupted
        }

        try reader.seek(toOffset: UInt64(parsed.payloadOffset))
        guard let payloadNonce = try reader.read(upToCount: 16), payloadNonce.count == 16 else {
            throw AgeError.corrupted
        }
        let payloadKey = hkdf(fileKey: fileKey, salt: payloadNonce, info: "payload")

        let totalBytes = fileSize(input)

        FileManager.default.createFile(atPath: output, contents: nil)
        guard let writer = FileHandle(forWritingAtPath: output) else { throw AgeError.internalFailure }
        var finished = false
        defer {
            try? writer.close()
            if !finished { try? FileManager.default.removeItem(atPath: output) }
        }

        let sealedChunk = chunkSize + 16
        var counter: UInt64 = 0
        var done: UInt64 = 0
        var current = try reader.read(upToCount: sealedChunk) ?? Data()
        guard !current.isEmpty else { throw AgeError.corrupted }  // not even an empty final chunk
        while true {
            if isCancelled() { throw AgeError.cancelled }
            guard current.count >= 16 else { throw AgeError.corrupted }
            let next = try reader.read(upToCount: sealedChunk) ?? Data()
            let isFinal = next.isEmpty
            guard let plain = try? open(current, key: payloadKey,
                                        chunkNonce: chunkNonce(counter: counter, final: isFinal))
            else { throw AgeError.corrupted }
            // A short non-final chunk, or a padding empty chunk after data, is forgery.
            if !isFinal && plain.count != chunkSize { throw AgeError.corrupted }
            if isFinal && plain.isEmpty && counter > 0 { throw AgeError.corrupted }
            try writer.write(contentsOf: plain)
            done += UInt64(current.count)
            if totalBytes > 0 { progress(Double(done) / Double(totalBytes)) }
            if isFinal { break }
            current = next
            counter += 1
        }
        finished = true
    }

    /// Is this an age file we can open with a password? Reads a few bytes, never derives keys.
    static func isAgeFile(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 32)) ?? Data()
        return head.starts(with: Data("\(versionLine)\n".utf8))
    }

    // MARK: - Header parsing

    private struct Header {
        let salt: Data
        let workFactor: Int
        let wrappedKey: Data
        let mac: Data
        let macInput: Data      // exact header bytes through "---", as found in the file
        let payloadOffset: Int  // where the 16-byte payload nonce begins
    }

    private static func parseHeader(_ head: Data) throws -> Header {
        // Line by line over the BYTES: the 64 KiB window holds the binary payload too, so
        // the buffer as a whole is not text — only the header lines before the MAC are.
        var lines: [String] = []
        var lineStarts: [Int] = []
        var cursor = head.startIndex
        while cursor < head.endIndex {
            lineStarts.append(cursor - head.startIndex)
            let newline = head[cursor...].firstIndex(of: 0x0A) ?? head.endIndex
            guard let line = String(data: head[cursor..<newline], encoding: .utf8) else {
                throw AgeError.notAgeFile
            }
            lines.append(line)
            if line.hasPrefix("--- ") { break }         // the MAC line ends the header
            guard newline < head.endIndex else { throw AgeError.corrupted }
            cursor = head.index(after: newline)
        }
        guard lines.first == versionLine else { throw AgeError.notAgeFile }

        var index = 1
        var salt: Data?
        var workFactor = 0
        var body = Data()
        while index < lines.count, lines[index].hasPrefix("-> ") {
            let args = lines[index].dropFirst(3).split(separator: " ")
            guard args.first == "scrypt" else { throw AgeError.keyLocked }
            guard salt == nil else { throw AgeError.corrupted }  // two scrypt stanzas is illegal
            guard args.count == 3,
                  let s = unb64(String(args[1])), s.count == 16,
                  let wf = Int(args[2]), wf > 0,
                  // A canonical integer only — "018" must not pass.
                  String(wf) == String(args[2]) else { throw AgeError.corrupted }
            guard wf <= maxWorkFactor else { throw AgeError.tooExpensive }
            salt = s
            workFactor = wf
            index += 1
            // Stanza body: base64 lines up to and including the first line shorter than 64.
            while index < lines.count {
                let line = lines[index]
                guard line.count <= 64, !line.hasPrefix("-> "), !line.hasPrefix("---"),
                      let piece = unb64(line) else { throw AgeError.corrupted }
                body.append(piece)
                index += 1
                if line.count < 64 { break }
            }
        }
        guard let salt, body.count == 32 else { throw AgeError.corrupted }
        guard index < lines.count, lines[index].hasPrefix("--- "),
              let mac = unb64(String(lines[index].dropFirst(4))), mac.count == 32
        else { throw AgeError.corrupted }

        let macEnd = lineStarts[index] + 3          // through the three dashes
        let payloadOffset = lineStarts[index] + lines[index].utf8.count + 1
        guard payloadOffset <= head.count else { throw AgeError.corrupted }
        return Header(salt: salt, workFactor: workFactor, wrappedKey: body, mac: mac,
                      macInput: head.prefix(macEnd), payloadOffset: payloadOffset)
    }

    // MARK: - Primitives

    private static func scrypt(password: String, salt: Data, workFactor: Int) throws -> Data {
        guard workFactor > 0, workFactor <= maxWorkFactor else { throw AgeError.tooExpensive }
        var out = Data(count: 32)
        let label = Data("age-encryption.org/v1/scrypt".utf8) + salt
        let pw = Data(password.utf8)
        let rc = out.withUnsafeMutableBytes { outPtr in
            pw.withUnsafeBytes { pwPtr in
                label.withUnsafeBytes { saltPtr in
                    fcxl_scrypt(pwPtr.bindMemory(to: UInt8.self).baseAddress, pw.count,
                                saltPtr.bindMemory(to: UInt8.self).baseAddress, label.count,
                                UInt64(1) << workFactor, 8, 1,
                                outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard rc == 0 else { throw AgeError.internalFailure }
        return out
    }

    private static func hkdf(fileKey: Data, salt: Data, info: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: fileKey),
                                         salt: salt, info: Data(info.utf8),
                                         outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func headerMAC(header: Data, fileKey: Data) -> Data {
        let key = hkdf(fileKey: fileKey, salt: Data(), info: "header")
        return Data(HMAC<SHA256>.authenticationCode(for: header, using: SymmetricKey(data: key)))
    }

    private static func seal(_ plain: Data, key: Data, chunkNonce: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key),
                                      nonce: ChaChaPoly.Nonce(data: chunkNonce))
        return box.ciphertext + box.tag
    }

    private static func open(_ sealed: Data, key: Data, chunkNonce: Data) throws -> Data {
        guard sealed.count >= 16 else { throw AgeError.corrupted }
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: chunkNonce),
                                           ciphertext: sealed.dropLast(16),
                                           tag: sealed.suffix(16))
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }

    /// STREAM chunk nonce: an 11-byte big-endian counter plus the final-chunk flag byte.
    private static func chunkNonce(counter: UInt64, final: Bool) -> Data {
        var nonce = Data(count: 12)
        var value = counter
        for i in stride(from: 10, through: 3, by: -1) {
            nonce[i] = UInt8(value & 0xFF)
            value >>= 8
        }
        nonce[11] = final ? 1 : 0
        return nonce
    }

    private static func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    /// Standard base64, no padding — the only alphabet the format speaks.
    private static func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private static func unb64(_ text: String) -> Data? {
        guard !text.contains("="), text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" })
        else { return nil }
        let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}
