import Foundation
import ImageIO

/// What a picture says about having been made by a neural network.
///
/// Two kinds of trace. The big services mark their pictures openly: IPTC's "digital source
/// type" in the XMP ("trained algorithmic media" — made by a model) and C2PA content credentials,
/// a signed record of the program that made the picture (ChatGPT, Firefly and Bing write those).
/// The programs people run themselves leave their working notes instead — Stable Diffusion's
/// parameters line, ComfyUI's whole node graph, NovelAI's JSON — with the prompt in plain text.
///
/// Only what the file SAYS is read. An invisible watermark woven into the pixels (Google's
/// SynthID) is not a note and is not seen here; a C2PA signature is shown, not verified.
struct AIOrigin: Equatable {

    enum Verdict: String, Equatable {
        /// Made by a model trained on pictures.
        case generated
        /// A picture with parts made by such a model — generative fill.
        case composite
        /// Made by an algorithm that was not trained on pictures.
        case algorithmic
    }

    var verdict: Verdict?
    var generator: String?
    var model: String?
    var prompt: String?
    var negativePrompt: String?
    var settings: String?
    /// C2PA content credentials: nil when there are none, the program they name when they name
    /// one, "" when they do not.
    var credentials: String?

    var isEmpty: Bool {
        verdict == nil && generator == nil && prompt == nil && credentials == nil
    }

    /// Made by a neural network by the file's own say-so — not merely signed, the way a camera
    /// signs its photographs.
    var isAIMade: Bool { verdict != nil || generator != nil }

    /// One line for a badge or a menu: "Создано нейросетью" — without the program's name.
    /// What a file names is often not a neural network a person would recognise ("OpenAI Media
    /// Service API"), and the point here is that ONE made it; which one the info panel says.
    var headline: String {
        L(verdict == .composite ? "ai.headline.composite" : "ai.headline")
    }

    /// The picture at `path`, when it is a picture and was made by a neural network — what a
    /// menu or the viewer asks before saying so.
    static func ofPicture(atPath path: String) -> AIOrigin? {
        guard MetadataScrubber.Kind(pathExtension: (path as NSString).pathExtension).isPicture
        else { return nil }
        let origin = read(path: path)
        return origin.isAIMade ? origin : nil
    }

    /// Everything read, before deciding what it means — kept apart so the deciding is testable
    /// without a file.
    struct Evidence {
        /// PNG text chunks by keyword; a JPEG comment as "comment".
        var texts: [String: String] = [:]
        var digitalSourceType: String?
        /// Software, CreatorTool, Credit — whatever names the program.
        var programs: [String] = []
        var description: String?
        var userComment: String?
        var credentials: [UInt8]?
    }

    // MARK: - Reading

    static func read(path: String) -> AIOrigin {
        let scan = PictureNoteScan.scan(path: path)
        var evidence = Evidence(texts: scan.texts, credentials: scan.credentials)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        else { return interpret(evidence) }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        evidence.programs += [tiff[kCGImagePropertyTIFFSoftware], png[kCGImagePropertyPNGSoftware]]
            .compactMap { $0 as? String }
        evidence.userComment = exif[kCGImagePropertyExifUserComment] as? String
        evidence.description = tiff[kCGImagePropertyTIFFImageDescription] as? String
            ?? png[kCGImagePropertyPNGDescription] as? String

        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            for tag in tags {
                let space = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
                let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                let value = Self.string(CGImageMetadataTagCopyValue(tag))
                switch (space, name) {
                case (_, "DigitalSourceType") where space.hasPrefix("http://iptc.org/std/Iptc4xmpExt"):
                    evidence.digitalSourceType = value
                case ("http://ns.adobe.com/xap/1.0/", "CreatorTool"),
                     ("http://ns.adobe.com/photoshop/1.0/", "Credit"):
                    if let value { evidence.programs.append(value) }
                case ("http://purl.org/dc/elements/1.1/", "description"):
                    evidence.description = value ?? evidence.description
                default:
                    break
                }
            }
        }
        return interpret(evidence)
    }

    /// A tag's value as text: a plain string, or the first entry of a language list or array —
    /// whose entries are tags in their turn.
    private static func string(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if CFGetTypeID(value) == CGImageMetadataTagGetTypeID() {
            return string(CGImageMetadataTagCopyValue(unsafeBitCast(value, to: CGImageMetadataTag.self)))
        }
        if let list = value as? [AnyObject] { return list.lazy.compactMap { string($0) }.first }
        if let map = value as? [String: AnyObject] { return map.values.lazy.compactMap { string($0) }.first }
        return nil
    }

    // MARK: - Deciding

    static func interpret(_ evidence: Evidence) -> AIOrigin {
        var origin = AIOrigin()
        origin.verdict = verdict(evidence.digitalSourceType)
        let texts = evidence.texts

        if let parameters = texts["parameters"] {
            origin.merge(fooocus(parameters) ?? stableDiffusion(parameters))
        } else if let comment = evidence.userComment, let found = stableDiffusion(comment) {
            origin.merge(found)
        }
        if let graph = texts["prompt"], let found = comfyUI(graph) {
            origin.merge(found)
        } else if texts["workflow"] != nil, origin.generator == nil {
            origin.generator = "ComfyUI"
        }
        if let invoke = texts["invokeai_metadata"].flatMap(invokeAI) { origin.merge(invoke) }
        if texts["Software"] == "NovelAI" || evidence.programs.contains("NovelAI") {
            origin.merge(novelAI(texts))
        }
        if evidence.programs.contains(where: { $0.localizedCaseInsensitiveContains("Draw Things") }) {
            origin.merge(drawThings(comment: evidence.userComment, description: evidence.description))
        }
        let description = evidence.description ?? texts["Description"]
        if origin.prompt == nil, let description, let jobID = description.range(of: "Job ID:") {
            origin.generator = origin.generator ?? "Midjourney"
            origin.prompt = String(description[..<jobID.lowerBound]).trimmed
        }
        if origin.generator == nil {
            origin.generator = evidence.programs.lazy.compactMap(aiProgram).first
        }

        if let credentials = evidence.credentials {
            let named = c2paGenerator(credentials)
            origin.credentials = named ?? ""
            if origin.verdict == nil { origin.verdict = c2paVerdict(credentials) }
            if origin.generator == nil, let named, aiProgram(named) != nil { origin.generator = named }
        }
        // A program that only makes pictures with a model has said enough.
        if origin.verdict == nil, origin.generator != nil || origin.prompt != nil {
            origin.verdict = .generated
        }
        return origin
    }

    private mutating func merge(_ other: AIOrigin?) {
        guard let other else { return }
        generator = generator ?? other.generator
        model = model ?? other.model
        prompt = prompt ?? other.prompt
        negativePrompt = negativePrompt ?? other.negativePrompt
        settings = settings ?? other.settings
    }

    /// IPTC's digital source type, as a URL or as the bare code.
    static func verdict(_ sourceType: String?) -> Verdict? {
        guard let code = sourceType?.split(separator: "/").last?.lowercased() else { return nil }
        switch code {
        case "trainedalgorithmicmedia": return .generated
        case "compositewithtrainedalgorithmicmedia", "compositesynthetic": return .composite
        case "algorithmicmedia": return .algorithmic
        default: return nil
        }
    }

    /// The names a program that makes pictures with a model goes by — in Software, CreatorTool,
    /// Credit ("Made with Google AI") or a C2PA claim. A camera or Photoshop is not one of them.
    static func aiProgram(_ text: String) -> String? {
        let known = ["Midjourney", "DALL·E", "DALL-E", "ChatGPT", "OpenAI", "Firefly",
                     "Stable Diffusion", "ComfyUI", "NovelAI", "InvokeAI", "Fooocus", "Draw Things",
                     "DiffusionBee", "Mochi Diffusion", "Image Playground", "Gemini",
                     "Google AI", "Leonardo", "Ideogram", "FLUX", "Bing Image", "Image Creator",
                     "Microsoft Designer", "Responsible AI", "Copilot", "Meta AI", "Grok", "Sora",
                     "Runway", "Kling"]
        guard known.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { return nil }
        if let made = text.range(of: "Made with ", options: .caseInsensitive) {
            return String(text[made.upperBound...]).trimmed
        }
        return text.trimmed
    }

    // MARK: - The programs' own notes

    /// Stable Diffusion web UIs (Automatic1111, Forge, SD.Next) and every tool that copies them:
    ///
    ///     a cat in a hat
    ///     Negative prompt: blurry
    ///     Steps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Size: 512x512, Model: sd_xl_base
    static func stableDiffusion(_ text: String) -> AIOrigin? {
        let lines = text.components(separatedBy: "\n")
        guard let last = lines.lastIndex(where: { $0.hasPrefix("Steps: ") }),
              lines[last].contains("Sampler: ") || lines[last].contains("Seed: ") else { return nil }
        var origin = AIOrigin(generator: "Stable Diffusion")
        let settings = lines[last...].joined(separator: "\n").trimmed
        origin.settings = settings
        origin.model = field("Model", in: settings)
        let body = lines[..<last].joined(separator: "\n")
        if let negative = body.range(of: "Negative prompt: ") {
            origin.prompt = String(body[..<negative.lowerBound]).trimmed.nilIfEmpty
            origin.negativePrompt = String(body[negative.upperBound...]).trimmed.nilIfEmpty
        } else {
            origin.prompt = body.trimmed.nilIfEmpty
        }
        return origin
    }

    /// "Key: value" out of a "Steps: 20, Sampler: Euler a, Model: name" line.
    private static func field(_ key: String, in line: String) -> String? {
        for part in line.components(separatedBy: ", ") where part.hasPrefix(key + ": ") {
            return String(part.dropFirst(key.count + 2)).trimmed.nilIfEmpty
        }
        return nil
    }

    /// Fooocus writes its parameters as JSON under the same keyword.
    static func fooocus(_ text: String) -> AIOrigin? {
        guard let json = object(text), json["Prompt"] != nil || json["prompt"] != nil else { return nil }
        var origin = AIOrigin(generator: "Fooocus")
        origin.prompt = (json["Prompt"] ?? json["prompt"]) as? String
        origin.negativePrompt = (json["Negative Prompt"] ?? json["negative_prompt"]) as? String
        origin.model = (json["Base Model"] ?? json["base_model"]) as? String
        origin.settings = summary(json, ["Seed", "seed", "Steps", "steps", "Sampler", "sampler"])
        return origin
    }

    /// ComfyUI keeps the graph it ran: nodes by id, each with its class and inputs. The prompt
    /// is the text of the node the sampler's "positive" input points at.
    static func comfyUI(_ text: String) -> AIOrigin? {
        guard let graph = object(text) as? [String: [String: Any]],
              graph.values.contains(where: { $0["class_type"] != nil }) else { return nil }
        var origin = AIOrigin(generator: "ComfyUI")
        func inputs(_ id: String?) -> [String: Any] { id.flatMap { graph[$0]?["inputs"] as? [String: Any] } ?? [:] }
        func words(_ id: String?) -> String? {
            let found = inputs(id)
            return (found["text"] ?? found["text_g"] ?? found["prompt"]) as? String
        }
        func link(_ value: Any?) -> String? {
            guard let pair = value as? [Any], let first = pair.first else { return nil }
            return (first as? String) ?? (first as? Int).map(String.init)
        }
        let sampler = graph.first { ($0.value["class_type"] as? String)?.contains("Sampler") == true }
        if let sampler {
            let found = inputs(sampler.key)
            origin.prompt = words(link(found["positive"]))
            origin.negativePrompt = words(link(found["negative"]))
            origin.settings = summary(found, ["seed", "noise_seed", "steps", "cfg", "sampler_name", "scheduler"])
        }
        if origin.prompt == nil {
            let texts = graph.values
                .filter { ($0["class_type"] as? String)?.contains("TextEncode") == true }
                .compactMap { ($0["inputs"] as? [String: Any])?["text"] as? String }
            origin.prompt = texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        origin.model = graph.values.lazy.compactMap { node -> String? in
            let found = node["inputs"] as? [String: Any] ?? [:]
            return (found["ckpt_name"] ?? found["unet_name"]) as? String
        }.first
        return origin
    }

    /// InvokeAI: one JSON object with everything named plainly.
    static func invokeAI(_ text: String) -> AIOrigin? {
        guard let json = object(text) else { return nil }
        var origin = AIOrigin(generator: "InvokeAI")
        origin.prompt = json["positive_prompt"] as? String
        origin.negativePrompt = json["negative_prompt"] as? String
        let model = json["model"] as? [String: Any]
        origin.model = (model?["name"] ?? model?["model_name"]) as? String
        origin.settings = summary(json, ["seed", "steps", "cfg_scale", "scheduler"])
        return origin
    }

    /// NovelAI: the prompt in Description, the model in Source, the rest as JSON in Comment.
    static func novelAI(_ texts: [String: String]) -> AIOrigin {
        var origin = AIOrigin(generator: "NovelAI")
        let comment = texts["Comment"].flatMap(object) ?? [:]
        origin.prompt = texts["Description"] ?? comment["prompt"] as? String
        origin.negativePrompt = comment["uc"] as? String
        origin.model = texts["Source"]
        origin.settings = summary(comment, ["seed", "steps", "sampler", "scale"])
        return origin
    }

    /// Draw Things: the prompt in the description, the rest as JSON in the EXIF user comment.
    static func drawThings(comment: String?, description: String?) -> AIOrigin {
        var origin = AIOrigin(generator: "Draw Things")
        let json = comment.flatMap(object) ?? [:]
        origin.prompt = json["c"] as? String ?? description
        origin.negativePrompt = json["uc"] as? String
        origin.model = json["model"] as? String
        origin.settings = summary(json, ["seed", "steps", "sampler", "scale"])
        return origin
    }

    private static func object(_ text: String) -> [String: Any]? {
        guard text.trimmed.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "seed: 1, steps: 20" — the keys that are there, in the order asked.
    private static func summary(_ json: [String: Any], _ keys: [String]) -> String? {
        let parts = keys.compactMap { key -> String? in
            guard let value = json[key], !(value is NSNull), !(value is [Any]), !(value is [String: Any])
            else { return nil }
            return "\(key): \(value)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - C2PA

    /// The program a C2PA claim names. The claim is CBOR inside JUMBF; rather than decode it
    /// all, the key is found and the text after it read. A claim names its program either as
    /// "claim_generator" (one string) or as "claim_generator_info" (maps with a "name").
    static func c2paGenerator(_ b: [UInt8]) -> String? {
        if let info = index(of: cborText("claim_generator_info"), in: b, from: 0),
           let name = index(of: cborText("name"), in: b, from: info),
           let value = cborString(b, name + 5) {
            return value.trimmed.nilIfEmpty
        }
        if let key = index(of: cborText("claim_generator"), in: b, from: 0),
           let value = cborString(b, key + 16) {
            // "Adobe_Firefly adobe_c2pa/0.7.6 c2pa-rs/0.25.2" → "Adobe Firefly"
            let words = value.split(separator: " ").filter { !$0.localizedCaseInsensitiveContains("c2pa") }
            let program = words.map { $0.split(separator: "/").first.map(String.init) ?? "" }
                .joined(separator: " ").replacingOccurrences(of: "_", with: " ")
            return program.trimmed.nilIfEmpty
        }
        return nil
    }

    /// The same IPTC source type, said inside the credentials' list of actions.
    static func c2paVerdict(_ b: [UInt8]) -> Verdict? {
        if index(of: Array("compositeWithTrainedAlgorithmicMedia".utf8), in: b, from: 0) != nil {
            return .composite
        }
        if index(of: Array("trainedAlgorithmicMedia".utf8), in: b, from: 0) != nil { return .generated }
        return nil
    }

    /// A CBOR text string's head and bytes (shorter than 256 bytes — a key always is).
    private static func cborText(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return (bytes.count < 24 ? [0x60 | UInt8(bytes.count)] : [0x78, UInt8(bytes.count)]) + bytes
    }

    private static func cborString(_ b: [UInt8], _ i: Int) -> String? {
        guard i < b.count, b[i] >> 5 == 3 else { return nil }
        let info = Int(b[i] & 0x1F)
        var length = info, start = i + 1
        switch info {
        case 0..<24: break
        case 24:
            guard i + 1 < b.count else { return nil }
            length = Int(b[i + 1]); start = i + 2
        case 25:
            guard let long = Binary.u16(b, i + 1) else { return nil }
            length = long; start = i + 3
        default:
            return nil
        }
        guard start + length <= b.count else { return nil }
        return String(bytes: b[start..<(start + length)], encoding: .utf8)
    }

    private static func index(of pattern: [UInt8], in b: [UInt8], from start: Int) -> Int? {
        guard let first = pattern.first, start >= 0 else { return nil }
        var i = start
        while i + pattern.count <= b.count {
            if b[i] == first, b[i..<(i + pattern.count)].elementsEqual(pattern) { return i }
            i += 1
        }
        return nil
    }

    // MARK: - For the panel

    /// The lines of the "Origin" section of the photo panel.
    var entries: [PhotoMetadataService.Entry] {
        var rows: [PhotoMetadataService.Entry] = []
        func add(_ key: String, _ value: String?) {
            guard let value = value?.trimmed, !value.isEmpty else { return }
            // A whole ComfyUI prompt can run to pages; the panel shows the start.
            let shown = value.count > 2000 ? String(value.prefix(2000)) + "…" : value
            rows.append(PhotoMetadataService.Entry(section: .origin, label: L(key), value: shown))
        }
        add("exif.ai.made", verdict.map { L("exif.ai.made.\($0.rawValue)") })
        add("exif.ai.generator", generator)
        add("exif.ai.model", model)
        add("exif.ai.prompt", prompt)
        add("exif.ai.negative", negativePrompt)
        add("exif.ai.settings", settings)
        add("exif.ai.credentials", credentials.map {
            $0.isEmpty ? L("exif.ai.credentials.present") : String(format: L("exif.ai.credentials.by"), $0)
        })
        return rows
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
