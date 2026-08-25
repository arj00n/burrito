import Combine
import NookSurface
import SwiftUI
import UniformTypeIdentifiers

final class NotchInteractionModel: ObservableObject {
    @Published var isDropTargeted = false
    @Published var activeStrategy: ProcessingStrategy = .highQuality
    @Published var isChoosingFormat = false
    @Published var selectedFiles: [URL] = []
    @Published var isPinned = false
    @Published var isDraggingResults = false

    /// How long the notch stays open waiting for a target format to be picked.
    ///
    /// `isChoosingFormat` feeds `staysExpandedOnHoverExit`, so it holds the notch open
    /// for as long as it is set. Without a deadline, selecting files and then walking
    /// away left the notch expanded indefinitely - the ✕ button was the only way out.
    private static let formatChoiceTimeout: TimeInterval = 45

    private var formatChoiceExpiry: DispatchWorkItem?

    /// Enter (or re-arm) format choice. Call again after the file selection lands so the
    /// deadline is measured from the point the user actually has something to choose.
    func beginChoosingFormat() {
        isChoosingFormat = true

        formatChoiceExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.isChoosingFormat else { return }
            self.endChoosingFormat()
        }
        formatChoiceExpiry = expiry
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.formatChoiceTimeout,
            execute: expiry
        )
    }

    /// Leave format choice and release the notch. Idempotent.
    func endChoosingFormat() {
        formatChoiceExpiry?.cancel()
        formatChoiceExpiry = nil
        selectedFiles = []
        isChoosingFormat = false
    }
}

struct NotchShelfView: View {
    static let contentSize = CGSize(width: 460, height: 204)

    /// Height of the top header row, shared with ``SettingsView`` so the title and the
    /// controls sit on exactly the same line in both states. Pinned rather than left to
    /// intrinsic sizing, because the two headers hold different controls and would
    /// otherwise settle at slightly different heights and shift on every transition.
    static let headerHeight: CGFloat = 16

    /// Horizontal inset of the shelf's content, shared with ``SettingsView``.
    static let contentInset: CGFloat = 16

    @ObservedObject var processor: ImageProcessor
    @ObservedObject var interaction: NotchInteractionModel
    let requestExpansion: () -> Void
    @AppStorage("enginePreset") private var enginePreset = "balanced"
    @State private var showSettings = false

    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(showSettings: $showSettings)
                    .transition(.opacity)
            } else {
                mainContent
                    .transition(.opacity)
            }
        }
        .padding(.top, 32)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height, alignment: .top)
        .background {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.18),
                    Color(red: 0.01, green: 0.16, blue: 0.09).opacity(0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(
                .leading,
                -(NookStyle.standard.topCornerRadius + NookStyle.standardExpandedContentInsets.leading)
            )
            .padding(
                .trailing,
                -(NookStyle.standard.topCornerRadius + NookStyle.standardExpandedContentInsets.trailing)
            )
            .padding(.bottom, -NookStyle.standardExpandedContentInsets.bottom)
        }
        .preferredColorScheme(.dark)
        .environment(\.controlActiveState, .active)
        .animation(.easeOut(duration: 0.14), value: showSettings)
        .onReceive(NotificationCenter.default.publisher(for: .showBurritoDropZone)) { _ in
            showSettings = false
            interaction.endChoosingFormat()
        }
        .onChange(of: processor.isProcessing) { _, processing in
            if processing {
                interaction.endChoosingFormat()
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image("MenuIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 12, height: 12)
                Text("Burrito")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Button { interaction.isPinned.toggle() } label: {
                    Image(systemName: interaction.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(interaction.isPinned ? Color.green : .white.opacity(0.68))
                }
                .buttonStyle(.plain)
                .help(interaction.isPinned ? "Unpin Burrito" : "Keep Burrito open")

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .buttonStyle(.plain)
            }
            .frame(height: Self.headerHeight)

            if processor.isBatchRunning {
                processingContent
            } else if processor.isProcessing {
                resultContent
            } else {
                engineSelector
                dropContent
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var engineSelector: some View {
        HStack(spacing: 3) {
            engineTab("Fast", value: "fast")
            engineTab("Balanced", value: "balanced")
            engineTab("Smallest", value: "smallest")
        }
        .padding(3)
        .background(.black.opacity(0.2), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.13), lineWidth: 0.75))
    }

    private func engineTab(_ title: String, value: String) -> some View {
        Button {
            enginePreset = value
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(enginePreset == value ? .white : .white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .frame(height: 21)
            .background(enginePreset == value ? Color.white.opacity(0.2) : .clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var dropContent: some View {
        Group {
            if interaction.isDropTargeted {
                HStack(spacing: 0) {
                    dropOption(primaryDropLabel, selected: interaction.activeStrategy == .highQuality)
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
                    dropOption(secondaryDropLabel, selected: interaction.activeStrategy == .webOptimized)
                }
                .transition(.opacity)
            } else if !interaction.selectedFiles.isEmpty {
                selectedFormatContent
            } else {
                Button(action: chooseFiles) {
                    FileDropPrompt(title: "Drop or select images, videos, or PDFs")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        interaction.isDropTargeted
                            ? engineTint.opacity(0.12)
                            : Color.white.opacity(0.035)
                    )
                DropZoneTunnel(
                    tint: engineTint,
                    intensity: interaction.isDropTargeted ? .dropTargeted : .idle
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    interaction.isDropTargeted ? engineTint.opacity(0.55) : Color.white.opacity(0.18),
                    style: StrokeStyle(lineWidth: 2, dash: interaction.isDropTargeted ? [] : [6, 6])
                )
        }
        .animation(.easeInOut(duration: 0.35), value: enginePreset)
    }

    /// Colour the drop zone carries for the active engine preset. Warm for speed, the
    /// app's own green for the balanced default, cool for maximum compression.
    private var engineTint: Color {
        switch enginePreset {
        case "fast":
            Color(red: 1.0, green: 0.65, blue: 0.24)
        case "smallest":
            Color(red: 0.63, green: 0.47, blue: 1.0)
        default:
            Color(red: 0.29, green: 0.86, blue: 0.53)
        }
    }

    private var selectedFormatContent: some View {
        VStack(spacing: 7) {
            HStack {
                Text("Choose target format")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Button {
                    interaction.endChoosingFormat()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.58))
            }

            HStack(spacing: 6) {
                formatChoice(primaryDropLabel, strategy: .highQuality)
                if processor.detectedMediaType != .pdf {
                    formatChoice(secondaryDropLabel, strategy: .webOptimized)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func formatChoice(_ title: String, strategy: ProcessingStrategy) -> some View {
        Button {
            let files = interaction.selectedFiles
            interaction.endChoosingFormat()
            processor.processDroppedURLs(files, strategy: strategy)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(engineTint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(engineTint.opacity(0.42), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .video, .pdf]
        panel.prompt = "Select"

        interaction.beginChoosingFormat()
        requestExpansion()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else {
                interaction.endChoosingFormat()
                return
            }
            processor.previewMediaType(from: panel.urls)
            interaction.selectedFiles = panel.urls
            // Re-arm the deadline now that there is actually something to choose - the
            // user may have sat in the open panel for a while.
            interaction.beginChoosingFormat()
            DispatchQueue.main.async { requestExpansion() }
        }
    }

    private func dropOption(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? engineTint.opacity(0.2) : .clear)
    }

    /// Converting. Centred column over a warp-speed field, so the wait reads as travel
    /// rather than as a stalled row of controls.
    private var processingContent: some View {
        VStack(spacing: 9) {
            if let job = processor.currentJob {
                BurritoThumbnail(url: job.sourceURL)
                    .frame(width: 40, height: 40)
            }

            Text(processor.currentFileName ?? "Finishing…")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 250)

            HStack(spacing: 8) {
                ProgressView(value: processor.batchProgress)
                    .progressViewStyle(.linear)
                    .tint(engineTint)
                    .frame(width: 164)
                Text("\(Int(processor.batchProgress * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .leading)
            }

            Button("Cancel") { processor.cancelProcessing() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.white.opacity(0.16), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Same tunnel as the drop zone, run at warp, with the particle field riding
            // its walls - so converting reads as travelling down the zone you dropped
            // into rather than as a different screen.
            let intensity = TunnelIntensity.converting(progress: processor.batchProgress)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.3))
                DropZoneTunnel(tint: engineTint, intensity: intensity)
                WarpField(tint: engineTint, intensity: intensity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Finished. Centred like the conversion screen, over the same tunnel - coasting to a
    /// slow drift on success, frozen on failure - so the outcome is legible from the motion
    /// before a word of the text is read.
    private var resultContent: some View {
        VStack(spacing: 9) {
            if processor.allSucceeded {
                ConvertedFilesStack(
                    urls: processor.outputURLs,
                    onDragStart: {
                        interaction.isDraggingResults = true
                        processor.holdBatchResults()
                    },
                    onDragEnd: { interaction.isDraggingResults = false }
                )
            } else {
                Image(systemName: resultIcon)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(resultTint)
                    .frame(height: 52)
            }

            Text(resultTitle)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(resultDetail ?? "")

            HStack(spacing: 7) {
                if processor.allSucceeded {
                    resultButton(processor.resultsCopied ? "Copied" : "Copy", tint: resultTint) {
                        _ = processor.copyConvertedFilesToClipboard()
                    }
                } else if processor.retryableFailureCount > 0 {
                    resultButton("Retry", tint: resultTint) { processor.retryFailedJobs() }
                }

                resultButton("Done", tint: nil) { processor.dismissBatchResults() }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.28))
                DropZoneTunnel(
                    tint: resultTint,
                    intensity: processor.allSucceeded ? .settled : .stalled
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Pass a `tint` for the run's primary action; `nil` keeps the button neutral, so only
    /// one control in the row ever competes for attention.
    private func resultButton(
        _ title: String,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background((tint ?? .white).opacity(tint == nil ? 0.15 : 0.24), in: Capsule())
            .overlay(
                Capsule().stroke(
                    (tint ?? .white).opacity(tint == nil ? 0.18 : 0.46),
                    lineWidth: 0.75
                )
            )
    }

    private var resultIcon: String {
        if processor.allSucceeded { return "checkmark.circle.fill" }
        if processor.cancelledCount > 0 && processor.failureCount == 0 { return "xmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    /// Colour the whole result screen carries - tunnel, glyph and primary action.
    ///
    /// Success adopts the engine preset, so a finished run still says which setting
    /// produced it. Failure and cancellation break away from the preset deliberately: those
    /// are outcomes, not settings, and tinting them amber or violet would read as a preset
    /// change rather than as something having gone wrong.
    private var resultTint: Color {
        if processor.allSucceeded { return engineTint }
        if processor.failureCount > 0 { return Color(red: 1.0, green: 0.56, blue: 0.27) }
        return Color(red: 0.64, green: 0.68, blue: 0.74)
    }

    /// The whole result on one line: the outcome, then the savings whenever there is a
    /// number worth reporting.
    ///
    /// `savingsPercentage` is computed for any batch that processed at least one byte, not
    /// only for a clean run, so a partial success still gets to report what it did save.
    private var resultTitle: String {
        let outcome: String
        if processor.allSucceeded {
            outcome = processor.successCount == 1
                ? "File optimized"
                : "\(processor.successCount) files optimized"
        } else if processor.cancelledCount > 0, processor.failureCount == 0 {
            outcome = "\(processor.successCount) done, \(processor.cancelledCount) cancelled"
        } else {
            outcome = "\(processor.failureCount) failed, \(processor.successCount) succeeded"
        }

        // No savings clause when nothing succeeded, or when the run genuinely saved
        // nothing - "saved 0%" is worse than silence.
        guard let savings = processor.savingsPercentage,
              savings > 0,
              processor.successCount > 0 else { return outcome }

        return "\(outcome) · saved \(savings)%"
    }

    /// Detail that used to sit on a second line. One line is the budget now, so the failure
    /// reason becomes the row's tooltip rather than being dropped - a shell error is the
    /// only way to find out why a conversion failed.
    private var resultDetail: String? {
        if processor.allSucceeded { return nil }
        if processor.cancelledCount > 0, processor.failureCount == 0 {
            return "Finished files remain in your save folder."
        }
        return processor.firstFailure?.message
    }

    private var primaryDropLabel: String {
        switch processor.detectedMediaType {
        case .video: "MP4"
        case .pdf: "PDF"
        case .mixed: "PNG · MP4 · PDF"
        default: "PNG"
        }
    }

    private var secondaryDropLabel: String {
        switch processor.detectedMediaType {
        case .video: "WEBM"
        case .pdf: "PDF"
        case .mixed: "WEBP · WEBM · PDF"
        default: "WEBP"
        }
    }

}
