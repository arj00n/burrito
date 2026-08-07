import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Binding var showSettings: Bool
    @ObservedObject var processor: ImageProcessor
    @AppStorage("enginePreset") private var enginePreset = "balanced"
    @State private var isDropTargeted = false
    @State private var activeDropStrategy: ProcessingStrategy = .highQuality
    @Namespace private var engineTabAnimation
    
    var body: some View {
        VStack(spacing: 0) {
            headerView

            engineSelector
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 5)

            ZStack {
                splitZonesView
                if !isDropTargeted && !processor.isProcessing {
                    idleDropView
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                processingZoneView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], delegate: MediaDropDelegate(
                isTargeted: $isDropTargeted,
                activeStrategy: $activeDropStrategy,
                processor: processor,
                midpoint: 158
            ))
            .overlay {
                borderOverlay
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 340, height: 180)
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }

    private var headerView: some View {
        HStack(spacing: 6) {
            Image("MenuIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 14, height: 14)
            
            Text("Burrito")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Spacer()
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.white.opacity(0.72))
            }
            .buttonStyle(.plain)

            Button(action: {
                NotificationCenter.default.post(name: .dismissDropShelf, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.22))
    }

    private var engineSelector: some View {
        HStack(spacing: 3) {
            engineTab("Fast", value: "fast")
            engineTab("Balanced", value: "balanced")
            engineTab("Smallest", value: "smallest")
        }
        .padding(3)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.16), lineWidth: 0.75))
        .disabled(processor.isBatchRunning)
        .opacity(processor.isBatchRunning ? 0.55 : 1)
        .help("Fast favors speed, Balanced mixes speed and size, and Smallest applies maximum compression")
    }

    private func engineTab(_ title: String, value: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                enginePreset = value
            }
        } label: {
            ZStack {
                if enginePreset == value {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.2))
                        .matchedGeometryEffect(id: "engineTabSelection", in: engineTabAnimation)
                }

                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(enginePreset == value ? .white : .white.opacity(0.68))
            }
            .frame(height: 20)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityValue(enginePreset == value ? "Selected" : "")
    }

    private var idleDropView: some View {
        VStack(spacing: 5) {
            ZStack {
                idleIcon("photo.fill", rotation: -13, x: -22, y: 2)
                idleIcon("doc.fill", rotation: 0, x: 0, y: -3)
                idleIcon("play.rectangle.fill", rotation: 13, x: 22, y: 2)
            }
            .compositingGroup()
            .frame(height: 30)

            Text("Drop images, video, or PDFs")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.82))
        }
    }

    private func idleIcon(_ name: String, rotation: Double, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            Image(systemName: name)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.black)
                .blendMode(.destinationOut)

            Image(systemName: name)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))
        }
            .rotationEffect(.degrees(rotation))
            .offset(x: x, y: y)
    }

    private var splitZonesView: some View {
        Group {
            if processor.detectedMediaType == .pdf {
                pdfDropZone
            } else {
                formatDropZones
            }
        }
        .opacity(processor.isProcessing ? 0 : (isDropTargeted ? 1 : 0.001))
        .allowsHitTesting(!processor.isProcessing)
        .animation(.easeOut(duration: 0.14), value: isDropTargeted)
    }

    private var pdfDropZone: some View {
        ZStack {
            Rectangle().fill(isDropTargeted ? Color.white.opacity(0.1) : Color.clear)
            Text("PDF")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var formatDropZones: some View {
        HStack(spacing: 0) {
            ZStack {
                Rectangle().fill(
                    isDropTargeted && activeDropStrategy == .highQuality
                        ? Color.white.opacity(0.1)
                        : Color.clear
                )
                Text(highQualityDropLabel)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1).padding(.vertical, 24)
            
            ZStack {
                Rectangle().fill(
                    isDropTargeted && activeDropStrategy == .webOptimized
                        ? Color.white.opacity(0.1)
                        : Color.clear
                )
                Text(webDropLabel)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var highQualityDropLabel: String {
        switch processor.detectedMediaType {
        case .video: return "MP4"
        case .mixed: return "PNG / MP4 / PDF"
        default: return "PNG"
        }
    }

    private var webDropLabel: String {
        switch processor.detectedMediaType {
        case .video: return "WEBM"
        case .mixed: return "WEBP / WEBM / PDF"
        default: return "WEBP"
        }
    }


    private var processingZoneView: some View {
        GeometryReader { geo in
            if processor.isProcessing {
                TimelineView(.animation(minimumInterval: 1/30)) { timeline in
                    processingContent(geo: geo, timeline: timeline)
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(processor.isProcessing)
    }

    private func processingContent(geo: GeometryProxy, timeline: TimelineViewDefaultContext) -> some View {
        let elapsedTime = timeline.date.timeIntervalSince(processor.processingStartTime)
        let isComplete = !processor.isBatchRunning
        let hasFailures = processor.failureCount > 0
        let wasCancelled = processor.cancelledCount > 0
        let didSucceed = isComplete && !hasFailures && !wasCancelled
        let shaderState: Float = (hasFailures || wasCancelled) ? 2.0 : (didSucceed ? 1.0 : 0.0)

        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.025))
            .layerEffect(
                ShaderLibrary.modernFluid(
                    .float(elapsedTime),
                    .float2(Float(geo.size.width), Float(geo.size.height)),
                    .float(shaderState)
                ),
                maxSampleOffset: CGSize(width: 10, height: 10)
            )

            Group {
                if processor.isBatchRunning {
                    batchProgressView
                } else {
                    batchSummaryView
                }
            }
            .animation(.easeOut(duration: 0.18), value: processor.isBatchRunning)
        }
    }

    private var batchProgressView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(processor.completedCount) OF \(processor.totalCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.1)
                Spacer()
                Text("\(Int(processor.batchProgress * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.13))
                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: max(0, geometry.size.width * processor.batchProgress))
                }
            }
            .frame(height: 6)

            Text(processor.currentFileName ?? "Preparing files…")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if processor.failureCount > 0 {
                    Text("\(processor.failureCount) failed")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.orange)
                }
                Spacer()
                Button("Cancel") {
                    processor.cancelProcessing()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.68))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var batchSummaryView: some View {
        let hasFailures = processor.failureCount > 0
        let wasCancelled = processor.cancelledCount > 0
        let color: Color = hasFailures ? .orange : (wasCancelled ? .gray : Color(red: 0.2, green: 0.8, blue: 0.4))
        let icon = hasFailures ? "exclamationmark.triangle.fill" : (wasCancelled ? "stop.circle.fill" : "checkmark.circle.fill")

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
                    .shadow(color: color.opacity(0.35), radius: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(summaryTitle)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let savings = processor.savingsPercentage, processor.successCount > 0 {
                        Text("Saved \(savings)%")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.66))
                    }
                }

                Spacer(minLength: 4)

                if processor.retryableFailureCount > 0 {
                    Button("Retry") {
                        processor.retryFailedJobs()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Retry only the files that failed")
                }

                Button("Done") {
                    processor.dismissBatchResults()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(color)
            }

            if let failure = processor.firstFailure {
                Text(failure.message)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(failure.suggestion)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundColor(.orange.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("\(failure.title): \(failure.message) \(failure.suggestion)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summaryTitle: String {
        var parts: [String] = []
        if processor.successCount == 1 { parts.append("1 file optimized") }
        if processor.successCount > 1 { parts.append("\(processor.successCount) files optimized") }
        if processor.failureCount == 1 { parts.append("1 failed") }
        if processor.failureCount > 1 { parts.append("\(processor.failureCount) failed") }
        if processor.cancelledCount == 1 { parts.append("1 cancelled") }
        if processor.cancelledCount > 1 { parts.append("\(processor.cancelledCount) cancelled") }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if !processor.isProcessing {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
        } else {
            TimelineView(.animation(minimumInterval: 1/30)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(processor.processingStartTime)
                let completionColor: Color = processor.failureCount > 0
                    ? .orange
                    : (processor.cancelledCount > 0 ? .gray : Color(red: 0.24, green: 0.94, blue: 0.58))

                if processor.isBatchRunning {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            AngularGradient(
                                colors: [.green, .mint, .cyan, .blue, .cyan, .green],
                                center: .center,
                                startAngle: .degrees(elapsed * 34 * processor.meshMotionRate),
                                endAngle: .degrees(360 + elapsed * 34 * processor.meshMotionRate)
                            ),
                            lineWidth: 3
                        )
                        .shadow(color: .cyan.opacity(0.42), radius: 7)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(completionColor.opacity(0.075))
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                AngularGradient(
                                    colors: [.green.opacity(0.7), .mint, .cyan, .blue, .cyan, .green.opacity(0.7)],
                                    center: .center,
                                    startAngle: .degrees(elapsed * 12),
                                    endAngle: .degrees(360 + elapsed * 12)
                                ),
                                lineWidth: 2.5
                            )
                            .shadow(color: completionColor.opacity(0.8), radius: 8)
                    }
                }
            }
            .transition(.opacity)
        }
    }
    
}

private struct MediaDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var activeStrategy: ProcessingStrategy
    let processor: ImageProcessor
    let midpoint: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        !processor.isProcessing && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        activeStrategy = strategy(at: info.location)
        processor.previewMediaType(from: info.itemProviders(for: [.fileURL]))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activeStrategy = strategy(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        processor.clearMediaTypePreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard !processor.isProcessing else { return false }
        isTargeted = false
        processor.processDroppedProviders(
            info.itemProviders(for: [.fileURL]),
            strategy: strategy(at: info.location)
        )
        return true
    }

    private func strategy(at location: CGPoint) -> ProcessingStrategy {
        location.x < midpoint ? .highQuality : .webOptimized
    }
}
