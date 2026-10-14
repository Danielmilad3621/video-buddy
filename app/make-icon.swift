// make-icon.swift <out.png>: draws the 1024px app icon (gradient tile + SF Symbol)
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Apple's icon grid leaves a ~100px margin around the tile
let box = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.35, green: 0.30, blue: 0.95, alpha: 1),
           ending: NSColor(srgbRed: 0.90, green: 0.30, blue: 0.55, alpha: 1))!.draw(in: tile, angle: -60)

let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "waveform.and.magnifyingglass", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let size = symbol.size
symbol.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))

NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
