// Mandarine — convertisseur de fichiers local pour macOS
// ⇧ + glisser un fichier dans le Finder → roue de conversion
// ⌥ + glisser un fichier                → roue d'outils
// Tout est traité en local. ffmpeg (Homebrew) est optionnel et débloque MP3, WEBM, FLAC…

import Cocoa
import AVFoundation
import PDFKit
import Vision
import UniformTypeIdentifiers
import ImageIO
import CoreText
import ServiceManagement

// MARK: - Utilitaires

struct E: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

typealias Conv = (URL, URL) throws -> Void

struct Item {
    let label: String
    let perform: ([URL]) throws -> String
}

func norm(_ e: String) -> String {
    let x = e.lowercased()
    switch x {
    case "jpeg": return "jpg"
    case "tif": return "tiff"
    case "htm": return "html"
    case "markdown": return "md"
    case "aif": return "aiff"
    default: return x
    }
}

func uniq(_ dir: URL, _ base: String, _ ext: String) -> URL {
    var i = 1
    while true {
        let name = (i == 1 ? base : "\(base) \(i)") + (ext.isEmpty ? "" : "." + ext)
        let u = dir.appendingPathComponent(name, isDirectory: false)
        if !FileManager.default.fileExists(atPath: u.path) { return u }
        i += 1
    }
}

func outURL(_ s: URL, ext: String, suffix: String = "") -> URL {
    uniq(s.deletingLastPathComponent(), s.deletingPathExtension().lastPathComponent + suffix, ext)
}

func byName(_ urls: [URL]) -> [URL] {
    urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func fileSize(_ u: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

func onMain<T>(_ f: () throws -> T) throws -> T {
    if Thread.isMainThread { return try f() }
    var r: Result<T, Error>!
    DispatchQueue.main.sync { r = Result { try f() } }
    return try r.get()
}

func copyToClipboard(_ s: String) {
    _ = try? onMain {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

func shell(_ exe: String, _ args: [String], cwd: URL? = nil) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        let msg = String(data: data, encoding: .utf8)?
            .split(separator: "\n").last.map(String.init) ?? "Échec"
        throw E(msg)
    }
}

enum FF {
    static let path: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ s: URL, _ d: URL, _ args: [String]) throws {
        guard let path else { throw E("Nécessite ffmpeg : brew install ffmpeg") }
        try shell(path, ["-y", "-hide_banner", "-loglevel", "error", "-i", s.path] + args + [d.path])
    }
}

// MARK: - Type de fichier

enum Kind { case image, video, audio, pdf, text, archive, folder, other }

let textExts: Set<String> = ["txt", "md", "rtf", "rtfd", "html", "docx", "doc", "odt"]
let videoExts: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "mts", "m2ts", "3gp", "mpg", "mpeg"]
let audioExts: Set<String> = ["ogg", "opus", "wma", "ape", "flac"]

func kind(of u: URL) -> Kind {
    let e = norm(u.pathExtension)
    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        return e == "rtfd" ? .text : .folder
    }
    if textExts.contains(e) { return .text }
    if videoExts.contains(e) { return .video }
    if audioExts.contains(e) { return .audio }
    if e == "zip" { return .archive }
    guard let t = UTType(filenameExtension: e) else { return .other }
    if t.conforms(to: .pdf) { return .pdf }
    if t.conforms(to: .image) { return .image }
    if t.conforms(to: .movie) { return .video }
    if t.conforms(to: .audio) { return .audio }
    return .other
}

// MARK: - Images

enum Img {
    static let writable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func load(_ u: URL, maxPixel: Int? = nil) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw E("Image illisible")
        }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        var side = max(w, h)
        if side == 0 { side = 8192 }
        if let m = maxPixel { side = min(side, m) }
        let o: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // respecte l'orientation EXIF
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary) else {
            throw E("Image illisible")
        }
        return img
    }

    static func ctx(_ w: Int, _ h: Int, opaque: Bool = false) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)
    }

    static func flatten(_ img: CGImage) -> CGImage {
        guard let c = ctx(img.width, img.height, opaque: true) else { return img }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        c.fill(r)
        c.draw(img, in: r)
        return c.makeImage() ?? img
    }

    static func write(_ img: CGImage, _ d: URL, uti: String, q: Double = 0.92) throws {
        let opaque = uti == "public.jpeg" || uti == "com.microsoft.bmp"
        let im = opaque ? flatten(img) : img
        guard let dest = CGImageDestinationCreateWithURL(d as CFURL, uti as CFString, 1, nil) else {
            throw E("Format non supporté")
        }
        CGImageDestinationAddImage(dest, im, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw E("Écriture impossible") }
    }

    static func convert(_ s: URL, _ d: URL, uti: String) throws {
        try write(try load(s), d, uti: uti)
    }

    /// Même format que la source si possible, sinon PNG.
    static func sameFormat(_ u: URL) -> (uti: String, ext: String) {
        let e = norm(u.pathExtension)
        if let t = UTType(filenameExtension: e), writable.contains(t.identifier) { return (t.identifier, e) }
        return ("public.png", "png")
    }

    static func resize(_ img: CGImage, _ k: CGFloat) -> CGImage {
        let w = max(1, Int(CGFloat(img.width) * k)), h = max(1, Int(CGFloat(img.height) * k))
        guard let c = ctx(w, h) else { return img }
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage() ?? img
    }

    static func rotate90(_ img: CGImage) -> CGImage {
        let w = img.width, h = img.height
        guard let c = ctx(h, w) else { return img }
        c.translateBy(x: 0, y: CGFloat(w))
        c.rotate(by: -.pi / 2)
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage() ?? img
    }

    static func toPDF(_ urls: [URL], _ d: URL) throws {
        let doc = PDFDocument()
        for u in urls {
            let cg = try load(u)
            let k = min(1, 842 / CGFloat(max(cg.width, cg.height)))
            let ns = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) * k, height: CGFloat(cg.height) * k))
            guard let page = PDFPage(image: ns) else { throw E("Création PDF impossible") }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.write(to: d) else { throw E("Écriture PDF impossible") }
    }

    static func ocr(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["fr-FR", "en-US"]
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func barcodes(_ img: CGImage) throws -> [String] {
        let req = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.payloadStringValue }
    }
}

// MARK: - Vidéo & audio

enum Vid {
    static let types: [String: AVFileType] = ["mp4": .mp4, "mov": .mov, "m4v": .m4v, "m4a": .m4a]

    static func export(_ a: AVAsset, _ d: URL, _ preset: String, _ type: AVFileType) throws {
        guard let s = AVAssetExportSession(asset: a, presetName: preset) else { throw E("Export impossible") }
        guard s.supportedFileTypes.contains(type) else { throw E("Format non supporté nativement") }
        s.outputURL = d
        s.outputFileType = type
        let sem = DispatchSemaphore(value: 0)
        s.exportAsynchronously { sem.signal() }
        sem.wait()
        if s.status != .completed {
            try? FileManager.default.removeItem(at: d)
            throw E(s.error?.localizedDescription ?? "Échec de l'export")
        }
    }

    static func convert(_ s: URL, _ d: URL) throws {
        guard let t = types[norm(d.pathExtension)] else { throw E("Format non supporté") }
        do { try export(AVURLAsset(url: s), d, AVAssetExportPresetPassthrough, t) }
        catch {
            try? FileManager.default.removeItem(at: d)
            try export(AVURLAsset(url: s), d, AVAssetExportPresetHighestQuality, t)
        }
    }

    static func audioM4A(_ s: URL, _ d: URL) throws {
        try export(AVURLAsset(url: s), d, AVAssetExportPresetAppleM4A, .m4a)
    }

    static func gif(_ s: URL, _ d: URL) throws {
        let a = AVURLAsset(url: s)
        let dur = CMTimeGetSeconds(a.duration)
        guard dur.isFinite, dur > 0 else { throw E("Vidéo illisible") }
        let g = AVAssetImageGenerator(asset: a)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 480, height: 480)
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        let fps = 10.0
        let n = max(1, Int(min(dur, 20) * fps))   // 20 s max
        var frames: [CGImage] = []
        for i in 0..<n {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let f = try? g.copyCGImage(at: t, actualTime: nil) { frames.append(f) }
        }
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(d as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw E("GIF impossible") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let fp = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(dest, f, fp) }
        guard CGImageDestinationFinalize(dest) else { throw E("GIF impossible") }
    }

    static func mute(_ s: URL, _ d: URL) throws {
        let a = AVURLAsset(url: s)
        guard let vt = a.tracks(withMediaType: .video).first else { throw E("Pas de piste vidéo") }
        let comp = AVMutableComposition()
        guard let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw E("Erreur de composition")
        }
        try t.insertTimeRange(CMTimeRange(start: .zero, duration: a.duration), of: vt, at: .zero)
        t.preferredTransform = vt.preferredTransform
        try export(comp, d, AVAssetExportPresetPassthrough, types[norm(d.pathExtension)] ?? .mp4)
    }
}

enum Aud {
    static func pcm(_ s: URL, _ d: URL) throws {
        let inF = try AVAudioFile(forReading: s)
        let fmt = inF.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: norm(d.pathExtension) == "aiff",
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outF = try AVAudioFile(forWriting: d, settings: settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536) else { throw E("Mémoire insuffisante") }
        while inF.framePosition < inF.length {
            try inF.read(into: buf)
            if buf.frameLength == 0 { break }
            try outF.write(from: buf)
        }
    }
}

// MARK: - PDF

enum Pdf {
    static func open(_ u: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: u) else { throw E("PDF illisible") }
        if d.isLocked { throw E("PDF protégé par mot de passe") }
        return d
    }

    static func pageImage(_ p: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let b = p.bounds(for: .mediaBox)
        let rot = p.rotation % 180 != 0
        let size = NSSize(width: (rot ? b.height : b.width) * scale, height: (rot ? b.width : b.height) * scale)
        let ns = p.thumbnail(of: size, for: .mediaBox)
        var r = NSRect(origin: .zero, size: ns.size)
        return ns.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    static func toImages(_ s: URL, _ d: URL, uti: String) throws {
        let doc = try open(s)
        guard doc.pageCount > 0 else { throw E("PDF vide") }
        let dir = d.deletingLastPathComponent(), base = d.deletingPathExtension().lastPathComponent, ext = d.pathExtension
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i), let img = pageImage(p) else { continue }
            let out = doc.pageCount == 1 ? d : uniq(dir, "\(base)-\(i + 1)", ext)
            try Img.write(img, out, uti: uti)
        }
    }

    /// Texte du PDF, avec OCR automatique si le PDF est scanné.
    static func text(_ u: URL) throws -> String {
        let doc = try open(u)
        let t = doc.string ?? ""
        if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        var out: [String] = []
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i), let img = pageImage(p) { out.append(try Img.ocr(img)) }
        }
        return out.joined(separator: "\n\n")
    }
}

// MARK: - Documents texte

enum Txt {
    static let types: [String: NSAttributedString.DocumentType] = [
        "txt": .plain, "rtf": .rtf, "rtfd": .rtfd, "html": .html,
        "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument,
    ]

    static func read(_ u: URL) throws -> NSAttributedString {
        let e = norm(u.pathExtension)
        return try onMain {
            if e == "md" {
                let s = try String(contentsOf: u, encoding: .utf8)
                return try NSAttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace), baseURL: nil)
            }
            var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let t = types[e] { opts[.documentType] = t }
            if e == "txt" || e == "html" { opts[.characterEncoding] = String.Encoding.utf8.rawValue }
            return try NSAttributedString(url: u, options: opts, documentAttributes: nil)
        }
    }

    static func write(_ s: NSAttributedString, _ d: URL) throws {
        let e = norm(d.pathExtension)
        try onMain {
            switch e {
            case "pdf": try pdf(s, d)
            case "txt", "md": try s.string.write(to: d, atomically: true, encoding: .utf8)
            default:
                guard let t = types[e] else { throw E("Format non supporté") }
                let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: t])
                try data.write(to: d)
            }
        }
    }

    static func pdf(_ s: NSAttributedString, _ d: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
        guard let c = CGContext(d as CFURL, mediaBox: &box, nil) else { throw E("PDF impossible") }
        let fs = CTFramesetterCreateWithAttributedString(s as CFAttributedString)
        let path = CGPath(rect: box.insetBy(dx: 56, dy: 56), transform: nil)
        var pos = 0
        repeat {
            c.beginPDFPage(nil)
            let f = CTFramesetterCreateFrame(fs, CFRange(location: pos, length: 0), path, nil)
            CTFrameDraw(f, c)
            c.endPDFPage()
            let n = CTFrameGetVisibleStringRange(f).length
            if n == 0 { break }
            pos += n
        } while pos < s.length
        c.closePDF()
    }
}

// MARK: - Archives

enum Arc {
    static func unzip(_ s: URL) throws -> URL {
        let d = uniq(s.deletingLastPathComponent(), s.deletingPathExtension().lastPathComponent, "")
        try shell("/usr/bin/ditto", ["-x", "-k", s.path, d.path])
        return d
    }

    static func zip(_ urls: [URL]) throws -> String {
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        if urls.count > 1 && parents.count == 1 {
            let parent = urls[0].deletingLastPathComponent()
            let d = uniq(parent, "Archive", "zip")
            try shell("/usr/bin/zip", ["-r", "-q", "-X", d.path] + urls.map { $0.lastPathComponent }, cwd: parent)
            return "✓ \(d.lastPathComponent)"
        }
        var last = ""
        for u in urls {
            let d = outURL(u, ext: "zip")
            try shell("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", u.path, d.path])
            last = d.lastPathComponent
        }
        return "✓ \(last)"
    }
}

// MARK: - Catalogue des actions

func conv(_ label: String, _ ext: String, _ native: Conv?, _ ff: [String]?) -> Item? {
    if native == nil && (ff == nil || FF.path == nil) { return nil }
    return Item(label: label) { urls in
        var last = ""
        for u in urls {
            let d = outURL(u, ext: ext)
            do {
                guard let n = native else { throw E("ffmpeg") }
                try n(u, d)
            } catch {
                try? FileManager.default.removeItem(at: d)
                guard let ff, FF.path != nil else { throw error }
                try FF.run(u, d, ff)
            }
            last = d.lastPathComponent
        }
        return urls.count == 1 ? "✓ \(last)" : "✓ \(urls.count) fichiers convertis"
    }
}

func each(_ label: String, _ f: @escaping (URL) throws -> URL) -> Item {
    Item(label: label) { urls in
        var last = ""
        for u in urls { last = try f(u).lastPathComponent }
        return urls.count == 1 ? "✓ \(last)" : "✓ \(urls.count) fichiers traités"
    }
}

func copyResult(_ t: String) throws -> String {
    let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { throw E("Aucun texte détecté") }
    copyToClipboard(s)
    return "✓ Texte copié (\(s.count) caractères)"
}

enum FFA {
    static let mp3 = ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
    static let aac = ["-vn", "-c:a", "aac", "-b:a", "192k"]
    static let flac = ["-vn", "-c:a", "flac"]
    static let ogg = ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
    static let opus = ["-vn", "-c:a", "libopus", "-b:a", "128k"]
    static let mp4 = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart"]
    static let mov = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac"]
    static let webm = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
    static let avi = ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame"]
    static let gif = ["-vf", "fps=10,scale=480:-1:flags=lanczos", "-t", "20"]
    static let webp = ["-c:v", "libwebp", "-quality", "85"]
}

enum Catalog {
    static var zipItem: Item { Item(label: "ZIP") { try Arc.zip($0) } }

    static func conversions(_ k: Kind, _ urls: [URL]) -> [Item] {
        let src = norm(urls[0].pathExtension)
        var list: [Item?] = []
        switch k {
        case .image:
            let fmts = [("JPG", "jpg", "public.jpeg"), ("PNG", "png", "public.png"), ("HEIC", "heic", "public.heic"),
                        ("WEBP", "webp", "org.webmproject.webp"), ("TIFF", "tiff", "public.tiff"),
                        ("GIF", "gif", "com.compuserve.gif"), ("BMP", "bmp", "com.microsoft.bmp")]
            for (label, ext, uti) in fmts where ext != src {
                var nat: Conv? = nil
                if Img.writable.contains(uti) { nat = { s, d in try Img.convert(s, d, uti: uti) } }
                list.append(conv(label, ext, nat, ext == "webp" ? FFA.webp : nil))
            }
            list.append(conv("PDF", "pdf", { s, d in try Img.toPDF([s], d) }, nil))

        case .video:
            let fmts: [(String, String, Conv?, [String]?)] = [
                ("MP4", "mp4", Vid.convert, FFA.mp4), ("MOV", "mov", Vid.convert, FFA.mov),
                ("GIF", "gif", Vid.gif, FFA.gif), ("WEBM", "webm", nil, FFA.webm),
                ("MKV", "mkv", nil, ["-c", "copy"]), ("AVI", "avi", nil, FFA.avi),
                ("M4A", "m4a", Vid.audioM4A, FFA.aac), ("MP3", "mp3", nil, FFA.mp3),
            ]
            for (label, ext, nat, ff) in fmts where ext != src { list.append(conv(label, ext, nat, ff)) }

        case .audio:
            let fmts: [(String, String, Conv?, [String]?)] = [
                ("MP3", "mp3", nil, FFA.mp3), ("M4A", "m4a", Vid.audioM4A, FFA.aac),
                ("WAV", "wav", Aud.pcm, ["-vn"]), ("AIFF", "aiff", Aud.pcm, ["-vn"]),
                ("FLAC", "flac", nil, FFA.flac), ("OGG", "ogg", nil, FFA.ogg), ("OPUS", "opus", nil, FFA.opus),
            ]
            for (label, ext, nat, ff) in fmts where ext != src { list.append(conv(label, ext, nat, ff)) }

        case .pdf:
            list.append(conv("PNG", "png", { s, d in try Pdf.toImages(s, d, uti: "public.png") }, nil))
            list.append(conv("JPG", "jpg", { s, d in try Pdf.toImages(s, d, uti: "public.jpeg") }, nil))
            list.append(conv("TXT", "txt", { s, d in try Pdf.text(s).write(to: d, atomically: true, encoding: .utf8) }, nil))
            list.append(conv("DOCX", "docx", { s, d in try Txt.write(NSAttributedString(string: try Pdf.text(s)), d) }, nil))

        case .text:
            for (label, ext) in [("PDF", "pdf"), ("DOCX", "docx"), ("TXT", "txt"), ("RTF", "rtf"),
                                 ("HTML", "html"), ("ODT", "odt"), ("DOC", "doc")] where ext != src {
                list.append(conv(label, ext, { s, d in try Txt.write(try Txt.read(s), d) }, nil))
            }

        case .archive:
            list.append(Item(label: "Décom-\npresser") { urls in
                var last = ""
                for u in urls { last = try Arc.unzip(u).lastPathComponent }
                return "✓ \(last)"
            })

        case .folder, .other:
            list.append(zipItem)
        }
        return list.compactMap { $0 }
    }

    static func tools(_ k: Kind, _ urls: [URL]) -> [Item] {
        switch k {
        case .image:
            return [
                each("Compresser") { u in
                    let d = outURL(u, ext: "jpg", suffix: "-compressé")
                    try Img.write(try Img.load(u, maxPixel: 2560), d, uti: "public.jpeg", q: 0.6)
                    return d
                },
                each("Réduire\n50 %") { u in
                    let f = Img.sameFormat(u)
                    let d = outURL(u, ext: f.ext, suffix: "-50")
                    try Img.write(Img.resize(try Img.load(u), 0.5), d, uti: f.uti)
                    return d
                },
                each("Pivoter\n↻") { u in
                    let f = Img.sameFormat(u)
                    let d = outURL(u, ext: f.ext, suffix: "-pivoté")
                    try Img.write(Img.rotate90(try Img.load(u)), d, uti: f.uti, q: 0.95)
                    return d
                },
                each("Sans\nméta") { u in
                    let f = Img.sameFormat(u)
                    let d = outURL(u, ext: f.ext, suffix: "-clean")
                    try Img.write(try Img.load(u), d, uti: f.uti, q: 0.95)
                    return d
                },
                Item(label: "Texte\n(OCR)") { urls in
                    try copyResult(try urls.map { try Img.ocr(try Img.load($0)) }.joined(separator: "\n\n"))
                },
                Item(label: "QR\ncode") { urls in
                    let codes = try urls.flatMap { try Img.barcodes(try Img.load($0)) }
                    guard let first = codes.first else { throw E("Aucun QR code détecté") }
                    copyToClipboard(codes.joined(separator: "\n"))
                    return "✓ Copié : \(first)"
                },
                Item(label: "PDF\nunique") { urls in
                    let s = byName(urls)
                    let d = outURL(s[0], ext: "pdf")
                    try Img.toPDF(s, d)
                    return "✓ \(d.lastPathComponent)"
                },
                zipItem,
            ]

        case .video:
            return [
                each("Compresser") { u in
                    let d = outURL(u, ext: "mp4", suffix: "-compressé")
                    do { try Vid.export(AVURLAsset(url: u), d, AVAssetExportPresetHEVC1920x1080, .mp4) }
                    catch {
                        try? FileManager.default.removeItem(at: d)
                        try FF.run(u, d, ["-c:v", "libx264", "-crf", "28", "-preset", "medium", "-pix_fmt", "yuv420p",
                                          "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"])
                    }
                    return d
                },
                each("Extraire\naudio") { u in
                    let d = outURL(u, ext: "m4a")
                    do { try Vid.audioM4A(u, d) }
                    catch { try? FileManager.default.removeItem(at: d); try FF.run(u, d, FFA.aac) }
                    return d
                },
                each("Muet") { u in
                    let d = outURL(u, ext: norm(u.pathExtension) == "mov" ? "mov" : "mp4", suffix: "-muet")
                    do { try Vid.mute(u, d) }
                    catch { try? FileManager.default.removeItem(at: d); try FF.run(u, d, ["-an", "-c:v", "copy"]) }
                    return d
                },
                each("GIF") { u in
                    let d = outURL(u, ext: "gif")
                    do { try Vid.gif(u, d) }
                    catch { try? FileManager.default.removeItem(at: d); try FF.run(u, d, FFA.gif) }
                    return d
                },
                zipItem,
            ]

        case .pdf:
            return [
                Item(label: "Compresser") { urls in
                    var saved: Int64 = 0
                    var last = ""
                    for u in urls {
                        let doc = try Pdf.open(u)
                        let d = outURL(u, ext: "pdf", suffix: "-compressé")
                        var opts: [PDFDocumentWriteOption: Any] = [:]
                        if #available(macOS 13.4, *) {
                            opts = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
                        }
                        guard doc.write(to: d, withOptions: opts) else { throw E("Compression impossible") }
                        let a = fileSize(u), b = fileSize(d)
                        if b >= a { try? FileManager.default.removeItem(at: d); continue }
                        saved += a - b
                        last = d.lastPathComponent
                    }
                    if last.isEmpty { return "Déjà optimisé, rien à gagner" }
                    return "✓ \(last) (−\(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)))"
                },
                Item(label: "Diviser") { urls in
                    var n = 0
                    for u in urls {
                        let doc = try Pdf.open(u)
                        let dir = u.deletingLastPathComponent(), base = u.deletingPathExtension().lastPathComponent
                        for i in 0..<doc.pageCount {
                            guard let p = doc.page(at: i)?.copy() as? PDFPage else { continue }
                            let one = PDFDocument()
                            one.insert(p, at: 0)
                            if one.write(to: uniq(dir, "\(base)-p\(i + 1)", "pdf")) { n += 1 }
                        }
                    }
                    return "✓ \(n) pages extraites"
                },
                Item(label: "Fusionner") { urls in
                    let s = byName(urls)
                    let out = PDFDocument()
                    for u in s {
                        let doc = try Pdf.open(u)
                        for i in 0..<doc.pageCount {
                            if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
                        }
                    }
                    let d = uniq(s[0].deletingLastPathComponent(), "Fusion", "pdf")
                    guard out.write(to: d) else { throw E("Fusion impossible") }
                    return "✓ \(d.lastPathComponent) (\(out.pageCount) pages)"
                },
                each("Pivoter\n↻") { u in
                    let doc = try Pdf.open(u)
                    for i in 0..<doc.pageCount {
                        if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 }
                    }
                    let d = outURL(u, ext: "pdf", suffix: "-pivoté")
                    guard doc.write(to: d) else { throw E("Écriture impossible") }
                    return d
                },
                Item(label: "Copier\ntexte") { urls in
                    try copyResult(try urls.map { try Pdf.text($0) }.joined(separator: "\n\n"))
                },
                zipItem,
            ]

        case .text:
            return [
                Item(label: "Mots") { urls in
                    var w = 0, c = 0
                    for u in urls {
                        let s = try Txt.read(u).string
                        c += s.count
                        s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { _, _, _, _ in w += 1 }
                    }
                    return "\(w) mots · \(c) caractères"
                },
                zipItem,
            ]

        case .audio, .archive, .folder, .other:
            return [zipItem]
        }
    }
}

// MARK: - Notifications visuelles (toast)

enum Toast {
    static var panel: NSPanel?
    static let label = NSTextField(labelWithString: "")
    static var gen = 0

    static func show(_ text: String, near p: NSPoint, sticky: Bool = false) {
        let pnl = panel ?? make()
        label.stringValue = text
        let w = min(max(label.intrinsicContentSize.width + 40, 140), 460)
        pnl.setFrame(NSRect(x: p.x - w / 2, y: p.y - 90, width: w, height: 38), display: true)
        pnl.alphaValue = 1
        pnl.orderFrontRegardless()
        gen += 1
        let g = gen
        guard !sticky else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            guard g == gen else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; pnl.animator().alphaValue = 0 },
                                                completionHandler: { if g == gen { pnl.orderOut(nil) } })
        }
    }

    static func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 38),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = 19
        v.layer?.masksToBounds = true
        p.contentView = v
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
        ])
        panel = p
        return p
    }
}

enum Runner {
    static let queue = DispatchQueue(label: "mandarine.work", qos: .userInitiated)

    static func run(_ item: Item, _ urls: [URL]) {
        let p = NSEvent.mouseLocation
        Toast.show("⏳ \(item.label.replacingOccurrences(of: "\n", with: " "))…", near: p, sticky: true)
        queue.async {
            let msg: String
            do { msg = try item.perform(urls) } catch { msg = "⚠︎ " + error.localizedDescription }
            DispatchQueue.main.async {
                Toast.show(msg, near: p)
                NSSound(named: msg.hasPrefix("⚠︎") ? "Basso" : "Pop")?.play()
            }
        }
    }
}

// MARK: - Roue radiale

final class RadialView: NSView {
    var items: [Item] = []
    var urls: [URL] = []
    var title = ""
    let rIn: CGFloat = 52, rOut: CGFloat = 170
    var hi: Int? {
        didSet {
            guard hi != oldValue else { return }
            needsDisplay = true
            if hi != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    var c: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    func configure(items: [Item], urls: [URL], title: String) {
        self.items = items
        self.urls = urls
        self.title = title
        hi = nil
        needsDisplay = true
    }

    func index(at p: NSPoint) -> Int? {
        let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
        let d = hypot(dx, dy)
        guard !items.isEmpty, d > Double(rIn), d < Double(rOut) + 10 else { return nil }
        let step = 360.0 / Double(items.count)
        let deg = atan2(dy, dx) * 180 / .pi
        var a = (90 - deg + step / 2).truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return min(items.count - 1, Int(a / step))
    }

    // Drag & drop : le fichier tombe sur la roue, pas dans le Finder
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { track(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { track(s) }
    override func draggingExited(_ s: NSDraggingInfo?) { hi = nil }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { true }

    private func track(_ s: NSDraggingInfo) -> NSDragOperation {
        hi = index(at: convert(s.draggingLocation, from: nil))
        return .copy
    }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let i = index(at: convert(s.draggingLocation, from: nil))
        hi = nil
        window?.orderOut(nil)
        if let i { Runner.run(items[i], urls) }   // relâché au centre = annuler
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = items.count
        guard n > 0 else { return }
        let disk = NSBezierPath(ovalIn: NSRect(x: c.x - rOut, y: c.y - rOut, width: rOut * 2, height: rOut * 2))
        NSColor(calibratedWhite: 0.08, alpha: 0.9).setFill()
        disk.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        disk.lineWidth = 1
        disk.stroke()

        let step = 360.0 / Double(n)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        for i in 0..<n {
            let mid = 90 - Double(i) * step
            let gap = n == 1 ? 0 : 1.2
            let a0 = CGFloat(mid - step / 2 + gap), a1 = CGFloat(mid + step / 2 - gap)
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: rOut - 6, startAngle: a0, endAngle: a1)
            p.appendArc(withCenter: c, radius: rIn + 6, startAngle: a1, endAngle: a0, clockwise: true)
            p.close()
            (i == hi ? NSColor.controlAccentColor : NSColor(calibratedWhite: 1, alpha: 0.07)).setFill()
            p.fill()

            let rad = mid * .pi / 180
            let lr = Double(rIn + rOut) / 2
            let pt = NSPoint(x: c.x + CGFloat(cos(rad) * lr), y: c.y + CGFloat(sin(rad) * lr))
            let long = items[i].label.contains("\n") || items[i].label.count > 5
            let s = NSAttributedString(string: items[i].label, attributes: [
                .font: NSFont.systemFont(ofSize: long ? 11.5 : 14, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: para,
            ])
            let h = s.size().height
            s.draw(in: NSRect(x: pt.x - 50, y: pt.y - h / 2, width: 100, height: h))
        }

        let ci = NSBezierPath(ovalIn: NSRect(x: c.x - rIn, y: c.y - rIn, width: rIn * 2, height: rIn * 2))
        NSColor(calibratedWhite: 0.16, alpha: 0.95).setFill()
        ci.fill()
        if let u = urls.first {
            NSWorkspace.shared.icon(forFile: u.path).draw(in: NSRect(x: c.x - 18, y: c.y - 6, width: 36, height: 36))
        }
        let t = NSAttributedString(string: urls.count > 1 ? "\(title) ×\(urls.count)" : title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.6),
            .paragraphStyle: para,
        ])
        t.draw(in: NSRect(x: c.x - rIn, y: c.y - 26, width: rIn * 2, height: 14))
    }
}

final class RadialPanel {
    let view = RadialView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
    let panel: NSPanel
    private var gen = 0

    init() {
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
    }

    func show(at p: NSPoint, urls: [URL], tools: Bool) {
        let k = kind(of: urls[0])
        let same = urls.filter { kind(of: $0) == k }
        var items = tools ? Catalog.tools(k, same) : Catalog.conversions(k, same)
        if items.isEmpty { items = [Catalog.zipItem] }
        view.configure(items: items, urls: same, title: tools ? "Outils" : "Convertir")
        gen += 1
        panel.setFrameOrigin(NSPoint(x: p.x - 180, y: p.y - 180))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.panel.animator().alphaValue = 1
        }
    }

    func hideLater() {
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.gen == g else { return }
            self.panel.orderOut(nil)
        }
    }
}

// MARK: - Détection du glisser-déposer (⇧ / ⌥)

final class DragWatcher {
    let radial = RadialPanel()
    private var timer: Timer?
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var wasDown = false
    private var shown = false

    func start() {
        let t = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let pb = NSPasteboard(name: .drag)
        let down = (NSEvent.pressedMouseButtons & 1) == 1
        guard down else {
            if wasDown && shown { radial.hideLater() }
            wasDown = false
            shown = false
            baseline = pb.changeCount
            return
        }
        wasDown = true
        guard !shown, pb.changeCount != baseline else { return }
        let f = NSEvent.modifierFlags
        let tools: Bool
        if f.contains(.shift) { tools = false }
        else if f.contains(.option) { tools = true }
        else { return }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        shown = true
        radial.show(at: NSEvent.mouseLocation, urls: urls, tools: tools)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let watcher = DragWatcher()
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🍊"
        buildMenu()
        watcher.start()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "🍊 Mandarine est prête"
            a.informativeText = "Dans le Finder, commence à glisser un fichier puis maintiens :\n\n⇧ Maj → roue de conversion\n⌥ Option → roue d'outils\n\nRelâche sur un format. Le résultat apparaît à côté de l'original. Relâche au centre pour annuler."
            a.addButton(withTitle: "Lancer au démarrage")
            a.addButton(withTitle: "Plus tard")
            if a.runModal() == .alertFirstButtonReturn { try? SMAppService.mainApp.register() }
            refreshLogin()
        }
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Mandarine est active", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "⇧ + glisser un fichier → Convertir", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "⌥ + glisser un fichier → Outils", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: FF.path != nil ? "ffmpeg détecté ✓ (formats étendus)"
                                            : "ffmpeg absent : brew install ffmpeg pour MP3, WEBM, FLAC…",
                  action: nil, keyEquivalent: "")
        loginItem = NSMenuItem(title: "Lancer au démarrage", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        m.addItem(loginItem)
        m.addItem(.separator())
        m.addItem(withTitle: "Quitter Mandarine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
        refreshLogin()
    }

    func refreshLogin() {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
        refreshLogin()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
