import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Full-screen view of one logged walk: the traced route front and center,
/// with distance, time, pace, and the XP it paid out.
struct WalkDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let walk: Walk

    @State private var showEdit = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                xpPill

                if walk.routePoints.count >= 2 {
                    routeMap
                } else {
                    Text("No route was traced for this walk.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .cardStyle()
                }

                statTiles
            }
            .padding()
        }
        .obsidianBackground()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showEdit) {
            EditWalkSheet(walk: walk)
        }
        .confirmationDialog("Delete Walk?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Walk", role: .destructive) {
                modelContext.delete(walk)
                try? modelContext.save()
                WidgetSnapshotter.shared.refresh()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This \(String(format: "%.2f mi", walk.distanceMiles)) walk will be permanently removed.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Image(systemName: "figure.walk")
                    .font(.title3)
                    .foregroundStyle(Theme.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Walk")
                        .font(.title2.bold())
                    Text(walk.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }

            Spacer()

            Menu {
                Button {
                    showEdit = true
                } label: {
                    Label("Edit Walk", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Walk", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .glassCircle()
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    private var xpPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.circle.fill")
                .font(.caption)
            Text("+\(XPEngine.walkXP) XP earned")
                .font(.caption.weight(.black))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.gold)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.gold.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.limitBreakGradient, lineWidth: 1).opacity(0.4))
    }

    // MARK: - Route

    private var routeMap: some View {
        let coordinates = walk.routePoints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        return Map {
            MapPolyline(coordinates: coordinates)
                .stroke(Theme.teal, lineWidth: 4)
            if let start = coordinates.first {
                Annotation("Start", coordinate: start) {
                    Circle()
                        .fill(Theme.emerald)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                }
            }
            if let end = coordinates.last, coordinates.count > 1 {
                Annotation("End", coordinate: end) {
                    Circle()
                        .fill(Theme.coral)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                }
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.glassBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    // MARK: - Stats

    private var statTiles: some View {
        HStack(spacing: 12) {
            statTile(value: String(format: "%.2f", walk.distanceMiles), label: "miles", color: Theme.teal)
            statTile(
                value: walk.durationSeconds > 0 ? walk.durationSeconds.clockString : "\u{2014}",
                label: "duration",
                color: Theme.coral
            )
            statTile(value: paceText, label: "min / mi", color: Theme.violet)
        }
    }

    private var paceText: String {
        guard walk.durationSeconds > 0, walk.distanceMiles > 0 else { return "\u{2014}" }
        let paceMinutes = walk.durationSeconds / 60 / walk.distanceMiles
        return String(format: "%.1f", paceMinutes)
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .statNumberStyle()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }
}

// MARK: - Edit walk sheet

/// A compact editor for a logged walk: correct the date and time it was
/// recorded, saving straight back to the store.
struct EditWalkSheet: View {
    let walk: Walk

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var date: Date
    @State private var hours: Int
    @State private var minutes: Int
    @State private var seconds: Int

    init(walk: Walk) {
        self.walk = walk
        _date = State(initialValue: walk.date)
        let total = Int(walk.durationSeconds.rounded())
        _hours = State(initialValue: total / 3600)
        _minutes = State(initialValue: (total % 3600) / 60)
        _seconds = State(initialValue: total % 60)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        DatePicker(
                            "When",
                            selection: $date,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .font(.subheadline.weight(.semibold))
                        .tint(Theme.teal)
                    }
                    .cardStyle()

                    durationCard
                }
                .padding()
            }
            .obsidianBackground()
            .navigationTitle("Edit Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Duration

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duration")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 0) {
                durationWheel(value: $hours, range: 0..<24, label: "hr")
                durationWheel(value: $minutes, range: 0..<60, label: "min")
                durationWheel(value: $seconds, range: 0..<60, label: "sec")
            }
            .frame(height: 140)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func durationWheel(value: Binding<Int>, range: Range<Int>, label: String) -> some View {
        HStack(spacing: 4) {
            Picker(label, selection: value) {
                ForEach(range, id: \.self) { number in
                    Text("\(number)")
                        .monospacedDigit()
                        .tag(number)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()

            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
    }

    private func save() {
        walk.date = date
        walk.durationSeconds = Double(hours * 3600 + minutes * 60 + seconds)
        try? modelContext.save()
        WidgetSnapshotter.shared.refresh()
        dismiss()
    }
}
