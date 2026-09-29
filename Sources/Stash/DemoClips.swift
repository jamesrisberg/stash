import AppKit
import StashKit

/// Sample history for `--demo` (pictures and docs).
@MainActor
enum DemoClips {
    static func seed(_ model: AppModel) {
        let store = model.store
        store.clear(keepPinned: false)
        let now = Date()
        func add(_ payload: ClipPayload, _ source: String, minutesAgo: Double, pin: Bool = false) {
            guard let clip = try? store.add(payload, source: source, date: now - minutesAgo * 60).clip else { return }
            if pin { store.setPinned(true, id: clip.id) }
        }
        func addFeed(_ text: String, source: String, minutesAgo: Double) {
            _ = try? store.add(.text(text), feedSource: source, date: now - minutesAgo * 60)
        }
        // Oldest first so the newest ends on top.
        add(.text("james.risberg@example.com"), "com.apple.mail", minutesAgo: 2900, pin: true)
        add(.text("ssh -L 8080:localhost:80 deploy@staging.internal"), "com.mitchellh.ghostty", minutesAgo: 1500, pin: true)
        add(.text("Meeting notes: ship Stash compact strip, then wire MacHUD badges."), "com.apple.Notes", minutesAgo: 190)
        if let calc = ["/System/Applications/Calculator.app", "/System/Applications/Notes.app"]
            .first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let url = URL(filePath: calc)
            add(ClipPayload(kind: .files, text: calc, fileURLs: [url]), "com.apple.finder", minutesAgo: 64)
        }
        if let rtf = NSAttributedString(string: "Bold claims need citations.",
                                        attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
            .rtf(from: NSRange(location: 0, length: 27)) {
            add(ClipPayload(kind: .richText, text: "Bold claims need citations.", blobData: rtf, blobExtension: "rtf"),
                "com.apple.TextEdit", minutesAgo: 31)
        }
        add(.text("https://github.com/jrisberg/stash/pull/1"), "com.apple.Safari", minutesAgo: 12)
        let png = gradientPNG()
        add(ClipPayload(kind: .image, blobData: png, blobExtension: "png", imageSize: CGSizeCodable(width: 640, height: 400)),
            "com.apple.Preview", minutesAgo: 4)
        add(.text("func paste(_ clip: Clip) {\n    model.copy(clip)\n    Paster.postCommandV()\n}"), "com.apple.dt.Xcode", minutesAgo: 0.2)
        addFeed("Remind me to send the invoice before Friday.", source: "Dictation", minutesAgo: 0.1)
        model.selectFirst()
    }

    private static func gradientPNG() -> Data {
        let size = NSSize(width: 640, height: 400)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.49, green: 0.36, blue: 0.99, alpha: 1),
                                NSColor(red: 0.96, green: 0.45, blue: 0.71, alpha: 1),
                                NSColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1)])?.draw(in: rect, angle: 30)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: 420, y: 230, width: 120, height: 120)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
