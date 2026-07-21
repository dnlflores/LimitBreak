import SwiftUI

/// Full-screen celebration when a ceiling shatters: flash, particle burst,
/// and the LIMITBREAK banner. Tap anywhere (or wait) to dismiss.
struct LimitBreakOverlay: View {
    let event: LimitBreakEvent
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var flashOpacity = 1.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()

            ParticleShatterView()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 18) {
                Text("LIMITBREAK TRIGGERED")
                    .font(.system(.title, design: .rounded, weight: .black))
                    .kerning(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.limitBreakGradient)
                    .shadow(color: Theme.gold.opacity(0.8), radius: 18)
                    .scaleEffect(appeared ? 1.0 : 0.3)

                VStack(spacing: 8) {
                    Text(event.exerciseName)
                        .font(.title3.weight(.bold))

                    Text("\(event.recordType): \(event.newValue.cleanWeight) \(event.unit)")
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Theme.gold)

                    if let delta = event.deltaPercent {
                        Text(String(format: "+%.1f%% over previous ceiling", delta))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.emerald)
                    } else {
                        Text("First record etched into the ledger")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.emerald)
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
            }
            .padding(32)
            .glassEffect(.clear, in: .rect(cornerRadius: 28))
            .padding(.horizontal, 20)
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { flashOpacity = 0 }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.1)) {
                appeared = true
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3.5))
            onDismiss()
        }
    }
}

// MARK: - Particle shatter

/// Canvas-driven shard burst radiating from center screen.
private struct ParticleShatterView: View {
    private struct Shard {
        let angle: Double
        let speed: Double
        let size: Double
        let spin: Double
        let isGold: Bool
    }

    private static func makeShards() -> [Shard] {
        var result: [Shard] = []
        for index in 0..<64 {
            let baseAngle: Double = Double(index) / 64.0 * 2.0 * Double.pi
            let jitter: Double = Double(index % 5) * 0.13
            let shard = Shard(
                angle: baseAngle + jitter,
                speed: 120.0 + Double((index * 37) % 220),
                size: 3.0 + Double((index * 13) % 8),
                spin: Double((index * 29) % 360),
                isGold: index % 3 != 0
            )
            result.append(shard)
        }
        return result
    }

    private let shards: [Shard] = ParticleShatterView.makeShards()

    @State private var startTime: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                guard let startTime else { return }
                let elapsed = timeline.date.timeIntervalSince(startTime)
                guard elapsed < 2.2 else { return }

                let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
                let progress = min(elapsed / 1.6, 1.0)
                let eased = 1 - pow(1 - progress, 3)
                let fade = max(0, 1 - elapsed / 2.0)

                for shard in shards {
                    let distance = shard.speed * eased * 2.2
                    let gravityDrop = 60 * progress * progress
                    let position = CGPoint(
                        x: center.x + cos(shard.angle) * distance,
                        y: center.y + sin(shard.angle) * distance + gravityDrop
                    )

                    var shardContext = context
                    shardContext.translateBy(x: position.x, y: position.y)
                    shardContext.rotate(by: .degrees(shard.spin + progress * 340))
                    shardContext.opacity = fade

                    let rect = CGRect(x: -shard.size / 2, y: -shard.size / 2, width: shard.size, height: shard.size * 1.6)
                    shardContext.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(shard.isGold ? Theme.gold : Theme.violet)
                    )
                }
            }
        }
        .onAppear { startTime = Date() }
    }
}
