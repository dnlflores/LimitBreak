import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Log a walk two ways: **Track** records your route live from GPS as you
/// walk, or **Draw** lets you trace it on the map with a finger after the fact.
/// Opens zoomed in on the user's current location, with a button to re-center.
struct WalkDrawView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Which way the user is logging this walk.
    private enum Mode: String, CaseIterable {
        case track = "Track"
        case draw = "Draw"
    }

    @State private var mode: Mode = .track
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var locationManager = CLLocationManager()
    @State private var tracker = WalkTracker()

    // Draw-mode state
    @State private var points: [CLLocationCoordinate2D] = []
    /// points.count checkpoint after each completed drag stroke, so Undo removes one stroke.
    @State private var strokeEnds: [Int] = []
    @State private var isDrawing = false
    @State private var date = Date()
    @State private var durationMinutes = ""
    /// Measured height of the floating toolbar, used to inset the drawing
    /// surface so it never sits under the toolbar's buttons.
    @State private var toolbarHeight: CGFloat = 0

    /// New points closer than this to the previous one are dropped as jitter.
    private static let minPointSpacing: CLLocationDistance = 6

    /// Named coordinate space for the map so drag points stay accurate even
    /// though the drawing surface is inset from the top to clear the toolbar.
    private static let mapSpace = "walkDrawCanvas"

    /// The route being shown/edited, whichever mode is active.
    private var routeCoordinates: [CLLocationCoordinate2D] {
        mode == .track ? tracker.coordinates : points
    }

    private var distanceMeters: CLLocationDistance {
        if mode == .track { return tracker.distanceMeters }
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            let from = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let to = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            return total + to.distance(from: from)
        }
    }

    private var distanceMiles: Double { distanceMeters / 1609.344 }

    /// You can't switch modes mid-recording without losing the live track.
    private var canSwitchMode: Bool { tracker.phase == .idle }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapCanvas
                controlPanel
            }
            .obsidianBackground()
            .navigationTitle("Add a Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(routeCoordinates.count < 2)
                }
            }
            .onAppear {
                locationManager.requestWhenInUseAuthorization()
                tracker.requestAuthorization()
            }
            .onDisappear {
                tracker.end()
            }
        }
    }

    // MARK: - Map

    private var mapCanvas: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $camera, interactionModes: (mode == .draw && isDrawing) ? [] : .all) {
                    UserAnnotation()

                    if routeCoordinates.count >= 2 {
                        MapPolyline(coordinates: routeCoordinates)
                            .stroke(Theme.emerald, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    if let first = routeCoordinates.first {
                        Annotation("", coordinate: first) {
                            Circle()
                                .fill(Theme.emerald)
                                .stroke(.white, lineWidth: 2)
                                .frame(width: 12, height: 12)
                        }
                    }
                    if routeCoordinates.count > 1, let last = routeCoordinates.last {
                        Annotation("", coordinate: last) {
                            Circle()
                                .fill(Theme.gold)
                                .stroke(.white, lineWidth: 2)
                                .frame(width: 12, height: 12)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .coordinateSpace(.named(Self.mapSpace))
                .overlay(alignment: .top) {
                    // The drawing surface only covers the map below the toolbar
                    // so finger drags never sit under the Undo/Clear buttons and
                    // steal their taps. Reading the drag in the map's named space
                    // keeps points accurate despite the inset.
                    if mode == .draw && isDrawing {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.mapSpace))
                                    .onChanged { value in
                                        addPoint(at: value.location, proxy: proxy)
                                    }
                                    .onEnded { _ in
                                        strokeEnds.append(points.count)
                                    }
                            )
                            .padding(.top, toolbarHeight)
                    }
                }
            }

            // Toolbar is a sibling layered above the map rather than a Map
            // overlay, so its buttons win the hit-test against MapKit's own
            // gesture recognizers and the drawing surface.
            mapToolbar
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { toolbarHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, height in
                                toolbarHeight = height
                            }
                    }
                )
        }
    }

    private var mapToolbar: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 10) {
                if mode == .draw {
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
                }

                Button {
                    recenterOnUser()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.caption.weight(.bold))
                        .padding(10)
                        .foregroundStyle(Theme.teal)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)

                Spacer()

                if mode == .draw {
                    Button {
                        undoStroke()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption.weight(.bold))
                            .padding(10)
                            .foregroundStyle(.white)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .contentShape(.circle)
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
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(points.isEmpty)
                }
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
        guard let coordinate = proxy.convert(location, from: .named(Self.mapSpace)) else { return }
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
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!canSwitchMode)

            if mode == .track {
                trackControls
            } else {
                drawControls
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: Track controls

    private var trackControls: some View {
        VStack(spacing: 14) {
            HStack {
                statColumn(
                    title: "DISTANCE",
                    value: String(format: "%.2f mi", distanceMiles),
                    color: Theme.emerald,
                    alignment: .leading
                )
                Spacer()
                statColumn(
                    title: "TIME",
                    value: tracker.elapsed > 0 ? tracker.elapsed.clockString : "0:00",
                    color: Theme.teal,
                    alignment: .center
                )
                Spacer()
                statColumn(
                    title: "PACE",
                    value: livePaceText,
                    color: Theme.violet,
                    alignment: .trailing
                )
            }

            HStack(spacing: 12) {
                switch tracker.phase {
                case .idle:
                    trackButton(title: "Start", icon: "record.circle.fill", tint: Theme.emerald) {
                        tracker.start()
                        camera = .userLocation(fallback: .automatic)
                    }
                case .tracking:
                    trackButton(title: "Pause", icon: "pause.fill", tint: Theme.gold) {
                        tracker.pause()
                    }
                case .paused:
                    trackButton(title: "Resume", icon: "play.fill", tint: Theme.emerald) {
                        tracker.start()
                        camera = .userLocation(fallback: .automatic)
                    }
                    trackButton(title: "Reset", icon: "trash", tint: Theme.coral) {
                        tracker.reset()
                    }
                }
            }

            if tracker.phase == .idle && tracker.coordinates.isEmpty {
                Text("Tip: tap Start, then walk. Your route is recorded live, even with the screen off.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            } else if tracker.phase == .paused {
                Text("Paused. Resume to keep going, or Save to log this walk.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private func trackButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.black)
                .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func statColumn(title: String, value: String, color: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textDim)
                .kerning(1)
            Text(value)
                .statNumberStyle()
                .foregroundStyle(color)
        }
    }

    private var livePaceText: String {
        guard tracker.elapsed > 0, distanceMiles > 0.01 else { return "\u{2014}" }
        let paceMinutes = tracker.elapsed / 60 / distanceMiles
        return String(format: "%.1f", paceMinutes)
    }

    // MARK: Draw controls

    private var drawControls: some View {
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
    }

    // MARK: - Save

    private func save() {
        let walkDate = mode == .track ? (tracker.startDate ?? date) : date
        let duration = mode == .track
            ? tracker.elapsed
            : (Double(durationMinutes) ?? 0) * 60

        let walk = Walk(
            date: walkDate,
            durationSeconds: duration,
            distanceMeters: distanceMeters,
            routePoints: routeCoordinates.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        )
        modelContext.insert(walk)
        try? modelContext.save()
        HealthKitManager.shared.syncIfEnabled(walk: walk)
        tracker.end()
        Haptics.shared.success()
        dismiss()
    }
}

// MARK: - Live GPS tracker

/// Records a walk route live from GPS. Accumulates timestamped-free coordinate
/// samples plus a wall-clock duration that survives pause/resume, and keeps
/// updating in the background so a pocketed phone still logs the route.
@Observable
final class WalkTracker: NSObject, CLLocationManagerDelegate {
    enum Phase { case idle, tracking, paused }

    private(set) var phase: Phase = .idle
    private(set) var coordinates: [CLLocationCoordinate2D] = []
    private(set) var distanceMeters: CLLocationDistance = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var startDate: Date?

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var timer: Timer?

    /// Samples closer than this to the previous one are dropped as GPS jitter.
    private static let minPointSpacing: CLLocationDistance = 5
    /// Fixes with worse horizontal accuracy than this (meters) are ignored.
    private static let maxAccuracy: CLLocationAccuracy = 50

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Begins a fresh recording, or resumes a paused one.
    func start() {
        if phase == .idle {
            coordinates = []
            distanceMeters = 0
            elapsed = 0
            accumulated = 0
            startDate = Date()
        }
        // Never bridge distance across the gap left by a pause.
        lastLocation = nil
        segmentStart = Date()
        phase = .tracking
        enableBackgroundIfAvailable()
        manager.startUpdatingLocation()
        startTimer()
        Haptics.shared.tick()
    }

    func pause() {
        guard phase == .tracking else { return }
        if let started = segmentStart {
            accumulated += Date().timeIntervalSince(started)
        }
        segmentStart = nil
        elapsed = accumulated
        phase = .paused
        lastLocation = nil
        manager.stopUpdatingLocation()
        stopTimer()
        Haptics.shared.tick()
    }

    /// Discards the current recording entirely.
    func reset() {
        manager.stopUpdatingLocation()
        stopTimer()
        phase = .idle
        coordinates = []
        distanceMeters = 0
        elapsed = 0
        accumulated = 0
        segmentStart = nil
        startDate = nil
        lastLocation = nil
        Haptics.shared.tick()
    }

    /// Stops the hardware without touching recorded data (used on save/dismiss).
    func end() {
        manager.stopUpdatingLocation()
        stopTimer()
    }

    /// Background updates require the `location` UIBackgroundMode; enabling the
    /// flag without it throws, so only turn it on when the mode is declared.
    private func enableBackgroundIfAvailable() {
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
           modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = true
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let started = self.segmentStart else { return }
            self.elapsed = self.accumulated + Date().timeIntervalSince(started)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard phase == .tracking else { return }
        for location in locations {
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= Self.maxAccuracy else { continue }
            if let last = lastLocation {
                let step = location.distance(from: last)
                guard step >= Self.minPointSpacing else { continue }
                distanceMeters += step
            }
            lastLocation = location
            coordinates.append(location.coordinate)
        }
    }
}
