import Foundation
import Synchronization
import Testing
@testable import RecScribeCore

@Suite struct AccuracyCalibrationMathTests {
    @Test func pooledAdjacentViolatorsAggregatesTiesAndClampsObservedEndpoints() throws {
        let map = try AccuracyCalibrationMath.fitIsotonic(scores: [0.8, 0.2, 0.2, 0.5, 0.9],
            targets: [0.4, 0.1, 0.3, 0.8, 1.0])
        #expect(map.upperBounds == [0.2, 0.8, 0.9])
        #expect(abs(map.values[0] - 0.2) < 1e-12)
        #expect(abs(map.values[1] - 0.6) < 1e-12)
        #expect(map.values[2] == 1)
        #expect(try map.predict(0) == map.values[0])
        #expect(try map.predict(0.2) == map.values[0])
        #expect(try map.predict(0.20001) == map.values[1])
        #expect(try map.predict(1) == map.values[2])
        #expect(try JSONDecoder().decode(AccuracyCalibrationMath.IsotonicMap.self,
            from: JSONEncoder().encode(map)) == map)
    }

    @Test func multipleViolatingBlocksPoolToTheirWeightedMean() throws {
        let map = try AccuracyCalibrationMath.fitIsotonic(scores: [0.1, 0.2, 0.3, 0.4], targets: [1, 0.8, 0.4, 0.2])
        #expect(map.upperBounds == [0.4])
        #expect(abs(map.values[0] - 0.6) < 1e-12)
        let tied = try AccuracyCalibrationMath.fitIsotonic(scores: [0.5, 0.5, 0.5], targets: [0, 0.5, 1])
        #expect(tied.upperBounds == [0.5] && tied.values == [0.5])
    }

    @Test func softTargetLogisticFitLearnsRankingAndIsDeterministic() throws {
        let features = [[-2.0, 3], [-1, 3], [0, 3], [1, 3], [2, 3]]
        let targets = [0.05, 0.2, 0.5, 0.8, 0.95]
        let model = try AccuracyCalibrationMath.fitLinear(features: features, targets: targets)
        #expect(model == (try AccuracyCalibrationMath.fitLinear(features: features, targets: targets)))
        #expect(abs(model.means[0]) < 1e-12 && model.means[1] == 3 && model.scales[1] == 1 && model.weights[1] == 0)
        let values = try features.map { try model.predict($0) }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(values.first! < 0.15 && values.last! > 0.85)
        #expect(abs(values[2] - 0.5) < 1e-10)
        #expect(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(try JSONDecoder().decode(AccuracyCalibrationMath.LinearModel.self,
            from: JSONEncoder().encode(model)) == model)
    }

    @Test func interceptLearnsConstantSoftTargetsWithoutInventingFeatureVariation() throws {
        let model = try AccuracyCalibrationMath.fitLinear(features: [[2], [2], [2]], targets: [0.75, 0.75, 0.75])
        #expect(model.weights == [0] && model.scales == [1])
        #expect(abs(try model.predict([2]) - 0.75) < 0.001)
        let positive = AccuracyCalibrationMath.LinearModel(means: [0], scales: [1], weights: [1], intercept: 0)
        #expect(try positive.predict([1_000]) == 1)
        #expect(try positive.predict([-1_000]) == 0)
    }

    @Test func decodedMalformedModelsAndMapsCannotProducePercentages() throws {
        let models = [
            "{\"means\":[],\"scales\":[],\"weights\":[],\"intercept\":0}",
            "{\"means\":[0],\"scales\":[0],\"weights\":[1],\"intercept\":0}",
            "{\"means\":[0],\"scales\":[1],\"weights\":[],\"intercept\":0}"
        ]
        for json in models {
            let model = try JSONDecoder().decode(AccuracyCalibrationMath.LinearModel.self, from: Data(json.utf8))
            #expect(throws: CoreFailure.self) { try model.predict([0.5]) }
        }
        let maps = [
            "{\"upperBounds\":[],\"values\":[]}",
            "{\"upperBounds\":[0.8,0.2],\"values\":[0.2,0.5]}",
            "{\"upperBounds\":[0.2,0.2],\"values\":[0.2,0.5]}",
            "{\"upperBounds\":[0.2,0.8],\"values\":[0.7,0.5]}",
            "{\"upperBounds\":[0.2],\"values\":[1.1]}"
        ]
        for json in maps {
            let map = try JSONDecoder().decode(AccuracyCalibrationMath.IsotonicMap.self, from: Data(json.utf8))
            #expect(throws: CoreFailure.self) { try map.predict(0.5) }
        }
    }

    @Test func invalidDimensionsNonfiniteNumbersAndExcessWorkFailClosed() throws {
        for (features, targets) in [([[Double]](), [Double]()), ([[1], [1, 2]], [0, 1]),
                                     ([[Double.nan]], [0.5]), ([[1]], [1.1]),
                                     ([[Double.greatestFiniteMagnitude], [-Double.greatestFiniteMagnitude]], [0, 1]),
                                     (Array(repeating: [1.0], count: 2_001), Array(repeating: 0.5, count: 2_001)),
                                     ([Array(repeating: 1.0, count: 17)], [0.5])] {
            #expect(throws: CoreFailure.self) { try AccuracyCalibrationMath.fitLinear(features: features, targets: targets) }
        }
        for (scores, targets) in [([Double](), [Double]()), ([0.1], [Double.nan]), ([Double.infinity], [0.5]),
                                  ([0.1, 0.2], [0.5]), ([-0.1], [0.5]),
                                  (Array(repeating: 0.5, count: 2_001), Array(repeating: 0.5, count: 2_001))] {
            #expect(throws: CoreFailure.self) { try AccuracyCalibrationMath.fitIsotonic(scores: scores, targets: targets) }
        }
        let model = AccuracyCalibrationMath.LinearModel(means: [0], scales: [1], weights: [1], intercept: 0)
        #expect(throws: CoreFailure.self) { try model.predict([]) }
        #expect(throws: CoreFailure.self) { try model.predict([Double.nan]) }
        let map = AccuracyCalibrationMath.IsotonicMap(upperBounds: [0.5], values: [0.5])
        #expect(throws: CoreFailure.self) { try map.predict(Double.nan) }
        #expect(throws: CoreFailure.self) { try map.predict(1.1) }
    }

    @Test func cancellationStopsBothFittersBeforeProducingAnArtifact() {
        #expect(throws: CancellationError.self) {
            try AccuracyCalibrationMath.fitLinear(features: [[0], [1]], targets: [0, 1], check: { throw CancellationError() })
        }
        #expect(throws: CancellationError.self) {
            try AccuracyCalibrationMath.fitIsotonic(scores: [0, 1], targets: [0, 1], check: { throw CancellationError() })
        }
    }

    @Test func cancellationCheckpointsRemainActiveAfterTrainingValidation() {
        let checks = Mutex(0)
        #expect(throws: CancellationError.self) {
            try AccuracyCalibrationMath.fitLinear(features: (0..<16).map { [Double($0)] },
                targets: Array(repeating: 0.5, count: 16), check: {
                    let count = checks.withLock { $0 += 1; return $0 }
                    if count >= 50 { throw CancellationError() }
                })
        }
        #expect(checks.withLock { $0 } == 50)
    }
}
