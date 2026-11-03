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

    @Test("available formats are [.wav]")
    func availability() {
        #expect(AudioFormat.available == [.wav])
    }

    @Test("makeEncoder() returns a WAVWriter for .wav")
    func wavFactory() throws {
        let encoder = try AudioFormat.wav.makeEncoder()
        #expect(encoder is WAVWriter)
    }

    @Test("makeEncoder() throws .notImplemented for non-live formats",
          arguments: [AudioFormat.m4a, .flac, .mp3])
    func stubbedFactoriesThrow(_ format: AudioFormat) {
        #expect(throws: AudioFormatError.notImplemented(format)) {
            _ = try format.makeEncoder()
        }
    }
}
