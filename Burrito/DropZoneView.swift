import AppKit
import SwiftUI
import QuickLookThumbnailing

struct FileDropPrompt: View {
    let title: String

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                icon("photo.fill", rotation: -13, x: -23, y: 2)
                icon("doc.fill", rotation: 0, x: 0, y: -3)
                icon("play.rectangle.fill", rotation: 13, x: 23, y: 2)
            }
            .compositingGroup()
            .frame(height: 34)

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.82))
        }
    }

    private func icon(_ name: String, rotation: Double, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            Image(systemName: name)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.black)
                .blendMode(.destinationOut)

            Image(systemName: name)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 23, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))
        }
        .rotationEffect(.degrees(rotation))
        .offset(x: x, y: y)
    }
}

struct BurritoThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    /// The card is sized by its container, and the preview is laid *inside* it as an
    /// overlay.
    ///
    /// The shape takes exactly the size it is proposed, and an overlay never feeds back
    /// into layout, so however extreme the file's aspect ratio the card stays the size the
    /// caller asked for and the excess is clipped. A `.frame(maxWidth: .infinity)` around
    /// the image will not do this: that frame is *flexible*, so `scaledToFill` on a
    /// 2400x300 image reported a 336 pt ideal width, the frame grew to match, and the clip
    /// then trimmed to those oversized bounds - spilling the preview sideways across the
    /// success text beside it.
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.ultraThinMaterial)
            .overlay { preview }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.28), lineWidth: 1))
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: 96, height: 96),
                    scale: NSScreen.main?.backingScaleFactor ?? 2,
                    representationTypes: .thumbnail
                )
                image = await withCheckedContinuation { continuation in
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                        continuation.resume(returning: representation?.nsImage)
                    }
                }
            }
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

struct ConvertedFilesStack: View {
    let urls: [URL]
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    private var visibleURLs: [URL] { Array(urls.prefix(3)) }

    var body: some View {
        ZStack {
            ForEach(visibleURLs.indices, id: \.self) { index in
                let position = CGFloat(index) - CGFloat(visibleURLs.count - 1) / 2
                BurritoThumbnail(url: visibleURLs[index])
                    .frame(width: 36, height: 42)
                    .rotationEffect(.degrees(Double(position) * 8))
                    .offset(x: position * 11, y: abs(position) * 2)
            }

            MultiFileDragView(urls: urls, onDragStart: onDragStart, onDragEnd: onDragEnd)
        }
        .frame(width: 64, height: 52)
        .overlay(alignment: .bottomTrailing) {
            if urls.count > 1 {
                Text("\(urls.count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .padding(4)
                    .background(.black.opacity(0.78), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.24), lineWidth: 0.75))
            }
        }
        .help(urls.count == 1 ? "Drag the converted file" : "Drag all converted files")
    }
}

private struct MultiFileDragView: NSViewRepresentable {
    let urls: [URL]
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    func makeNSView(context: Context) -> MultiFileDragNSView {
        MultiFileDragNSView(urls: urls, onDragStart: onDragStart, onDragEnd: onDragEnd)
    }

    func updateNSView(_ view: MultiFileDragNSView, context: Context) {
        view.urls = urls
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
    }
}

private final class MultiFileDragNSView: NSView, NSDraggingSource {
    var urls: [URL]
    var onDragStart: () -> Void
    var onDragEnd: () -> Void
    private var startedDragging = false

    init(urls: [URL], onDragStart: @escaping () -> Void, onDragEnd: @escaping () -> Void) {
        self.urls = urls
        self.onDragStart = onDragStart
        self.onDragEnd = onDragEnd
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startedDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging, !urls.isEmpty else { return }
        startedDragging = true
        onDragStart()

        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 36, height: 36)
            let offset = CGFloat(min(index, 4)) * 3
            item.setDraggingFrame(
                NSRect(x: bounds.midX - 18 + offset, y: bounds.midY - 18 - offset, width: 36, height: 36),
                contents: icon
            )
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        startedDragging = false
        onDragEnd()
    }
}

/// Integrates elapsed time into a looping `0..<1` phase at whatever rate it is handed.
///
/// Rate changes apply going forward only, which is the whole point: speeding the tunnel
/// up mid-march changes its velocity without moving a single ring. A `repeatForever`
/// animation can only change duration by restarting, which resets the phase and visibly
/// shifts the entire tunnel at the moment a drag arrives.
final class TunnelClock {
    private var lastTick: Date?
    private var value: Double = 0

    func phase(at now: Date, rate: Double) -> Double {
        defer { lastTick = now }
        guard let lastTick else { return value }
        let advanced = value + (now.timeIntervalSince(lastTick) * rate)
        value = advanced - advanced.rounded(.down)
        return value
    }
}

/// The single perspective every part of the drop zone's tunnel is built on.
///
/// A cross-section at `depth` - 0 at the frame, 1 at the vanishing point - is this
/// fraction of the frame's size. Geometric rather than linear, which is what gives real
/// reflections their characteristic bunching toward the vanishing point. Rings, rails and
/// warp particles all read their geometry from here, which is what makes the particles
/// look like they are travelling down the tunnel the rings describe rather than drifting
/// through a radial spray of their own.
enum TunnelPerspective {
    /// Deliberately shallow. A deep vanishing scale drives rings down to a few percent of
    /// the frame within the first fraction of the tunnel, which means the only rings large
    /// enough to clear centred content are the outermost one or two - everything else piles
    /// through the middle of the UI. Flattening the curve lets rings fade out while they are
    /// still most of the frame's size, so they never reach the content at all.
    ///
    /// Particles recover the depth this gives up by travelling a much longer stretch of the
    /// same curve - see `WarpField.particleDepthSpan`.
    static let vanishingScale: Double = 0.6

    static func scale(atDepth depth: Double) -> Double {
        pow(vanishingScale, depth)
    }
}

/// How hard the tunnel is running.
///
/// The drop zone drifts, a drag over it quickens, a conversion runs it at warp with the
/// particle field layered in - and then it either coasts to a drift (``settled``) or stops
/// dead (``stalled``). That last pair is deliberate: after the warp screen, motion alone
/// tells you whether the run succeeded, before a word of the text is read.
enum TunnelIntensity: Equatable {
    case idle
    case dropTargeted
    case converting(progress: Double)

    /// Arrived. A slow, bright drift - the warp coasting to rest.
    case settled

    /// Stopped, near enough. Dimmed and creeping - a minute or so for one ring to cross -
    /// so the screen still breathes without suggesting anything is under way.
    case stalled

    /// Cycles per second. One cycle is a full run from vanishing point to frame.
    var rate: Double {
        switch self {
        case .idle:
            1.0 / 7.0
        case .dropTargeted:
            1.0 / 1.7
        case .converting(let progress):
            // Accelerates as the batch completes, so the sense of speed tracks how close
            // the work actually is to done.
            0.85 + (1.25 * min(max(progress, 0), 1))
        case .settled:
            1.0 / 14.0
        case .stalled:
            1.0 / 75.0
        }
    }

    var ringBrightness: Double {
        switch self {
        case .idle: 0.6
        case .dropTargeted: 0.95
        case .converting: 0.88
        case .settled: 0.8
        case .stalled: 0.34
        }
    }

    var railBrightness: Double {
        switch self {
        case .idle: 0.4
        case .dropTargeted: 0.66
        case .converting: 0.6
        case .settled: 0.5
        case .stalled: 0.22
        }
    }

    var glow: Double {
        switch self {
        case .idle: 0.55
        case .dropTargeted: 0.9
        case .converting: 0.9
        case .settled: 0.75
        case .stalled: 0.3
        }
    }

    /// Depth by which rings have completely faded, leaving everything deeper clear.
    ///
    /// Per state because each screen needs a different amount of room: the drop zone holds
    /// only a short prompt, while the conversion and result screens fill the zone top to
    /// bottom and need the rings pulled back toward the frame.
    var ringFadeOutDepth: Double {
        switch self {
        case .idle, .dropTargeted: 0.42
        case .converting: 0.34
        case .settled, .stalled: 0.3
        }
    }

    var bloomRadius: Double {
        switch self {
        case .idle: 5
        case .dropTargeted: 7
        case .converting: 7
        case .settled: 6
        case .stalled: 4
        }
    }
}

/// One perspective rail: a straight run from a corner of the drop zone to the vanishing
/// point. Stroked at a constant width; the fade along it is what stops the four rails
/// reaching each other.
private struct TunnelRail: Shape {
    let origin: UnitPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(
            to: CGPoint(
                x: rect.minX + (rect.width * origin.x),
                y: rect.minY + (rect.height * origin.y)
            )
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        return path
    }
}

/// Receding "infinity mirror" tunnel: nested rounded rectangles marching toward a
/// vanishing point, with four perspective rails running in from the corners.
///
/// Rings and rails both live in the outer part of the tunnel only and are gone well before
/// the middle, leaving the centre clear for whatever the host puts there. That clearance is
/// why ``ringCount`` is high: the visible band is narrow, and a band that narrow needs
/// closely spaced rings or it reads as two lonely rectangles.
struct DropZoneTunnel: View {
    let tint: Color
    let intensity: TunnelIntensity

    @State private var clock = TunnelClock()
    @State private var intro: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Kept low on purpose. The flattened perspective confines every visible ring to a
    /// narrow band just inside the frame, so a high count stacks them a couple of points
    /// apart and the tunnel reads as a thick multi-line border instead of as depth.
    private static let ringCount = 8
    private static let outerCornerRadius: Double = 12

    /// Depth over which a ring fades up as it enters at the frame - only long enough to
    /// hide the loop's wrap.
    private static let ringFadeInDepth: Double = 0.07

    /// Reveal when the notch opens: rails draw outward from the centre while rings fade up.
    private static let introDuration: Double = 0.55

    private static let railOrigins: [UnitPoint] = [
        .topLeading, .topTrailing, .bottomLeading, .bottomTrailing
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if reduceMotion {
                tunnel(in: size, phase: 0)
            } else {
                TimelineView(.animation) { context in
                    tunnel(in: size, phase: clock.phase(at: context.date, rate: intensity.rate))
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard intro == 0 else { return }
            withAnimation(.easeOut(duration: Self.introDuration)) { intro = 1 }
        }
    }

    private func tunnel(in size: CGSize, phase: Double) -> some View {
        let lines = ZStack {
            rails(in: size)
            rings(in: size, phase: phase)
        }

        return ZStack {
            // One blurred copy of the whole line network, added back over itself. A single
            // blur pass buys the bloom that a `.shadow` per ring would need dozens of
            // passes a frame to approximate.
            lines
                .blur(radius: intensity.bloomRadius)
                .blendMode(.plusLighter)
                .opacity(intensity.glow)
            lines
            edgeFalloff(in: size)
        }
        .compositingGroup()
    }

    private func rings(in size: CGSize, phase: Double) -> some View {
        ZStack {
            ForEach(0..<Self.ringCount, id: \.self) { index in
                let depth = depth(ofRing: index, phase: phase)
                let scale = TunnelPerspective.scale(atDepth: depth)

                RoundedRectangle(cornerRadius: Self.outerCornerRadius * scale)
                    .stroke(
                        tint.opacity(ringOpacity(atDepth: depth)),
                        lineWidth: 0.5 + (1.1 * scale)
                    )
                    .frame(width: size.width * scale, height: size.height * scale)
            }
        }
    }

    /// Rails fade up from the frame and back out early, matching the rings.
    ///
    /// `endPoint: .center` matters: a shape's gradient is measured over the shape view's
    /// full frame - the whole drop zone - so aiming the axis at the centre is what makes a
    /// stop location mean "fraction of the way down the rail".
    private func rails(in size: CGSize) -> some View {
        ZStack {
            ForEach(Self.railOrigins, id: \.self) { origin in
                TunnelRail(origin: origin)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: tint.opacity(0), location: 0),
                                .init(color: tint.opacity(intensity.railBrightness), location: 0.11),
                                .init(color: tint.opacity(0), location: 0.26)
                            ],
                            startPoint: origin,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
            }
        }
        .scaleEffect(0.86 + (0.14 * intro))
        .opacity(intro)
    }

    /// Vignette. Darkens the frame rather than the vanishing point.
    private func edgeFalloff(in size: CGSize) -> some View {
        RadialGradient(
            colors: [
                Color.black.opacity(0),
                Color.black.opacity(0.12),
                Color.black.opacity(0.5)
            ],
            center: .center,
            startRadius: min(size.width, size.height) * 0.2,
            endRadius: max(size.width, size.height) * 0.62
        )
    }

    private func depth(ofRing index: Int, phase: Double) -> Double {
        let raw = (Double(index) / Double(Self.ringCount)) + phase
        return raw - raw.rounded(.down)
    }

    /// A ring fades up briefly as it enters at the frame, then out again by the state's
    /// ``TunnelIntensity/ringFadeOutDepth``, keeping it clear of centred content.
    ///
    /// The fade-out doubles as the loop's seam: a ring is long invisible by the time it
    /// teleports from the vanishing point back out to the frame.
    private func ringOpacity(atDepth depth: Double) -> Double {
        let arriving = min(depth / Self.ringFadeInDepth, 1)
        let leaving = min(max(intensity.ringFadeOutDepth - depth, 0) / 0.2, 1)
        return intensity.ringBrightness * arriving * leaving * intro
    }
}

/// Warp-speed field for the conversion screen: glowing particles riding the four walls of
/// the tunnel, out of the vanishing point and past the viewer.
///
/// Particles sit on the tunnel's wall planes and are scaled by ``TunnelPerspective`` - the
/// same curve the rings use - so they read as travelling down the tunnel the rings
/// describe. A radial spray with an acceleration curve of its own looks like weather in
/// front of the tunnel rather than motion through it.
///
/// Drawn as a single `Canvas`: ninety-odd shape views laid out afresh every frame is a
/// different order of cost from ninety fills into one drawing context.
struct WarpField: View {
    let tint: Color
    let intensity: TunnelIntensity

    @State private var clock = TunnelClock()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let particleCount = 92

    /// How far past the frame a particle rides before wrapping, as a multiple of the
    /// frame's half-extent. Above 1 so particles leave the frame instead of piling up
    /// along its edge.
    private static let overshoot: Double = 1.35

    /// Diameter of a particle as it passes the frame. Scaled on the same perspective curve
    /// as its position, so nearer means bigger.
    private static let nearDiameter: Double = 4.2

    /// How many tunnel-depths a particle covers in one life.
    ///
    /// The rings only decorate the mouth of the tunnel - they fade out inside the first
    /// half-depth, which is what keeps them off the UI. Particles run the same geometric
    /// curve far deeper, so they still emerge from a genuine vanishing point rather than
    /// popping into being at four-fifths of the frame's width.
    private static let particleDepthSpan: Double = 4.5

    var body: some View {
        ZStack {
            if reduceMotion {
                field(phase: 0)
            } else {
                TimelineView(.animation) { context in
                    field(phase: clock.phase(at: context.date, rate: intensity.rate))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func field(phase: Double) -> some View {
        let canvas = Canvas { context, size in
            draw(into: &context, size: size, phase: phase)
        }

        return ZStack {
            canvas.blur(radius: 6).blendMode(.plusLighter).opacity(0.85)
            canvas
        }
        .compositingGroup()
    }

    private func draw(into context: inout GraphicsContext, size: CGSize, phase: Double) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2

        for index in 0..<Self.particleCount {
            // Evenly spaced launch phases, deliberately not pre-warped: riding a geometric
            // curve means particles genuinely *should* crowd toward the vanishing point,
            // exactly as the rings do. That crowding is the perspective.
            let launch = Double(index) / Double(Self.particleCount)
            let speed = 0.85 + (Self.noise(index, salt: 1) * 0.3)

            let raw = launch + (phase * speed)
            let travel = raw - raw.rounded(.down)

            // Depth runs 1 (vanishing point) down to 0 (frame): born deep, flying out past
            // the viewer.
            let scale = TunnelPerspective.scale(
                atDepth: (1 - travel) * Self.particleDepthSpan
            ) * Self.overshoot

            // Pinned to one wall plane at a fixed position along it, so a particle tracks
            // straight out along the tunnel instead of wandering across it.
            let along = (Self.noise(index, salt: 2) * 2) - 1
            let point: CGPoint

            switch index % 4 {
            case 0:
                point = CGPoint(
                    x: centre.x + (along * halfWidth * scale),
                    y: centre.y - (halfHeight * scale)
                )
            case 1:
                point = CGPoint(
                    x: centre.x + (along * halfWidth * scale),
                    y: centre.y + (halfHeight * scale)
                )
            case 2:
                point = CGPoint(
                    x: centre.x - (halfWidth * scale),
                    y: centre.y + (along * halfHeight * scale)
                )
            default:
                point = CGPoint(
                    x: centre.x + (halfWidth * scale),
                    y: centre.y + (along * halfHeight * scale)
                )
            }

            let diameter = max(0.7, Self.nearDiameter * scale)
            let opacity = min(travel / 0.12, 1) * min((1 - travel) / 0.1, 1)

            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - (diameter / 2),
                        y: point.y - (diameter / 2),
                        width: diameter,
                        height: diameter
                    )
                ),
                with: .color(tint.opacity(opacity * 0.95))
            )
        }
    }

    /// Stable per-particle pseudo-randomness. A particle's wall position must be identical
    /// on every frame or the field boils, so it is hashed from the index rather than pulled
    /// from a generator.
    private static func noise(_ index: Int, salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64((index &* 73_856_093) ^ (salt &* 19_349_663) ^ 0x9E37_79B9))
        x ^= x >> 33
        x = x &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 29
        x = x &* 0xC4CE_B9FE_1A85_EC53
        x ^= x >> 32
        return Double(x % 1_000_003) / 1_000_003
    }
}
