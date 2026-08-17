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
}

struct NotchShelfView: View {
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
        .frame(width: 460, height: 204, alignment: .top)
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
            interaction.selectedFiles = []
            interaction.isChoosingFormat = false
        }
        .onChange(of: processor.isProcessing) { _, processing in
            if processing {
                interaction.selectedFiles = []
                interaction.isChoosingFormat = false
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
        .background(
            interaction.isDropTargeted ? Color.green.opacity(0.11) : Color.white.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    interaction.isDropTargeted ? Color.green.opacity(0.5) : Color.white.opacity(0.18),
                    style: StrokeStyle(lineWidth: 2, dash: interaction.isDropTargeted ? [] : [6, 6])
                )
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
                    interaction.selectedFiles = []
                    interaction.isChoosingFormat = false
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
            interaction.selectedFiles = []
            processor.processDroppedURLs(files, strategy: strategy)
            interaction.isChoosingFormat = false
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.42), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .video, .pdf]
        panel.prompt = "Select"

        interaction.isChoosingFormat = true
        requestExpansion()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else {
                interaction.isChoosingFormat = false
                return
            }
            processor.previewMediaType(from: panel.urls)
            interaction.selectedFiles = panel.urls
            DispatchQueue.main.async { requestExpansion() }
        }
    }

    private func dropOption(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color.green.opacity(0.18) : .clear)
    }

    private var processingContent: some View {
        HStack(spacing: 14) {
            if let job = processor.currentJob {
                BurritoThumbnail(url: job.sourceURL)
                    .frame(width: 42, height: 42)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(processor.currentFileName ?? "Finishing…")
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(processor.batchProgress * 100))%")
                        .monospacedDigit()
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))

                ProgressView(value: processor.batchProgress)
                    .progressViewStyle(.linear)
                    .tint(.green)
            }

            Button("Cancel") { processor.cancelProcessing() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxHeight: .infinity)
    }

    private var resultContent: some View {
        HStack(spacing: 12) {
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
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(resultColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if processor.allSucceeded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(resultTitle)
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                Text(resultSubtitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.64))
            }

            Spacer()

            if processor.allSucceeded {
                resultButton(processor.resultsCopied ? "Copied" : "Copy") {
                    _ = processor.copyConvertedFilesToClipboard()
                }
            } else if processor.retryableFailureCount > 0 {
                resultButton("Retry") { processor.retryFailedJobs() }
            }

            resultButton("Done") { processor.dismissBatchResults() }
        }
        .frame(maxHeight: .infinity)
    }

    private func resultButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(.white.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.75))
    }

    private var resultIcon: String {
        if processor.allSucceeded { return "checkmark.circle.fill" }
        if processor.cancelledCount > 0 && processor.failureCount == 0 { return "xmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var resultColor: Color {
        processor.allSucceeded ? .green : processor.failureCount > 0 ? .orange : .secondary
    }

    private var resultTitle: String {
        if processor.allSucceeded {
            return processor.successCount == 1 ? "File optimized" : "\(processor.successCount) files optimized"
        }
        if processor.cancelledCount > 0 {
            return "\(processor.successCount) completed, \(processor.cancelledCount) cancelled"
        }
        return "\(processor.failureCount) failed, \(processor.successCount) succeeded"
    }

    private var resultSubtitle: String {
        if let savings = processor.savingsPercentage, processor.allSucceeded {
            return "Saved \(savings)%"
        }
        if processor.cancelledCount > 0 && processor.failureCount == 0 {
            return "Finished files remain in your save folder."
        }
        return processor.firstFailure?.message ?? "Conversion finished"
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
