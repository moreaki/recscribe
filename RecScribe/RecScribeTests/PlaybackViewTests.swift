import AVKit
import SwiftUI
import Testing

@MainActor
struct PlaybackViewTests {
    @Test("The app links native AVKit and can render SwiftUI's player without a runtime abort")
    func playerViewRenders() throws {
        // Inspect the host executable: importing frameworks in a test bundle
        // must not accidentally hide a missing dependency in the shipped app.
        let executable = try #require(Bundle.main.executableURL)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", executable.path]
        process.standardOutput = output
        try process.run()
        let dependencies = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        try #require(dependencies.contains("/AVKit.framework/"))
        try #require(NSClassFromString("AVPlayerView") != nil)

        let player = AVPlayer()
        player.isMuted = true
        let hosting = NSHostingView(rootView: VideoPlayer(player: player))
        hosting.frame = CGRect(x: 0, y: 0, width: 640, height: 80)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { player.pause(); window.contentView = nil; window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(!hosting.subviews.isEmpty)
    }
}
