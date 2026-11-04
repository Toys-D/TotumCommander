import AppKit
import ImageIO
import XCTest

@testable import TotumComXLApp

/// Telling a picture made by a neural network by what it says about itself — and taking that
/// out with the rest of its notes.
final class AIOriginTests: XCTestCase {

    private var folder: String!

    override func setUpWithError() throws {
        folder = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fcxl-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func path(_ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    private let parameters = """
        a red fox in the snow, MARKERPROMPT
        Negative prompt: blurry, MARKERNEGATIVE
        Steps: 20, Sampler: DPM++ 2M Karras, CFG scale: 7, Seed: 1234, Size: 512x768, Model hash: 6ce0161689, Model: sd_xl_base_1.0, Version: v1.7.0
        """

    // MARK: - What the programs write

    func testStableDiffusionParametersAreReadAsWritten() {
        let origin = AIOrigin.interpret(AIOrigin.Evidence(texts: ["parameters": parameters]))
        XCTAssertEqual(origin.verdict, .generated)
        XCTAssertEqual(origin.generator, "Stable Diffusion")
        XCTAssertEqual(origin.model, "sd_xl_base_1.0")
        XCTAssertEqual(origin.prompt, "a red fox in the snow, MARKERPROMPT")
        XCTAssertEqual(origin.negativePrompt, "blurry, MARKERNEGATIVE")
        XCTAssertTrue(origin.settings?.hasPrefix("Steps: 20, Sampler: DPM++ 2M Karras") == true)
    }

    /// The same line, put by the web UI into a JPEG's EXIF instead of a PNG chunk.
    func testStableDiffusionInAUserCommentIsReadToo() {
        let origin = AIOrigin.interpret(AIOrigin.Evidence(userComment: parameters))
        XCTAssertEqual(origin.prompt, "a red fox in the snow, MARKERPROMPT")
    }

    func testAnOrdinaryCommentIsNotAPrompt() {
        let origin = AIOrigin.interpret(AIOrigin.Evidence(
            programs: ["Adobe Photoshop 25.0"], description: "Закат над морем", userComment: "Steps away"))
        XCTAssertTrue(origin.isEmpty, "фото из Photoshop с подписью — не картинка нейросети")
    }

    func testComfyUIsGraphGivesUpItsPrompt() {
        let graph = """
            {"3": {"class_type": "KSampler", "inputs": {"seed": 42, "steps": 25, "cfg": 7.5,
                   "sampler_name": "euler", "scheduler": "normal", "positive": ["6", 0],
                   "negative": ["7", 0], "model": ["4", 0], "latent_image": ["5", 0]}},
             "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "flux1-dev.safetensors"}},
             "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a lighthouse at dawn", "clip": ["4", 1]}},
             "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "text, watermark", "clip": ["4", 1]}}}
            """
        let origin = AIOrigin.interpret(AIOrigin.Evidence(texts: ["prompt": graph, "workflow": "{}"]))
        XCTAssertEqual(origin.generator, "ComfyUI")
        XCTAssertEqual(origin.prompt, "a lighthouse at dawn")
        XCTAssertEqual(origin.negativePrompt, "text, watermark")
        XCTAssertEqual(origin.model, "flux1-dev.safetensors")
        XCTAssertEqual(origin.settings, "seed: 42, steps: 25, cfg: 7.5, sampler_name: euler, scheduler: normal")
    }

    func testNovelAIsNotes() {
        let origin = AIOrigin.interpret(AIOrigin.Evidence(texts: [
            "Software": "NovelAI", "Source": "NovelAI Diffusion V4",
            "Description": "1girl, cherry blossoms",
            "Comment": #"{"prompt": "1girl, cherry blossoms", "uc": "lowres", "seed": 7, "steps": 28, "sampler": "k_euler_ancestral", "scale": 5}"#,
        ]))
        XCTAssertEqual(origin.generator, "NovelAI")
        XCTAssertEqual(origin.model, "NovelAI Diffusion V4")
        XCTAssertEqual(origin.prompt, "1girl, cherry blossoms")
        XCTAssertEqual(origin.negativePrompt, "lowres")
        XCTAssertEqual(origin.settings, "seed: 7, steps: 28, sampler: k_euler_ancestral, scale: 5")
    }

    func testInvokeAIsNotes() {
        let origin = AIOrigin.interpret(AIOrigin.Evidence(texts: [
            "invokeai_metadata": #"{"positive_prompt": "a quiet library", "negative_prompt": "people", "model": {"name": "juggernautXL"}, "seed": 9, "steps": 30}"#,
        ]))
        XCTAssertEqual(origin.generator, "InvokeAI")
        XCTAssertEqual(origin.prompt, "a quiet library")
        XCTAssertEqual(origin.model, "juggernautXL")
    }

    func testMidjourneysDescription() {
        let origin = AIOrigin.interpret(AIOrigin.Evidence(
            description: "a paper boat on a puddle --ar 3:2 --v 6.1 Job ID: 1b2c3d4e-0000-4000-8000-123456789abc"))
        XCTAssertEqual(origin.generator, "Midjourney")
        XCTAssertEqual(origin.prompt, "a paper boat on a puddle --ar 3:2 --v 6.1")
        XCTAssertEqual(origin.verdict, .generated)
    }

    func testTheDigitalSourceTypeSaysHowItWasMade() {
        let base = "http://cv.iptc.org/newscodes/digitalsourcetype/"
        XCTAssertEqual(AIOrigin.verdict(base + "trainedAlgorithmicMedia"), .generated)
        XCTAssertEqual(AIOrigin.verdict(base + "compositeWithTrainedAlgorithmicMedia"), .composite)
        XCTAssertEqual(AIOrigin.verdict(base + "algorithmicMedia"), .algorithmic)
        XCTAssertNil(AIOrigin.verdict(base + "digitalCapture"), "снимок с камеры")
        let google = AIOrigin.interpret(AIOrigin.Evidence(
            digitalSourceType: base + "trainedAlgorithmicMedia", programs: ["Made with Google AI"]))
        XCTAssertEqual(google.generator, "Google AI")
    }

    // MARK: - C2PA

    /// The manifest store, as far as reading it goes: the JUMBF box labelled "c2pa", a claim in
    /// CBOR naming its program, and an action saying the picture was made by a model.
    private func credentials(generator: String, info: Bool = false, madeByModel: Bool = true) -> [UInt8] {
        func text(_ s: String) -> [UInt8] {
            let b = Array(s.utf8)
            return (b.count < 24 ? [0x60 | UInt8(b.count)] : [0x78, UInt8(b.count)]) + b
        }
        let claim: [UInt8] = info
            ? [0xA1] + text("claim_generator_info") + [0x81, 0xA2] + text("name") + text(generator)
                + text("version") + text("1.0")
            : [0xA1] + text("claim_generator") + text(generator)
        let action: [UInt8] = !madeByModel ? [] : [0xA1] + text("digitalSourceType")
            + text("http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")
        let label = Array("jumd".utf8) + Array("c2pa".utf8) + [0x00, 0x11, 0x00, 0x10] + [UInt8](repeating: 0, count: 8)
            + [0x03] + Array("c2pa\u{0}".utf8)
        let body = label + claim + action
        return Binary.be32(body.count + 8) + Array("jumb".utf8) + body
    }

    func testC2PANamesTheProgram() {
        XCTAssertEqual(AIOrigin.c2paGenerator(credentials(generator: "ChatGPT c2pa-rs/0.31.3")), "ChatGPT")
        XCTAssertEqual(AIOrigin.c2paGenerator(credentials(generator: "Adobe_Firefly adobe_c2pa/0.7.6")),
                       "Adobe Firefly")
        XCTAssertEqual(AIOrigin.c2paGenerator(credentials(generator: "Microsoft Designer", info: true)),
                       "Microsoft Designer")
        let origin = AIOrigin.interpret(AIOrigin.Evidence(credentials: credentials(generator: "ChatGPT")))
        XCTAssertEqual(origin.credentials, "ChatGPT")
        XCTAssertEqual(origin.generator, "ChatGPT")
        XCTAssertEqual(origin.verdict, .generated)
    }

    /// A camera that signs its photographs is not a neural network: the credentials are shown,
    /// nothing more is concluded.
    func testACameraSignatureIsNotAVerdict() {
        let bytes = credentials(generator: "Leica M11-P", madeByModel: false)
        let origin = AIOrigin.interpret(AIOrigin.Evidence(credentials: bytes))
        XCTAssertEqual(origin.credentials, "Leica M11-P")
        XCTAssertNil(origin.generator)
        XCTAssertNil(origin.verdict)
    }

    // MARK: - Files

    private func plainPNG(_ name: String) throws -> String {
        let target = path(name)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("холст не создался") }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: target) as CFURL, "public.png" as CFString, 1, nil)
        else { throw XCTSkip("PNG не пишется") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("PNG не записался") }
        return target
    }

    /// Chunks put in right after the header, where the web UIs and C2PA put theirs.
    private func insert(_ chunks: [[UInt8]], into png: String) throws {
        var b = [UInt8](try Data(contentsOf: URL(fileURLWithPath: png)))
        let afterHeader = 8 + 12 + (Binary.u32(b, 8) ?? 13)
        b.insert(contentsOf: chunks.flatMap { $0 }, at: afterHeader)
        try Data(b).write(to: URL(fileURLWithPath: png))
    }

    func testAStableDiffusionPictureIsSeenOnThePanelAndCleaned() async throws {
        let png = try plainPNG("лиса.png")
        XCTAssertFalse(MetadataScrubber.canClean(path: png), "чистая картинка — предлагать нечего")
        try insert([
            PNGChunks.chunk("tEXt", Array("parameters\u{0}".utf8) + Array(parameters.utf8)),
            PNGChunks.chunk("caBX", credentials(generator: "ChatGPT")),
        ], into: png)

        let panel = PhotoMetadataService.read(path: png).entries(in: .origin)
        func value(_ key: String) -> String? { panel.first { $0.label == L(key) }?.value }
        XCTAssertEqual(value("exif.ai.made"), L("exif.ai.made.generated"))
        XCTAssertEqual(value("exif.ai.generator"), "Stable Diffusion")
        XCTAssertEqual(value("exif.ai.prompt"), "a red fox in the snow, MARKERPROMPT")
        XCTAssertEqual(value("exif.ai.credentials"), String(format: L("exif.ai.credentials.by"), "ChatGPT"))
        XCTAssertTrue(MetadataScrubber.canClean(path: png), "у ImageIO этих записей нет, а пункт есть")

        try await MetadataScrubber.clean(path: png)

        let data = try Data(contentsOf: URL(fileURLWithPath: png))
        for word in ["MARKERPROMPT", "parameters", "caBX", "c2pa", "ChatGPT"] {
            XCTAssertNil(data.range(of: Data(word.utf8)), word)
        }
        XCTAssertTrue(AIOrigin.read(path: png).isEmpty)
        XCTAssertTrue(PhotoMetadataService.read(path: png).entries(in: .origin).isEmpty)
    }

    /// A JPEG the way the big services make one: the IPTC source type in the XMP, the C2PA
    /// credentials in APP11 segments.
    func testAMarkedJPEGIsSeenAndCleaned() async throws {
        let jpeg = path("открытка.jpg")
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: jpeg) as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw XCTSkip("JPEG не пишется") }
        let metadata = CGImageMetadataCreateMutable()
        let iptc = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, iptc as CFString,
                                                                "Iptc4xmpExt" as CFString, nil))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            metadata, nil, "Iptc4xmpExt:DigitalSourceType" as CFString,
            "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia" as CFString))
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var b = [UInt8](try Data(contentsOf: URL(fileURLWithPath: jpeg)))
        let box = Array("JP".utf8) + [0, 1, 0, 0, 0, 1] + credentials(generator: "Adobe_Firefly adobe_c2pa/0.7.6")
        b.insert(contentsOf: [0xFF, 0xEB] + [UInt8((box.count + 2) >> 8), UInt8((box.count + 2) & 0xFF)] + box, at: 2)
        try Data(b).write(to: URL(fileURLWithPath: jpeg))

        let origin = AIOrigin.read(path: jpeg)
        XCTAssertEqual(origin.verdict, .generated)
        XCTAssertEqual(origin.credentials, "Adobe Firefly")
        XCTAssertEqual(origin.generator, "Adobe Firefly")

        try await MetadataScrubber.clean(path: jpeg)

        XCTAssertTrue(AIOrigin.read(path: jpeg).isEmpty)
        XCTAssertNil(try Data(contentsOf: URL(fileURLWithPath: jpeg)).range(of: Data("c2pa".utf8)))
    }

    func testAWebPLosesItsCredentials() throws {
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            Array(type.utf8) + Binary.le32(data.count) + data + (data.count % 2 == 1 ? [0] : [])
        }
        let picture = [UInt8](repeating: 0x2F, count: 12)
        let body = Array("WEBP".utf8) + chunk("VP8L", picture) + chunk("C2PA", credentials(generator: "ChatGPT"))
        let clean = try XCTUnwrap(WebPChunks.clean(Array("RIFF".utf8) + Binary.le32(body.count) + body,
                                                   scope: .everything))
        let expected = Array("WEBP".utf8) + chunk("VP8L", picture)
        XCTAssertEqual(clean, Array("RIFF".utf8) + Binary.le32(expected.count) + expected)
    }

    /// HEIF keeps C2PA in a box of its own at the top level: cleaned in place, renamed to
    /// "free", emptied — and the picture still opens, the file the same length.
    func testAHEICsCredentialsBecomePadding() async throws {
        let heic = path("пейзаж.heic")
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: heic) as CFURL, "public.heic" as CFString, 1, nil)
        else { throw XCTSkip("HEIC не пишется") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("HEIC не записался") }
        let payload = PictureNoteScan.c2paUUID + Array("manifest\u{0}".utf8) + [UInt8](repeating: 0, count: 8)
            + credentials(generator: "ChatGPT")
        let box = Binary.be32(payload.count + 8) + Array("uuid".utf8) + payload
        try (try Data(contentsOf: URL(fileURLWithPath: heic)) + Data(box)).write(to: URL(fileURLWithPath: heic))
        let size = try Data(contentsOf: URL(fileURLWithPath: heic)).count
        XCTAssertEqual(AIOrigin.read(path: heic).credentials, "ChatGPT")

        try await MetadataScrubber.clean(path: heic)

        let data = try Data(contentsOf: URL(fileURLWithPath: heic))
        XCTAssertEqual(data.count, size)
        XCTAssertNil(data.range(of: Data("c2pa".utf8)))
        XCTAssertNil(AIOrigin.read(path: heic).credentials)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: heic) as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "картинка открывается")
    }
}
