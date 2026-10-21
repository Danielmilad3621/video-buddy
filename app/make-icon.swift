// make-icon.swift <out.png>: draws the 1024px Video Buddy icon (red gradient tile + white play symbol)
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Apple's icon grid leaves a ~100px margin around the tile
let box = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0xFA / 255, green: 0x23 / 255, blue: 0x3B / 255, alpha: 1),
           ending: NSColor(srgbRed: 0xB8 / 255, green: 0x13 / 255, blue: 0x2C / 255, alpha: 1))!.draw(in: tile, angle: -45)

let config = NSImage.SymbolConfiguration(pointSize: 380, weight: .bold)
    .applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let size = symbol.size
symbol.draw(in: NSRect(x: box.midX - size.width / 2 + 24, y: box.midY - size.height / 2, width: size.width, height: size.height))

NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
