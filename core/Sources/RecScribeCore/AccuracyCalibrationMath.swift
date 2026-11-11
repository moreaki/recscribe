import Foundation

/// Deterministic bounded fitting primitives. Fitting is not evidence that a
/// calibrator is qualified for display; admission and held-out checks are separate.
public enum AccuracyCalibrationMath {
    public static let maximumRows = 2_000
    public static let maximumFeatures = 16
    public static let linearIterations = 400
    public static let coefficientPenalty = 0.01

    public struct LinearModel: Codable, Equatable, Sendable {
        public let means: [Double]
        public let scales: [Double]
        public let weights: [Double]
        public let intercept: Double

        public init(means: [Double], scales: [Double], weights: [Double], intercept: Double) {
            self.means = means; self.scales = scales; self.weights = weights; self.intercept = intercept
        }

        public func validate() throws {
            guard (1...AccuracyCalibrationMath.maximumFeatures).contains(means.count),
                  means.count == scales.count, means.count == weights.count,
                  means.allSatisfy(\.isFinite), scales.allSatisfy({ $0.isFinite && $0 > 0 }),
                  weights.allSatisfy(\.isFinite), intercept.isFinite else {
                throw CoreFailure("Invalid accuracy predictor dimensions or parameters")
            }
        }

        public func predict(_ features: [Double]) throws -> Double {
            try validate()
            guard features.count == means.count, features.allSatisfy(\.isFinite) else {
                throw CoreFailure("Accuracy features are missing, nonfinite or incompatible")
            }
            var logit = intercept
            for index in features.indices {
                logit += weights[index] * ((features[index] - means[index]) / scales[index])
                guard logit.isFinite else { throw CoreFailure("Accuracy predictor exceeded its numeric bounds") }
            }
            return AccuracyCalibrationMath.sigmoid(logit)
        }
    }

    /// A monotone step map: each value applies through its inclusive upper bound.
    /// Scores below/above the observed range use the first/last fitted value.
    public struct IsotonicMap: Codable, Equatable, Sendable {
        public let upperBounds: [Double]
        public let values: [Double]

        public init(upperBounds: [Double], values: [Double]) {
            self.upperBounds = upperBounds; self.values = values
        }

        public func validate() throws {
            guard (1...AccuracyCalibrationMath.maximumRows).contains(upperBounds.count),
                  upperBounds.count == values.count,
                  upperBounds.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw CoreFailure("Invalid accuracy calibration map")
            }
            for index in upperBounds.indices.dropFirst() {
                guard upperBounds[index] > upperBounds[index - 1], values[index] >= values[index - 1] else {
                    throw CoreFailure("Accuracy calibration map is not monotone")
                }
            }
        }

        public func predict(_ score: Double) throws -> Double {
            try validate()
            guard score.isFinite, (0...1).contains(score) else {
                throw CoreFailure("Accuracy predictor score must be finite and between zero and one")
            }
            return values[upperBounds.firstIndex(where: { score <= $0 }) ?? (values.count - 1)]
        }
    }

    /// Logistic cross entropy against soft targets, population standardization,
    /// L2 coefficients and an unpenalized intercept. Constant features use scale 1.
    public static func fitLinear(features: [[Double]], targets: [Double],
                                 check: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> LinearModel {
        try check()
        guard (1...maximumRows).contains(features.count), features.count == targets.count,
              let count = features.first?.count, (1...maximumFeatures).contains(count),
              targets.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw CoreFailure("Accuracy fitting requires bounded nonempty rows and valid targets")
        }
        let rows = Double(features.count)
        var means = [Double](repeating: 0, count: count)
        for row in features {
            try check()
            guard row.count == count, row.allSatisfy(\.isFinite) else {
                throw CoreFailure("Accuracy training features have inconsistent dimensions or nonfinite values")
            }
            for index in row.indices { means[index] += row[index] / rows }
        }
        guard means.allSatisfy(\.isFinite) else { throw CoreFailure("Accuracy feature means exceed numeric bounds") }
        var variance = [Double](repeating: 0, count: count)
        for row in features {
            try check()
            for index in row.indices {
                let deviation = row[index] - means[index]
                variance[index] += deviation * deviation / rows
            }
        }
        guard variance.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw CoreFailure("Accuracy feature variance exceeds numeric bounds")
        }
        let scales = variance.map { $0 > 0 ? sqrt($0) : 1 }
        let standardized = features.map { row in row.indices.map { (row[$0] - means[$0]) / scales[$0] } }
        guard standardized.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw CoreFailure("Accuracy feature standardization exceeds numeric bounds")
        }
        var weights = [Double](repeating: 0, count: count), intercept = 0.0
        // With standardized columns, this conservative fixed step is bounded by
        // the trace bound on the logistic Hessian; no stochastic order or seed.
        let rate = 0.5 / Double(count + 1)
        for _ in 0..<linearIterations {
            try check()
            var gradient = [Double](repeating: 0, count: count), interceptGradient = 0.0
            for rowIndex in standardized.indices {
                if rowIndex % 64 == 0 { try check() }
                let row = standardized[rowIndex]
                var logit = intercept
                for index in row.indices { logit += weights[index] * row[index] }
                let residual = (sigmoid(logit) - targets[rowIndex]) / rows
                interceptGradient += residual
                for index in row.indices { gradient[index] += residual * row[index] }
            }
            intercept -= rate * interceptGradient
            for index in weights.indices {
                weights[index] -= rate * (gradient[index] + coefficientPenalty * weights[index])
            }
        }
        let result = LinearModel(means: means, scales: scales, weights: weights, intercept: intercept)
        try result.validate()
        try check()
        return result
    }

    /// Least-squares pooled-adjacent-violators fitting. Tied input scores are
    /// aggregated before pooling so one score can never have multiple predictions.
    public static func fitIsotonic(scores: [Double], targets: [Double],
                                   check: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> IsotonicMap {
        try check()
        guard (1...maximumRows).contains(scores.count), scores.count == targets.count,
              scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              targets.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw CoreFailure("Accuracy calibration requires bounded scores and targets between zero and one")
        }
        struct Block {
            var upper: Double
            var sum: Double
            var count: Int
            var mean: Double { sum / Double(count) }
        }
        let ordered = scores.indices.sorted {
            scores[$0] == scores[$1] ? $0 < $1 : scores[$0] < scores[$1]
        }
        var tied: [Block] = []
        for index in ordered {
            try check()
            if tied.last?.upper == scores[index] {
                tied[tied.count - 1].sum += targets[index]
                tied[tied.count - 1].count += 1
            } else { tied.append(Block(upper: scores[index], sum: targets[index], count: 1)) }
        }
        var blocks: [Block] = []
        for block in tied {
            try check()
            blocks.append(block)
            while blocks.count > 1, blocks[blocks.count - 2].mean > blocks[blocks.count - 1].mean {
                try check()
                let right = blocks.removeLast(), left = blocks.removeLast()
                blocks.append(Block(upper: right.upper, sum: left.sum + right.sum, count: left.count + right.count))
            }
        }
        let result = IsotonicMap(upperBounds: blocks.map(\.upper), values: blocks.map(\.mean))
        try result.validate()
        try check()
        return result
    }

    private static func sigmoid(_ value: Double) -> Double {
        if value >= 0 { return 1 / (1 + exp(-value)) }
        let numerator = exp(value)
        return numerator / (1 + numerator)
    }
}
