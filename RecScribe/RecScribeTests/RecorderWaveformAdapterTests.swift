import Testing
@testable import RecScribe

struct RecorderWaveformAdapterTests {
    @Test(arguments: [1, 7, 82, 123, 200, 257])
    func envelopesHaveRequestedLengthAndRetainSilence(count: Int) {
        #expect(RecorderWaveformAdapter.magnitudes([], bucketedTo: count) == [Float](repeating: 0, count: count))
        #expect(RecorderWaveformAdapter.magnitudes([Float](repeating: 0, count: 200), bucketedTo: count).allSatisfy { $0 == 0 })
        #expect(RecorderWaveformAdapter.magnitudes([0.5, 0.25], bucketedTo: count).count == count)
    }
    @Test func amplitudeCurveIsSignedInvariantMonotonicAndBounded() {
        let amplitudes: [Float] = [0.0001, 0.01, 0.02, 0.1, 0.5, 1, 4]
        let positive = RecorderWaveformAdapter.magnitudes(amplitudes, bucketedTo: amplitudes.count)
        let negative = RecorderWaveformAdapter.magnitudes(amplitudes.map { -$0 }, bucketedTo: amplitudes.count)
        #expect(positive == negative)
        #expect(positive[0] == 0 && positive.last == 1)
        #expect(positive[2] > 0.3 && positive[2] < 0.9)
        #expect(zip(positive, positive.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(positive.allSatisfy { (0...1).contains($0) })
    }
    @Test func isolatedTransientsSurvivePeakBucketingAndShortInputsExpand() {
        let result = RecorderWaveformAdapter.magnitudes([0.1, -0.9, 0.1, 0.1, 0.2, 0.2, -0.7, 0.2], bucketedTo: 2)
        #expect(result == [0.9, 0.7].map { RecorderWaveformAdapter.magnitudes([$0], bucketedTo: 1)[0] })
        #expect(RecorderWaveformAdapter.magnitudes([0.5, 0.25], bucketedTo: 8).allSatisfy { $0 > 0 })
        #expect(RecorderWaveformAdapter.magnitudes([1], bucketedTo: 0).isEmpty)
        #expect(RecorderWaveformAdapter.mainWindowBarCount == 123)
        #expect(RecorderWaveformAdapter.popoverBarCount == 82)
        #expect(RecorderWaveformAdapter.barCount(forWidth: 370) == 123)
    }
}
