import SwiftUI

enum StudioMotionToken: String, CaseIterable, Hashable, Sendable {
    case press, hover, quick, swap, reveal, expand, materialize, playhead
    var animation: Animation {
        if self == .expand { return .spring(response: 0.35, dampingFraction: 0.8) }
        if self == .materialize { return .spring(response: 0.4, dampingFraction: 0.75) }
        if self == .playhead { return .linear(duration: 1 / 30) }
        let seconds: [Self: Double] = [.press: 0.1, .hover: 0.12, .quick: 0.15, .swap: 0.18, .reveal: 0.2]
        return .easeOut(duration: seconds[self]!)
    }
    var reducedAnimation: Animation? {
        if self == .press || self == .hover { return nil }
        return self == .playhead ? .linear(duration: 1 / 30) : .easeOut(duration: 0.15)
    }
    func resolved(reduceMotion: Bool) -> Animation? { reduceMotion ? reducedAnimation : animation }
}

enum StudioTransportTiming {
    static let minimumArming: TimeInterval = 0.25
    static let minimumStopping: TimeInterval = 0.45
    static let savedDwell: TimeInterval = 1.4
}

private struct StudioMotion<Value: Equatable>: ViewModifier {
    let token: StudioMotionToken
    let value: Value
    @Environment(\.accessibilityReduceMotion) var reduced
    func body(content: Content) -> some View { content.animation(token.resolved(reduceMotion: reduced), value: value) }
}

extension View {
    func studioAnimation<Value: Equatable>(_ token: StudioMotionToken, value: Value) -> some View {
        modifier(StudioMotion(token: token, value: value))
    }
    func studioHover(_ value: Binding<Bool>, showsPointingHand: Bool = true) -> some View {
        onHover { value.wrappedValue = $0 }.onDisappear { value.wrappedValue = false }
    }
}
