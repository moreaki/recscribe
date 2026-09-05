//
//  AudioFormatTests.swift
//  RecScribeTests
//
//  BL-011: the AudioFormat enum — metadata, availability, and the encoder
//  factory. Guards that every case is wired (extension + display name) and that
//  unimplemented formats fail safely at construction rather than producing a
//  bad file.
//

import Testing
import Foundation
@testable import RecScribe

@MainActor
struct AudioFormatTests {

    @Test("fileExtension is correct, non-empty, and dot-free for every case")
    func fileExtensions() {
        #expect(AudioFormat.wav.fileExtension == "wav")
        #expect(AudioFormat.m4a.fileExtension == "m4a")
        #expect(AudioFormat.flac.fileExtension == "flac")
        #expect(AudioFormat.mp3.fileExtension == "mp3")
        for format in AudioFormat.allCases {
            #expect(!format.fileExtension.isEmpty)
            #expect(!format.fileExtension.hasPrefix("."))   // callers add the dot
        }
    }

    @Test("displayName is non-empty and distinct for every case")
    func displayNames() {
        let names = AudioFormat.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == AudioFormat.allCases.count)   // no copy-paste dupes
    }

    @Test("available formats are [.wav, .m4a, .flac] after BL-013")
    func availability() {
        #expect(AudioFormat.available == [.wav, .m4a, .flac])
    }

    @Test("makeEncoder() returns a WAVWriter for .wav")
    func wavFactory() throws {
        let encoder = try AudioFormat.wav.makeEncoder()
        #expect(encoder is WAVWriter)
    }

    @Test("makeEncoder() returns an M4AEncoder for .m4a")
    func m4aFactory() throws {
        let encoder = try AudioFormat.m4a.makeEncoder()
        #expect(encoder is M4AEncoder)
    }

    @Test("makeEncoder() returns a FLACEncoder for .flac")
    func flacFactory() throws {
        let encoder = try AudioFormat.flac.makeEncoder()
        #expect(encoder is FLACEncoder)
    }

    @Test("makeEncoder() throws .notImplemented for stubbed formats",
          arguments: [AudioFormat.mp3])
    func stubbedFactoriesThrow(_ format: AudioFormat) {
        #expect(throws: AudioFormatError.notImplemented(format)) {
            _ = try format.makeEncoder()
        }
    }
}
