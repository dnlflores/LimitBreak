import CoreHaptics
import UIKit

/// Central haptic dispatcher. Lightweight ticks use UIImpactFeedbackGenerator;
/// the LimitBreak celebration plays a custom CoreHaptics charge-up + shatter pattern.
@MainActor
final class Haptics {
    static let shared = Haptics()

    private var engine: CHHapticEngine?
    private let tickGenerator = UIImpactFeedbackGenerator(style: .light)
    private let logGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {
        prepareEngine()
    }

    private func prepareEngine() {
        guard supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.prepareEngine() }
            }
            engine.stoppedHandler = { _ in }
            try engine.start()
            self.engine = engine
        } catch {
            engine = nil
        }
    }

    /// One tick per weight/rep increment on dials and steppers.
    func tick() {
        tickGenerator.impactOccurred(intensity: 0.6)
    }

    /// Solid thunk when a set is committed.
    func logSet() {
        logGenerator.impactOccurred()
    }

    func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Multi-stage burst: mechanical charge-up ramp followed by a tactile shatter rumble.
    func limitBreakBurst() {
        guard supportsHaptics, let engine else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        var events: [CHHapticEvent] = []

        // Stage 1: charge-up — continuous rumble swelling in intensity and sharpness.
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                .init(parameterID: .hapticIntensity, value: 0.35),
                .init(parameterID: .hapticSharpness, value: 0.2),
            ],
            relativeTime: 0,
            duration: 0.65
        ))

        // Stage 2: the shatter — a hard transient spike.
        events.append(CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                .init(parameterID: .hapticIntensity, value: 1.0),
                .init(parameterID: .hapticSharpness, value: 1.0),
            ],
            relativeTime: 0.68
        ))

        // Stage 3: decaying debris rumble.
        for (offset, intensity) in [(0.78, Float(0.7)), (0.88, 0.45), (1.0, 0.25)] {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    .init(parameterID: .hapticIntensity, value: intensity),
                    .init(parameterID: .hapticSharpness, value: 0.4),
                ],
                relativeTime: offset
            ))
        }

        let curve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.3),
                .init(relativeTime: 0.65, value: 1.0),
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: [curve])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
