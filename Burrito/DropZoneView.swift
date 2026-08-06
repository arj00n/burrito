import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Binding var showSettings: Bool
    @ObservedObject var processor: ImageProcessor
    @AppStorage("enginePreset") private var enginePreset = "balanced"
    @State private var isTargetedPNG = false
    @State private var isTargetedWebP = false
    @State private var isTargetedPDF = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerView

            engineSelector
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 5)

            ZStack {
                splitZonesView
                if !isDropHovering && !processor.isProcessing {
                    idleDropView
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                processingZoneView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .animation(.easeInOut(duration: 0.4), value: processor.isProcessing)
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
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)

            Button(action: {
                NotificationCenter.default.post(name: .dismissDropShelf, object: nil)
            }) {
                Image(systemName: "xmark")
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.16))
    }

    private var engineSelector: some View {
        Picker("Compression", selection: $enginePreset) {
            Text("Fast").tag("fast")
            Text("Balanced").tag("balanced")
            Text("Smallest").tag("smallest")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(Capsule())
        .disabled(processor.isBatchRunning)
        .opacity(processor.isBatchRunning ? 0.55 : 1)
        .help("Fast favors speed, Balanced mixes speed and size, and Smallest applies maximum compression")
    }

    private var isDropHovering: Bool {
        isTargetedPNG || isTargetedWebP || isTargetedPDF
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
        .opacity(processor.isProcessing ? 0 : (isDropHovering ? 1 : 0.001))
        .allowsHitTesting(!processor.isProcessing)
        .animation(.easeOut(duration: 0.14), value: isDropHovering)
    }

    private var pdfDropZone: some View {
        ZStack {
            Rectangle().fill(isTargetedPDF ? Color.white.opacity(0.1) : Color.clear)
            Text("PDF")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], delegate: MediaDropDelegate(
            isTargeted: $isTargetedPDF,
            processor: processor,
            strategy: .highQuality
        ))
    }

    private var formatDropZones: some View {
        HStack(spacing: 0) {
            ZStack {
                Rectangle().fill(isTargetedPNG ? Color.white.opacity(0.1) : Color.clear)
                Text(highQualityDropLabel)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], delegate: MediaDropDelegate(
                isTargeted: $isTargetedPNG,
                processor: processor,
                strategy: .highQuality
            ))
            
            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1).padding(.vertical, 24)
            
            ZStack {
                Rectangle().fill(isTargetedWebP ? Color.white.opacity(0.1) : Color.clear)
                Text(webDropLabel)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], delegate: MediaDropDelegate(
                isTargeted: $isTargetedWebP,
                processor: processor,
                strategy: .webOptimized
            ))
        }
    }

    private var highQualityDropLabel: String {
        switch processor.detectedMediaType {
        case .pdf: return "PDF"
        case .video: return "MP4"
        case .mixed: return "PNG / MP4 / PDF"
        default: return "PNG"
        }
    }

    private var webDropLabel: String {
        switch processor.detectedMediaType {
        case .pdf: return "PDF"
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
        let shaderState: Float = hasFailures ? 2.0 : (isComplete ? 1.0 : 0.0)

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

        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(color)
                .shadow(color: color.opacity(0.35), radius: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(summaryTitle)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                HStack(spacing: 6) {
                    Text(summarySubtitle)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.66))
                    if let savings = processor.savingsPercentage, savings > 0 {
                        Text("−\(savings)%")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.4))
                    }
                }
                if let failure = processor.firstFailure {
                    Text(failure.message)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(.orange.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("\(failure.message) \(failure.suggestion)")
                }
            }

            Spacer()

            HStack(spacing: 6) {
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
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var summaryTitle: String {
        if processor.failureCount > 0 { return "Completed with issues" }
        if processor.cancelledCount > 0 { return "Conversion cancelled" }
        return processor.successCount == 1 ? "1 file optimized" : "\(processor.successCount) files optimized"
    }

    private var summarySubtitle: String {
        var parts: [String] = []
        if processor.successCount > 0 { parts.append("\(processor.successCount) succeeded") }
        if processor.failureCount > 0 { parts.append("\(processor.failureCount) failed") }
        if processor.cancelledCount > 0 { parts.append("\(processor.cancelledCount) cancelled") }
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
    let processor: ImageProcessor
    let strategy: ProcessingStrategy

    func validateDrop(info: DropInfo) -> Bool {
        !processor.isProcessing && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        processor.previewMediaType(from: info.itemProviders(for: [.fileURL]))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
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
            strategy: strategy
        )
        return true
    }
}
