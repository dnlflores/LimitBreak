import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Log a walk by drawing its route directly on the map with your finger.
/// Pan mode moves the map; Draw mode turns drags into route points.
/// Opens zoomed in on the user's current location, with a button to re-center.
struct WalkDrawView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var locationManager = CLLocationManager()
    @State private var points: [CLLocationCoordinate2D] = []
    /// points.count checkpoint after each completed drag stroke, so Undo removes one stroke.
    @State private var strokeEnds: [Int] = []
    @State private var isDrawing = false
    @State private var date = Date()
    @State private var durationMinutes = ""

    /// New points closer than this to the previous one are dropped as jitter.
    private static let minPointSpacing: CLLocationDistance = 6

    private var distanceMeters: CLLocationDistance {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            let from = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let to = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return total + to.distance(from: from)
        }
    }

    private var distanceMiles: Double { distanceMeters / 1609.344 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapCanvas
                controlPanel
            }
            .obsidianBackground()
            .dismissibleKeyboard()
            .navigationTitle("Add a Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(points.count < 2)
                }
            }
            .onAppear {
                locationManager.requestWhenInUseAuthorization()
            }
        }
    }

    // MARK: - Map

    private var mapCanvas: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: isDrawing ? [] : .all) {
                UserAnnotation()

                if points.count >= 2 {
                    MapPolyline(coordinates: points)
                        .stroke(Theme.emerald, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                if let first = points.first {
                    Annotation("", coordinate: first) {
                        Circle()
                            .fill(Theme.emerald)
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 12, height: 12)
                    }
                }
                if points.count > 1, let last = points.last {
                    Annotation("", coordinate: last) {
                        Circle()
                            .fill(Theme.gold)
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .overlay {
                if isDrawing {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    addPoint(at: value.location, proxy: proxy)
                                }
                                .onEnded { _ in
                                    strokeEnds.append(points.count)
                                }
                        )
                }
            }
            .overlay(alignment: .top) {
                mapToolbar
            }
        }
    }

    private var mapToolbar: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 10) {
                Button {
                    isDrawing.toggle()
                    Haptics.shared.tick()
                } label: {
                    Label(isDrawing ? "Drawing" : "Panning", systemImage: isDrawing ? "pencil.tip" : "hand.draw.fill")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(isDrawing ? .black : .white)
                        .glassEffect(
                            isDrawing ? .regular.tint(Theme.emerald).interactive() : .regular.interactive(),
                            in: .capsule
                        )
                }
                .buttonStyle(.plain)

                Button {
                    recenterOnUser()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.caption.weight(.bold))
                        .padding(10)
                        .foregroundStyle(Theme.teal)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    undoStroke()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption.weight(.bold))
                        .padding(10)
                        .foregroundStyle(.white)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(points.isEmpty)

                Button {
                    points = []
                    strokeEnds = []
                    Haptics.shared.tick()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.bold))
                        .padding(10)
                        .foregroundStyle(Theme.coral)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(points.isEmpty)
            }
        }
        .padding(10)
    }

    /// Snaps the camera back to the user's current location.
    private func recenterOnUser() {
        Haptics.shared.tick()
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .userLocation(fallback: .automatic)
        }
    }

    private func addPoint(at location: CGPoint, proxy: MapProxy) {
        guard let coordinate = proxy.convert(location, from: .local) else { return }
        if let last = points.last {
            let from = CLLocation(latitude: last.latitude, longitude: last.longitude)
            let to = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard to.distance(from: from) >= Self.minPointSpacing else { return }
        }
        points.append(coordinate)
    }

    private func undoStroke() {
        _ = strokeEnds.popLast()
        points = Array(points.prefix(strokeEnds.last ?? 0))
        Haptics.shared.tick()
    }

    // MARK: - Controls

    private var controlPanel: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DISTANCE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                        .kerning(1)
                    Text(String(format: "%.2f mi", distanceMiles))
                        .statNumberStyle()
                        .foregroundStyle(Theme.emerald)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("POINTS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textDim)
                        .kerning(1)
                    Text("\(points.count)")
                        .statNumberStyle()
                }
            }

            DatePicker("When", selection: $date, in: ...Date())
                .font(.subheadline.weight(.semibold))
                .tint(Theme.emerald)

            HStack {
                Text("Duration")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                TextField("optional", text: $durationMinutes)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .padding(8)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                Text("min")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
            }

            if points.isEmpty {
                Text("Tip: switch to Drawing mode, then trace your route with a finger.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Save

    private func save() {
        let walk = Walk(
            date: date,
            durationSeconds: (Double(durationMinutes) ?? 0) * 60,
            distanceMeters: distanceMeters,
            routePoints: points.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        )
        modelContext.insert(walk)
        try? modelContext.save()
        HealthKitManager.shared.syncIfEnabled(walk: walk)
        Haptics.shared.success()
        dismiss()
    }
}
