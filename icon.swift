import AppKit
let n: CGFloat = 1024
let img = NSImage(size: NSSize(width: n, height: n))
img.lockFocus()
let s = NSAttributedString(string: "🍊", attributes: [.font: NSFont.systemFont(ofSize: 800)])
let z = s.size()
s.draw(at: NSPoint(x: (n - z.width) / 2, y: (n - z.height) / 2))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
