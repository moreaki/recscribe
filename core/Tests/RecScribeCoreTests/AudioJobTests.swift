import Foundation
import Synchronization
import Testing
@testable import RecScribeCore

enum AudioFixture {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-audio-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    static func wav(_ url: URL, channels: Int = 1, width: Int = 2, rate: Int = 16_000, frames: Int = 16_000,
                    sample: (Int, Int) -> Int64 = { _, _ in 1000 }) throws {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer(_ value: Int64, _ count: Int) { for byte in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) } }
        let bytes = frames * channels * width
        text("RIFF"); integer(Int64(bytes + 36), 4); text("WAVEfmt "); integer(16, 4)
        integer(1, 2); integer(Int64(channels), 2); integer(Int64(rate), 4); integer(Int64(rate * channels * width), 4)
        integer(Int64(channels * width), 2); integer(Int64(width * 8), 2); text("data"); integer(Int64(bytes), 4)
        for frame in 0..<frames { for channel in 0..<channels { integer(sample(frame, channel) + (width == 1 ? 128 : 0), width) } }
        try data.write(to: url, options: .withoutOverwriting)
    }
    static func read(_ root: URL, _ file: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(file))) }
    static func session(_ root: URL, parts: [(String, Int64)], missing: Int? = nil) throws -> URL {
        var end: Int64 = 0, entries: [JSONValue] = []
        for (index, pair) in parts.enumerated() {
            let (name, frames) = pair, path = root.appendingPathComponent(name)
            entries.append(["path": .string(name), "startSample": .integer(end), "frames": .integer(frames),
                "sizeBytes": .integer(frames * 2 + 44), "status": "verified",
                "sha256": .string(index == missing ? String(repeating: "a", count: 64) : try WAVAudio.hash(path))])
            end += frames
        }
        let value: JSONValue = ["schemaVersion": 3, "id": "synthetic-session", "status": "completed", "sampleRate": 16_000,
                               "channels": 1, "bitDepth": 16, "channelMap": ["channel-1"], "parts": .array(entries), "issues": []]
        let url = root.appendingPathComponent("synthetic.recscribe.json")
        try value.encoded().write(to: url)
        return url
    }
    struct Preparer: AudioPreparer {
        func prepare(_ source: URL, channel: Int, output: URL, check: @Sendable () throws -> Void) throws -> JSONValue {
            try check()
            let layout = try WAVAudio.layout(source), data = try Data(contentsOf: source)
            guard layout.rate == 16_000, layout.width == 2 else { throw CoreFailure("Synthetic preparer accepts PCM16/16k only") }
            try wav(output, frames: Int(layout.frames)) { frame, _ in
                let index = Int(layout.dataOffset) + (frame * layout.channels + channel) * 2
                return Int64(Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8))
            }
            return ["channel": .integer(Int64(channel)), "path": .string(output.lastPathComponent), "sha256": .string(try WAVAudio.hash(output)),
                    "sample_rate": 16_000, "bit_depth": 16]
        }
    }
    final class Engine: TranscriptEngine {
        let requests = Mutex<[String]>([])
        let model: String
        let text: String
        let action: @Sendable (URL) throws -> Void
        init(model: String = "a", text: String = " Gr üezi <test>! ", action: @escaping @Sendable (URL) throws -> Void = { _ in }) {
            self.model = model; self.text = text; self.action = action
        }
        func transcribe(_ audio: URL, output: URL, language: String, check: @Sendable () throws -> Void) throws -> AudioEngineResult {
            try check(); requests.withLock { $0.append(output.lastPathComponent) }
            let raw = output.appendingPathExtension("json")
            try Data("{\"raw\":true}\n".utf8).write(to: raw, options: .withoutOverwriting)
            try action(output); try check()
            return .init(segments: [["start_ms": 0, "end_ms": 800, "source_text": .string(text), "confidence": nil, "speaker": nil, "words": []]],
                         rawPath: raw, provenance: ["engine": "synthetic", "version": "1", "model": .string(model),
                            "model_sha256": .string(String(repeating: model, count: 64)), "command": [], "duration_seconds": 0, "local_only": true])
        }
    }
}

@Suite struct AudioJobTests {
    @Test(arguments: [1, 2, 3, 4])
    func streamingInspectionRetainsIntegerPCMAndMatchesReference(width: Int) throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), scale = Int64(1) << (width * 8 - 1)
        try AudioFixture.wav(source, channels: 2, width: width, rate: 44_100, frames: 1003) { frame, channel in
            switch frame % 4 { case 0: -scale; case 1: scale - 1; case 2: 0; default: Int64(channel + 1) }
        }
        let inspection = try WAVAudio.inspect(source)
        #expect(inspection.layout.width == width && inspection.layout.frames == 1003)
        #expect(inspection.report["channels_bit_identical"] == false)
        #expect(inspection.report["duration_ms"] == 23)
        #expect(inspection.report["channel_metrics"].array?[0]["peak"] == .number(1))
        try reference(root, source: source, job: nil)
    }

    @Test func exactWindowReuseRetainsDifferentChannelsAndContext() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("stereo.wav")
        try AudioFixture.wav(source, channels: 2, rate: 10, frames: 900) { frame, channel in channel == 1 && frame == 450 ? 1 : 0 }
        let report = try WAVAudio.inspect(source).report
        #expect(try WAVAudio.recognitionRegions(report, channel: 0) == nil)
        #expect(try WAVAudio.recognitionRegions(report, channel: 1) == [280..<620])
        var broken = report
        var windows = broken["channel_windows"]["windows"].array!
        windows[1]["start_frame"] = 301; broken["channel_windows"]["windows"] = .array(windows)
        #expect(throws: CoreFailure.self) { try WAVAudio.recognitionRegions(broken, channel: 1) }
    }

    @Test func nativeJobKeepsEveryArtifactAndMatchesPythonSemanticsAndExports() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), output = root.appendingPathComponent("job"), engine = AudioFixture.Engine()
        try AudioFixture.wav(source, channels: 2)
        let before = try WAVAudio.hash(source)
        let result = try AudioJob(engine: engine, preparer: AudioFixture.Preparer()).run(source: source, output: output,
            options: .init(sourceLanguage: "de-CH", mode: .normalize, profile: "fast", diarize: true))
        #expect(result.value["segments"].array?.count == 1)
        #expect(engine.requests.withLock { $0 }.count == 1)
        #expect(result.value["language_processing"]["status"] == "pending")
        #expect(try WAVAudio.hash(source) == before)
        for name in ["manifest.json", "audio-report.json", "transcript.raw.json", "transcript.json", "transcript.verbatim.txt", "transcript.cleaned.md", "transcript.srt", "transcript.vtt", "review.md"] {
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path))
        }
        let manifest = try AudioFixture.read(output, "manifest.json")
        #expect(manifest["state"] == "completed_with_review" && manifest["progress"].double == 1)
        #expect(manifest["working_audio_retained"] == false)
        #expect(manifest["working_audio"].array?.first?["sha256"].string?.count == 64)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("working-channel-0.wav").path))
        #expect(try Data(contentsOf: output.appendingPathComponent("asr-channel-0.json")) == Data("{\"raw\":true}\n".utf8))
        #expect(throws: (any Error).self) { try AudioJob(engine: engine, preparer: AudioFixture.Preparer()).run(source: source, output: output, options: .init()) }
        try reference(root, source: source, job: output)
    }

    @Test func distinctAndSilentChannelsAreNeverDeducedFromRecognizedText() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), engine = AudioFixture.Engine()
        try AudioFixture.wav(source, channels: 3) { _, channel in channel == 2 ? 0 : Int64(1000 + channel) }
        let result = try AudioJob(engine: engine, preparer: AudioFixture.Preparer()).run(source: source, output: root.appendingPathComponent("job"), options: .init())
        #expect(result.value["segments"].array?.map { $0["channel"] } == [0, 1])
        #expect(engine.requests.withLock { $0 }.count == 2)
        try reference(root, source: source, job: root.appendingPathComponent("job"))
    }

    @Test func recognitionRegionJobsRetainRawIndexesAndMapSourceTimeWithoutConcatenation() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("stereo.wav"), engine = AudioFixture.Engine()
        try AudioFixture.wav(source, channels: 2, frames: 90 * 16_000) { frame, channel in
            channel == 1 && frame == 45 * 16_000 ? 1001 : 1000
        }
        let output = root.appendingPathComponent("job")
        let result = try AudioJob(engine: engine, preparer: AudioFixture.Preparer()).run(source: source, output: output, options: .init())
        #expect(engine.requests.withLock { $0 } == ["asr-channel-0", "asr-channel-1-region-0"])
        #expect(result.value["segments"].array?.map { $0["start_ms"] } == [0,28000])
        let index = try AudioFixture.read(output, "asr-channel-1.regions.json")
        #expect(index["regions"].array?[0]["source_frames"] == [448000,992000])
        #expect(index["regions"].array?[0]["offset_ms"] == 28000)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("asr-channel-1-region-0.wav").path))
        #expect(index["regions"].array?[0]["working_sha256"].string?.count == 64)
        try reference(root, source: source, job: output)
    }

    @Test func verifiedPassesCompareDistinctModelHashesAndRetainDisagreement() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"); try AudioFixture.wav(source)
        let primary = AudioFixture.Engine(), second = AudioFixture.Engine(model: "b", text: "different")
        let result = try AudioJob(engine: primary, verifier: second, preparer: AudioFixture.Preparer()).run(source: source, output: root.appendingPathComponent("job"), options: .init(profile: "verified"))
        #expect(result.value["processing"]["engine_passes"].array?.count == 2)
        #expect(result.value["segments"].array?[0]["review_reasons"].array?.contains("engine_pass_disagreement") == true)
        try reference(root, source: source, job: root.appendingPathComponent("job"))
        #expect(throws: CoreFailure.self) { try AudioJob(engine: primary, verifier: primary, preparer: AudioFixture.Preparer()).run(source: source, output: root.appendingPathComponent("same-model"), options: .init(profile: "verified")) }
    }

    @Test func multipartTimestampsMissingPartsAndCanonicalBoundariesRemainContinuous() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        try AudioFixture.wav(root.appendingPathComponent("one.wav")); try AudioFixture.wav(root.appendingPathComponent("three.wav"))
        let source = try AudioFixture.session(root, parts: [("one.wav", 16000), ("missing.wav", 16000), ("three.wav", 16000)], missing: 1)
        let before = try WAVAudio.hash(source)
        let result = try AudioJob(engine: AudioFixture.Engine(), preparer: AudioFixture.Preparer()).run(source: source, output: root.appendingPathComponent("job"), options: .init())
        #expect(result.value["source"]["duration_ms"] == 3000)
        #expect(result.value["segments"].array?.map { $0["start_ms"] } == [0, 2000])
        #expect(result.value["review_reasons"].array?.contains { $0.string?.hasPrefix("part_2_unavailable:") == true } == true)
        #expect(result.value["segments"].array?.allSatisfy { $0["review_reasons"].array?.contains("part_boundary; check_cut_or_duplicate_speech") == true } == true)
        #expect(try WAVAudio.hash(source) == before)
        try reference(root, source: source, job: root.appendingPathComponent("job"), compareJob: false)
    }

    @Test(arguments: [1,2,3])
    func sessionVersionsAndSourceIdentityMatchReference(version: Int) throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        try AudioFixture.wav(root.appendingPathComponent("one.wav")); try AudioFixture.wav(root.appendingPathComponent("two.wav"))
        let source = try AudioFixture.session(root, parts: [("one.wav",16000),("two.wav",16000)])
        var session = try AudioFixture.read(root, source.lastPathComponent)
        session["schemaVersion"] = .integer(Int64(version))
        if version >= 2 { session["sourceIdentity"] = ["role": "input", "deviceUID": "synthetic-input"] }
        if version == 3 { session["sourceTracks"] = [["role": "input", "manifestPath": "source.recscribe.json"]] }
        try session.encoded().write(to: source)
        let output = root.appendingPathComponent("job")
        let result = try AudioJob(engine: AudioFixture.Engine(), preparer: AudioFixture.Preparer()).run(source: source, output: output, options: .init())
        #expect(result.value["segments"].array?.map { $0["start_ms"] } == [0,1000])
        #expect(result.value["source"]["capture_source"] == session["sourceIdentity"])
        try reference(root, source: source, job: output)
    }

    @Test func cancellationAndSourceMutationRetainFailureEvidenceWithoutPublishingSuccess() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"); try AudioFixture.wav(source)
        let cancelled = root.appendingPathComponent("cancelled")
        let engine = AudioFixture.Engine { prefix in try Data().write(to: prefix.deletingLastPathComponent().appendingPathComponent("cancel.request")) }
        #expect(throws: CancellationError.self) { try AudioJob(engine: engine, preparer: AudioFixture.Preparer()).run(source: source, output: cancelled, options: .init()) }
        #expect(try AudioFixture.read(cancelled, "manifest.json")["state"] == "cancelled")
        #expect(!FileManager.default.fileExists(atPath: cancelled.appendingPathComponent("working-channel-0.wav").path))
        #expect(FileManager.default.fileExists(atPath: cancelled.appendingPathComponent("asr-channel-0.json").path))
        let mutate = AudioFixture.Engine { _ in
            let file = try FileHandle(forWritingTo: source); defer { try? file.close() }
            try file.seek(toOffset: 44); try file.write(contentsOf: Data([0,0]))
        }
        let output = root.appendingPathComponent("mutated")
        #expect(throws: CoreFailure.self) { try AudioJob(engine: mutate, preparer: AudioFixture.Preparer()).run(source: source, output: output, options: .init()) }
        #expect(try AudioFixture.read(output, "manifest.json")["state"] == "failed")
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("working-channel-0.wav").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("transcript.json").path))
    }

    @Test func truncatedPCMAndUnsafeSessionPathsFailExplicitly() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"); try AudioFixture.wav(source)
        let session = try AudioFixture.session(root, parts: [("source.wav",16000)])
        var value = try AudioFixture.read(root, session.lastPathComponent)
        var parts = value["parts"].array!; parts[0]["path"] = "../outside.wav"; value["parts"] = .array(parts)
        try value.encoded().write(to: session)
        #expect(throws: CoreFailure.self) { try AudioSource.inspect(session, check: {}) }
        let file = try FileHandle(forWritingTo: source); try file.truncate(atOffset: 100); try file.close()
        #expect(throws: CoreFailure.self) { try WAVAudio.inspect(source) }
    }

    private func reference(_ root: URL, source: URL, job: URL?, compareJob: Bool = true) throws {
        guard let python = ProcessInfo.processInfo.environment["RECSCRIBE_REFERENCE_PYTHON"] else { return }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if !source.path.hasSuffix(".json") { try WAVAudio.inspect(source).report.encoded().write(to: root.appendingPathComponent("native-report.json")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONPATH": repo.appendingPathComponent("pipeline/src").path]) { _, new in new }
        process.arguments = ["-c", """
        import json, math, sys, shutil
        from pathlib import Path
        from recscribe.audio import inspect_wav
        from recscribe.process import Cancellation
        from recscribe.job import Job, validate
        from recscribe.engines import EngineResult
        from recscribe.renderers import render
        root, source, job = map(Path, sys.argv[1:4])
        if not source.name.endswith('.json'):
            native=json.loads((root/'native-report.json').read_text())
            reference=inspect_wav(source,Cancellation(root/'cancel.request'))
            for key in reference:
                if key != 'channel_metrics': assert native[key]==reference[key], key
            for a,b in zip(native['channel_metrics'],reference['channel_metrics']):
                for key in b:
                    assert math.isclose(a[key],b[key],rel_tol=1e-12,abs_tol=1e-12), key
        if str(job) != '.':
            doc=json.loads((job/'transcript.json').read_text()); validate(doc)
            for name, content in render(doc).items(): assert (job/name).read_bytes()==content.encode(), name
            if sys.argv[4]=='true':
                class Engine:
                    def __init__(self,model='a',text=' Gr \\u00fcezi <test>! '): self.model,self.text=model,text
                    def transcribe(self,audio,output,language,cancel):
                        raw=output.with_suffix('.json'); raw.write_bytes(b'{"raw":true}\\n')
                        return EngineResult([dict(start_ms=0,end_ms=800,source_text=self.text,confidence=None,speaker=None,words=[])],raw,
                            dict(engine='synthetic',version='1',model=self.model,model_sha256=self.model*64,command=[],duration_seconds=0,local_only=True))
                options={k:doc['processing'][k] for k in ('source_language','target_language','mode','profile','diarize','local_only','formats')}
                verifier=Engine('b','different') if options['profile']=='verified' else None
                ref=Job(root/'reference-job',source,options).run(Engine(),Path(shutil.which('ffmpeg')),verifier)
                # Compare filesystem identity for macOS /var aliases, including part reports.
                def align_paths(a,b):
                    if isinstance(a,dict) and isinstance(b,dict):
                        for k in a.keys() & b.keys():
                            if k=='path' and isinstance(a[k],str) and a[k].startswith('/'):
                                assert Path(a[k]).samefile(b[k]); b[k]=a[k]
                            else: align_paths(a[k],b[k])
                    elif isinstance(a,list) and isinstance(b,list):
                        for x,y in zip(a,b): align_paths(x,y)
                align_paths(doc['source'],ref['source'])
                for key in ('source','segments','review_reasons','language_processing','status'):
                    assert doc[key]==ref[key], (key,doc[key],ref[key])
                for name in render(ref): assert (job/name).read_bytes()==(root/'reference-job'/name).read_bytes(),name
        """, root.path, source.path, job?.path ?? ".", String(compareJob)]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
