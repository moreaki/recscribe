import AppKit
import Foundation

// Existing RecScribe SF Symbols, rendered only for these portable design mocks.
let names = ["waveform.circle", "waveform", "rectangle.stack", "slider.horizontal.below.rectangle", "slider.horizontal.3", "point.3.connected.trianglepath.dotted", "headphones", "play.circle", "mic.fill", "speaker.wave.2.fill", "speaker.slash.fill", "arrow.counterclockwise", "externaldrive", "doc.text", "sparkles", "cpu", "wrench.and.screwdriver", "lock.shield", "folder", "gearshape", "checkmark.circle", "exclamationmark.triangle", "trash", "square.and.arrow.up", "magnifyingglass", "plus", "ellipsis", "play.fill", "stop.fill", "key.fill", "desktopcomputer", "cable.connector", "sun.max", "moon", "circle.lefthalf.filled", "app.connected.to.app.below.fill", "text.bubble", "chart.xyaxis.line"]
guard let output = ProcessInfo.processInfo.environment["RECSCRIBE_RUN_DIR"] else { fatalError("Use work-artifacts.py") }
var symbols: [String:String] = [:]
for name in names {
    guard let image = NSImage(systemSymbolName:name, accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:22,weight:.regular)) else { fatalError("Missing symbol: \(name)") }
    let canvas=NSImage(size:NSSize(width:40,height:40))
    canvas.lockFocus()
    NSColor.black.set()
    let ratio=min(30/image.size.width,30/image.size.height)
    let size=NSSize(width:image.size.width*ratio,height:image.size.height*ratio)
    image.draw(in:NSRect(x:(40-size.width)/2,y:(40-size.height)/2,width:size.width,height:size.height))
    canvas.unlockFocus()
    guard let tiff=canvas.tiffRepresentation, let rep=NSBitmapImageRep(data:tiff), let png=rep.representation(using:.png,properties:[:]) else { fatalError("Render failed") }
    symbols[name]="data:image/png;base64,"+png.base64EncodedString()
}
let data=try JSONSerialization.data(withJSONObject:symbols,options:[.sortedKeys])
try data.write(to:URL(fileURLWithPath:output).appendingPathComponent("sf-symbols.json"))
print("Exported \(symbols.count) native symbols to \(output)/sf-symbols.json")
