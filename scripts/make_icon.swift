import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
  fatalError("Usage: swift make_icon.swift /path/to/AppIcon.icns")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let representations: [(type: String, pixels: Int)] = [
  ("icp4", 16),
  ("icp5", 32),
  ("icp6", 64),
  ("ic07", 128),
  ("ic08", 256),
  ("ic09", 512),
  ("ic10", 1024),
]

func drawIcon(pixels: Int) throws -> Data {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixels,
      pixelsHigh: pixels,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bitmapFormat: [],
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  else {
    throw CocoaError(.fileWriteUnknown)
  }

  bitmap.size = NSSize(width: pixels, height: pixels)
  guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    throw CocoaError(.fileWriteUnknown)
  }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context

  let unit = CGFloat(pixels)
  let canvas = NSRect(x: 0, y: 0, width: unit, height: unit)
  NSColor.clear.setFill()
  canvas.fill()

  let outer = canvas.insetBy(dx: unit * 0.055, dy: unit * 0.055)
  let outerPath = NSBezierPath(
    roundedRect: outer,
    xRadius: unit * 0.22,
    yRadius: unit * 0.22
  )

  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
  shadow.shadowBlurRadius = unit * 0.055
  shadow.shadowOffset = NSSize(width: 0, height: -unit * 0.025)
  shadow.set()

  let background = NSGradient(
    starting: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1),
    ending: NSColor(calibratedRed: 0.025, green: 0.03, blue: 0.055, alpha: 1)
  )
  background?.draw(in: outerPath, angle: -58)

  NSGraphicsContext.restoreGraphicsState()
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context

  NSColor.white.withAlphaComponent(0.08).setStroke()
  outerPath.lineWidth = max(1, unit * 0.006)
  outerPath.stroke()

  let signal = NSGradient(
    starting: NSColor(
      calibratedRed: 0.46,
      green: 0.34,
      blue: 1,
      alpha: 1
    ),
    ending: NSColor(
      calibratedRed: 0.33,
      green: 0.84,
      blue: 1,
      alpha: 1
    )
  )

  let rail = NSBezierPath(
    roundedRect: NSRect(
      x: unit * 0.205,
      y: unit * 0.22,
      width: unit * 0.085,
      height: unit * 0.56
    ),
    xRadius: unit * 0.043,
    yRadius: unit * 0.043
  )
  signal?.draw(in: rail, angle: 88)

  for y in [0.35, 0.50, 0.65] {
    let diameter = max(1.5, unit * 0.025)
    NSColor(calibratedRed: 0.035, green: 0.04, blue: 0.07, alpha: 1)
      .setFill()
    NSBezierPath(
      ovalIn: NSRect(
        x: unit * 0.2475 - diameter / 2,
        y: unit * y - diameter / 2,
        width: diameter,
        height: diameter
      )
    )
    .fill()
  }

  let rearBubble = NSBezierPath(
    roundedRect: NSRect(
      x: unit * 0.41,
      y: unit * 0.40,
      width: unit * 0.40,
      height: unit * 0.30
    ),
    xRadius: unit * 0.10,
    yRadius: unit * 0.10
  )
  NSColor(
    calibratedRed: 0.33,
    green: 0.84,
    blue: 1,
    alpha: 0.16
  ).setFill()
  rearBubble.fill()
  NSColor(
    calibratedRed: 0.48,
    green: 0.88,
    blue: 1,
    alpha: 0.38
  ).setStroke()
  rearBubble.lineWidth = max(1, unit * 0.009)
  rearBubble.stroke()

  let bubble = NSBezierPath(
    roundedRect: NSRect(
      x: unit * 0.335,
      y: unit * 0.30,
      width: unit * 0.43,
      height: unit * 0.34
    ),
    xRadius: unit * 0.115,
    yRadius: unit * 0.115
  )
  signal?.draw(in: bubble, angle: 36)

  let tail = NSBezierPath()
  tail.move(to: NSPoint(x: unit * 0.63, y: unit * 0.32))
  tail.line(to: NSPoint(x: unit * 0.72, y: unit * 0.22))
  tail.line(to: NSPoint(x: unit * 0.695, y: unit * 0.39))
  tail.close()
  signal?.draw(in: tail, angle: 36)

  NSColor.white.withAlphaComponent(0.92).setFill()
  NSBezierPath(
    roundedRect: NSRect(
      x: unit * 0.42,
      y: unit * 0.49,
      width: unit * 0.25,
      height: max(1, unit * 0.026)
    ),
    xRadius: unit * 0.013,
    yRadius: unit * 0.013
  ).fill()

  NSColor.white.withAlphaComponent(0.54).setFill()
  NSBezierPath(
    roundedRect: NSRect(
      x: unit * 0.42,
      y: unit * 0.42,
      width: unit * 0.17,
      height: max(1, unit * 0.026)
    ),
    xRadius: unit * 0.013,
    yRadius: unit * 0.013
  ).fill()

  NSGraphicsContext.restoreGraphicsState()

  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  return png
}

func appendASCII(_ string: String, to data: inout Data) {
  data.append(string.data(using: .ascii)!)
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
  var bigEndian = value.bigEndian
  withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

var elements = Data()
for representation in representations {
  let png = try drawIcon(pixels: representation.pixels)
  appendASCII(representation.type, to: &elements)
  appendBigEndian(UInt32(png.count + 8), to: &elements)
  elements.append(png)
}

var icon = Data()
appendASCII("icns", to: &icon)
appendBigEndian(UInt32(elements.count + 8), to: &icon)
icon.append(elements)
try icon.write(to: outputURL)
