import AppKit
import Foundation

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "RecallCaptureIcon", code: 1)
    }

    let dimension = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    NSColor.clear.setFill()
    rect.fill()

    let inset = dimension * 0.035
    let tileRect = rect.insetBy(dx: inset, dy: inset)
    let tile = NSBezierPath(
        roundedRect: tileRect,
        xRadius: dimension * 0.22,
        yRadius: dimension * 0.22
    )
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.19, green: 0.22, blue: 0.62, alpha: 1),
        ending: NSColor(calibratedRed: 0.08, green: 0.50, blue: 0.78, alpha: 1)
    )!
    gradient.draw(in: tileRect, angle: -55)
    NSGraphicsContext.restoreGraphicsState()

    let waveform = NSBezierPath()
    waveform.lineWidth = max(1.6, dimension * 0.055)
    waveform.lineCapStyle = .round
    waveform.lineJoinStyle = .round
    let points: [(CGFloat, CGFloat)] = [
        (0.20, 0.50), (0.29, 0.50), (0.35, 0.69), (0.43, 0.30),
        (0.51, 0.76), (0.60, 0.39), (0.67, 0.57), (0.76, 0.50)
    ]
    for (index, point) in points.enumerated() {
        let resolved = NSPoint(x: dimension * point.0, y: dimension * point.1)
        index == 0 ? waveform.move(to: resolved) : waveform.line(to: resolved)
    }
    NSColor.white.withAlphaComponent(0.96).setStroke()
    waveform.stroke()

    let dotDiameter = dimension * 0.22
    let dotRect = NSRect(
        x: dimension * 0.69,
        y: dimension * 0.16,
        width: dotDiameter,
        height: dotDiameter
    )
    let ringRect = dotRect.insetBy(dx: -dimension * 0.025, dy: -dimension * 0.025)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: ringRect).fill()
    NSColor(calibratedRed: 0.95, green: 0.16, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "RecallCaptureIcon", code: 2)
    }
    return data
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndianValue = value.bigEndian
    withUnsafeBytes(of: &bigEndianValue) { bytes in
        data.append(contentsOf: bytes)
    }
}

func makeICNS() throws -> Data {
    let representations: [(type: String, size: Int)] = [
        ("icp4", 16),
        ("icp5", 32),
        ("icp6", 64),
        ("ic07", 128),
        ("ic08", 256),
        ("ic09", 512),
        ("ic10", 1024)
    ]
    var chunks = Data()
    for representation in representations {
        let png = try drawIcon(size: representation.size)
        chunks.append(contentsOf: representation.type.utf8)
        appendBigEndian(UInt32(png.count + 8), to: &chunks)
        chunks.append(png)
    }

    var icon = Data("icns".utf8)
    appendBigEndian(UInt32(chunks.count + 8), to: &icon)
    icon.append(chunks)
    return icon
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon <output.icns>\n".utf8))
    exit(2)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try makeICNS().write(to: destination, options: .atomic)
