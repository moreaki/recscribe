import Testing
@testable import RecScribe

struct AudioFormatTests {
    @Test func liveCaptureHasOneFormatAndAConcreteSink() throws {
        #expect(AudioFormat.available == [.wav])
        #expect(AudioFormat.wav.fileExtension == "wav")
        #expect(AudioFormat.wav.shortName == "WAV")
        #expect(AudioFormat.wav.displayName == "WAV (Lossless)")
        #expect(try AudioFormat.wav.makeEncoder() is WAVWriter)
    }
    @Test(arguments: ["m4a", "flac", "mp3"])
    func archiveOnlyFormatsCannotBecomeLiveEncoders(name: String) {
        #expect(AudioFormat(rawValue: name) == nil)
    }
}
