import Foundation
import UniformTypeIdentifiers
import SwiftUI
import Combine
import PDFKit

enum TargetFormat: Equatable {
    case png
    case webp
    case mp4
    case webm
    case pdf

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .webp: return "webp"
        case .mp4: return "mp4"
        case .webm: return "webm"
        case .pdf: return "pdf"
        }
    }
}

enum ProcessingStrategy {
    case highQuality
    case webOptimized
}

enum MediaType {
    case image
    case video
    case pdf
    case mixed
    case unknown
}

enum ConversionFailureKind {
    case unsupportedFile
    case unreadableInput
    case outputFolder
    case toolUnavailable
    case permissionDenied
    case insufficientSpace
    case qualityThreshold
    case encoderRejected
    case invalidOutput
    case unexpected
}

struct ConversionFailure: Error {
    let kind: ConversionFailureKind
    let title: String
    let message: String
    let suggestion: String
    let technicalDetails: String?

    var displayMessage: String { "\(title): \(message)" }
}

enum ConversionJobState {
    case queued
    case processing
    case succeeded
    case failed(ConversionFailure)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        case .queued, .processing: return false
        }
    }
}

struct ConversionJob: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let targetFormat: TargetFormat?
    var state: ConversionJobState
    var outputURL: URL?

    var displayName: String { sourceURL.lastPathComponent }
}

private struct ConversionOutput {
    let originalSize: Int64
    let optimizedSize: Int64
    let outputURL: URL
}

private struct CommandResult {
    let status: Int32
    let standardError: String
}

private final class LockedURLSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?]

    init(count: Int) {
        urls = Array(repeating: nil, count: count)
    }

    func set(_ url: URL, at index: Int) {
        lock.lock()
        urls[index] = url
        lock.unlock()
    }

    func collected() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls.compactMap { $0 }
    }
}

private final class BatchMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var originalBytes: Int64 = 0
    private var optimizedBytes: Int64 = 0

    func add(_ output: ConversionOutput) {
        lock.lock()
        originalBytes += output.originalSize
        optimizedBytes += output.optimizedSize
        lock.unlock()
    }

    func snapshot() -> (original: Int64, optimized: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (originalBytes, optimizedBytes)
    }
}

final class ImageProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var isBatchRunning = false
    @Published var isSuccess = false
    @Published var isError = false
    @Published var errorMessage: String?
    @Published var savingsPercentage: Int?
    @Published var processingStartTime = Date()
    @Published var successStartTime = Date()
    @Published var detectedMediaType: MediaType = .unknown
    @Published var jobs: [ConversionJob] = []
    @Published var meshMotionRate = 0.55

    private let processLock = NSLock()
    private let outputLock = NSLock()
    private var activeProcesses: [ObjectIdentifier: Process] = [:]
    private var cancelRequested = false
    private var autoDismissWorkItem: DispatchWorkItem?
    private var lastProgressDate = Date()
    private var smoothedItemsPerSecond = 0.0
    private var mediaPreviewToken = UUID()

    var totalCount: Int { jobs.count }
    var completedCount: Int { jobs.filter { $0.state.isTerminal }.count }
    var successCount: Int {
        jobs.filter {
            if case .succeeded = $0.state { return true }
            return false
        }.count
    }
    var failureCount: Int {
        jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
    }
    var retryableFailureCount: Int {
        jobs.filter {
            guard $0.targetFormat != nil else { return false }
            if case .failed = $0.state { return true }
            return false
        }.count
    }
    var cancelledCount: Int {
        jobs.filter {
            if case .cancelled = $0.state { return true }
            return false
        }.count
    }
    var batchProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
    var currentFileName: String? {
        jobs.first {
            if case .processing = $0.state { return true }
            return false
        }?.displayName
    }
    var firstFailure: ConversionFailure? {
        jobs.compactMap {
            if case let .failed(failure) = $0.state { return failure }
            return nil
        }.first
    }

    func previewMediaType(from providers: [NSItemProvider]) {
        let token = UUID()
        mediaPreviewToken = token

        let suggestedURLs = providers.compactMap { provider -> URL? in
            guard let name = provider.suggestedName, !name.isEmpty else { return nil }
            return URL(fileURLWithPath: name)
        }
        if !suggestedURLs.isEmpty {
            detectedMediaType = mediaType(for: suggestedURLs)
        }

        loadURLs(from: providers) { [weak self] urls in
            guard let self, self.mediaPreviewToken == token, !self.isProcessing else { return }
            self.detectedMediaType = self.mediaType(for: urls)
        }
    }

    func clearMediaTypePreview() {
        mediaPreviewToken = UUID()
        guard !isProcessing else { return }
        detectedMediaType = .unknown
    }

    func processDroppedProviders(_ providers: [NSItemProvider], strategy: ProcessingStrategy) {
        mediaPreviewToken = UUID()
        loadURLs(from: providers) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.processDroppedURLs(urls, strategy: strategy)
        }
    }

    func processDroppedURLs(_ droppedURLs: [URL], strategy: ProcessingStrategy) {
        autoDismissWorkItem?.cancel()
        let sourceURLs = expandedSourceURLs(from: droppedURLs)
        let preparedJobs = sourceURLs.map { prepareJob(for: $0, strategy: strategy) }
        guard !preparedJobs.isEmpty else { return }

        setCancellationRequested(false)
        lastProgressDate = Date()
        smoothedItemsPerSecond = 0

        withAnimation(.easeInOut(duration: 0.22)) {
            isProcessing = true
            isBatchRunning = true
            isSuccess = false
            isError = false
            errorMessage = nil
            savingsPercentage = nil
            processingStartTime = Date()
            meshMotionRate = 0.55
            detectedMediaType = mediaType(for: sourceURLs)
            jobs = preparedJobs
        }

        runQueuedJobs()
    }

    func retryFailedJobs() {
        guard !isBatchRunning, retryableFailureCount > 0 else { return }
        autoDismissWorkItem?.cancel()
        setCancellationRequested(false)
        lastProgressDate = Date()
        smoothedItemsPerSecond = 0

        for index in jobs.indices where jobs[index].targetFormat != nil {
            if case .failed = jobs[index].state {
                jobs[index].state = .queued
                jobs[index].outputURL = nil
            }
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            isBatchRunning = true
            isSuccess = false
            isError = false
            errorMessage = nil
            savingsPercentage = nil
            processingStartTime = Date()
            meshMotionRate = 0.55
        }

        runQueuedJobs()
    }

    private func runQueuedJobs() {
        let queuedJobs = jobs

        let workerCount = adaptiveWorkerCount(for: queuedJobs)
        let group = DispatchGroup()
        let metrics = BatchMetrics()
        let operationQueue = OperationQueue()
        operationQueue.name = "com.arjoon.burrito.conversion"
        operationQueue.qualityOfService = .userInitiated
        operationQueue.maxConcurrentOperationCount = workerCount

        for index in queuedJobs.indices {
            guard case .queued = queuedJobs[index].state,
                  let targetFormat = queuedJobs[index].targetFormat else { continue }

            group.enter()
            operationQueue.addOperation {
                defer { group.leave() }

                guard !self.isCancellationRequested else { return }
                DispatchQueue.main.sync {
                    guard !self.isCancellationRequested else { return }
                    self.jobs[index].state = .processing
                }
                guard !self.isCancellationRequested else { return }

                let result = self.executeShellPipeline(
                    sourceURL: queuedJobs[index].sourceURL,
                    targetFormat: targetFormat
                )

                DispatchQueue.main.sync {
                    if self.isCancellationRequested {
                        self.jobs[index].state = .cancelled
                    } else {
                        switch result {
                        case let .success(output):
                            metrics.add(output)
                            self.jobs[index].outputURL = output.outputURL
                            self.jobs[index].state = .succeeded
                        case let .failure(failure):
                            self.jobs[index].state = .failed(failure)
                        }
                    }
                    self.recordProgressAdvance()
                }
            }
        }

        group.notify(queue: .main) {
            _ = operationQueue.operationCount
            let totals = metrics.snapshot()
            if totals.original > 0 {
                let savings = Double(totals.original - totals.optimized) / Double(totals.original)
                self.savingsPercentage = max(0, Int(savings * 100))
            }

            withAnimation(.easeOut(duration: 0.2)) {
                self.isBatchRunning = false
                self.isSuccess = self.successCount > 0
                self.isError = self.failureCount > 0
                self.errorMessage = self.firstFailure?.displayMessage
                self.meshMotionRate = 0.24
                self.successStartTime = Date()
            }
            self.scheduleAutoDismiss()
        }
    }

    func cancelProcessing() {
        guard isBatchRunning else { return }
        setCancellationRequested(true)

        processLock.lock()
        let processes = Array(activeProcesses.values)
        processLock.unlock()
        for process in processes where process.isRunning { process.terminate() }

        for index in jobs.indices {
            if case .queued = jobs[index].state { jobs[index].state = .cancelled }
        }
    }

    func dismissBatchResults() {
        guard !isBatchRunning else { return }
        autoDismissWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            isProcessing = false
            isSuccess = false
            isError = false
            errorMessage = nil
            savingsPercentage = nil
            jobs = []
            detectedMediaType = .unknown
            meshMotionRate = 0.55
        }
    }

    private func scheduleAutoDismiss() {
        autoDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismissBatchResults()
        }
        autoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func recordProgressAdvance() {
        let now = Date()
        let interval = max(now.timeIntervalSince(lastProgressDate), 0.05)
        let currentRate = 1 / interval
        smoothedItemsPerSecond = smoothedItemsPerSecond == 0
            ? currentRate
            : (smoothedItemsPerSecond * 0.72) + (currentRate * 0.28)
        meshMotionRate = min(max(0.46 + smoothedItemsPerSecond * 0.18, 0.46), 1.65)
        lastProgressDate = now
    }

    private var isCancellationRequested: Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return cancelRequested
    }

    private func setCancellationRequested(_ requested: Bool) {
        processLock.lock()
        cancelRequested = requested
        processLock.unlock()
    }

    private func expandedSourceURLs(from droppedURLs: [URL]) -> [URL] {
        var results: [URL] = []
        for url in droppedURLs {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                results.append(url)
                continue
            }

            let keys: [URLResourceKey] = [.isRegularFileKey]
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let child = enumerator?.nextObject() as? URL {
                if (try? child.resourceValues(forKeys: Set(keys)).isRegularFile) == true {
                    results.append(child)
                }
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func adaptiveWorkerCount(for jobs: [ConversionJob]) -> Int {
        let formats = jobs.compactMap(\.targetFormat)
        guard !formats.isEmpty else { return 1 }
        let videoCount = formats.filter { $0 == .mp4 || $0 == .webm }.count
        let pdfCount = formats.filter { $0 == .pdf }.count
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 2)
        let preset = UserDefaults.standard.string(forKey: "enginePreset") ?? "balanced"

        if videoCount == formats.count { return 1 }
        if pdfCount == formats.count { return preset == "fast" ? 2 : 1 }
        if pdfCount > 0 { return 1 }
        if videoCount > 0 { return preset == "fast" ? min(2, max(1, cores / 6)) : 1 }
        switch preset {
        case "smallest": return min(2, max(1, cores / 6))
        case "balanced": return min(3, max(2, cores / 4))
        default: return min(4, max(2, cores / 3))
        }
    }

    private func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let slots = LockedURLSlots(count: providers.count)
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    slots.set(url, at: index)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(slots.collected())
        }
    }

    private func mediaType(for urls: [URL]) -> MediaType {
        var includesImage = false
        var includesVideo = false
        var includesPDF = false

        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
            includesImage = includesImage || type.conforms(to: .image)
            includesVideo = includesVideo || type.conforms(to: .movie) || type.conforms(to: .video)
            includesPDF = includesPDF || type.conforms(to: .pdf)
        }

        let categoryCount = [includesImage, includesVideo, includesPDF].filter { $0 }.count
        if categoryCount > 1 { return .mixed }
        if includesPDF { return .pdf }
        if includesVideo { return .video }
        if includesImage { return .image }
        return .unknown
    }

    private func prepareJob(for url: URL, strategy: ProcessingStrategy) -> ConversionJob {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return ConversionJob(
                sourceURL: url,
                targetFormat: nil,
                state: .failed(ConversionFailure(
                    kind: .unreadableInput,
                    title: "File can’t be read",
                    message: "Burrito does not have permission to read \(url.lastPathComponent).",
                    suggestion: "Move the file to a writable folder or grant Burrito file access, then try again.",
                    technicalDetails: nil
                ))
            )
        }

        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie)
                || type.conforms(to: .video) || type.conforms(to: .pdf) else {
            return ConversionJob(
                sourceURL: url,
                targetFormat: nil,
                state: .failed(ConversionFailure(
                    kind: .unsupportedFile,
                    title: "Unsupported file",
                    message: "\(url.lastPathComponent) is not a recognized image, video, or PDF.",
                    suggestion: "Drop an image, video, or PDF file instead.",
                    technicalDetails: nil
                ))
            )
        }

        let isVideo = type.conforms(to: .movie) || type.conforms(to: .video)
        let isPDF = type.conforms(to: .pdf)
        let targetFormat: TargetFormat
        if isPDF {
            targetFormat = .pdf
        } else {
            switch strategy {
            case .highQuality: targetFormat = isVideo ? .mp4 : .png
            case .webOptimized: targetFormat = isVideo ? .webm : .webp
            }
        }
        return ConversionJob(sourceURL: url, targetFormat: targetFormat, state: .queued)
    }

    private func executeShellPipeline(
        sourceURL: URL,
        targetFormat: TargetFormat
    ) -> Result<ConversionOutput, ConversionFailure> {
        let fileManager = FileManager.default
        let enginePreset = UserDefaults.standard.string(forKey: "enginePreset") ?? "balanced"
        let x264Preset: String
        let vp9CPUUsed: String
        let webPMethod: String
        let pngQuantSpeed: String
        let oxiPNGLevel: String
        let imageQuality: Int
        let videoCRF: Int
        let aacBitrate: String
        let opusBitrate: String
        switch enginePreset {
        case "smallest":
            x264Preset = "medium"
            vp9CPUUsed = "1"
            webPMethod = "6"
            pngQuantSpeed = "1"
            oxiPNGLevel = "4"
            imageQuality = 48
            videoCRF = 32
            aacBitrate = "64k"
            opusBitrate = "56k"
        case "balanced":
            x264Preset = "fast"
            vp9CPUUsed = "3"
            webPMethod = "5"
            pngQuantSpeed = "2"
            oxiPNGLevel = "3"
            imageQuality = 74
            videoCRF = 25
            aacBitrate = "112k"
            opusBitrate = "96k"
        default:
            x264Preset = "veryfast"
            vp9CPUUsed = "5"
            webPMethod = "4"
            pngQuantSpeed = "4"
            oxiPNGLevel = "2"
            imageQuality = 88
            videoCRF = 20
            aacBitrate = "160k"
            opusBitrate = "128k"
        }
        let originalSize = ((try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let savesBesideOriginals = UserDefaults.standard.string(forKey: "outputLocation") == "besideOriginals"
        let optimizedDirectory = savesBesideOriginals
            ? sourceDirectory
            : sourceDirectory.appendingPathComponent("Optimized Files")

        do {
            try fileManager.createDirectory(at: optimizedDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(ConversionFailure(
                kind: .outputFolder,
                title: "Output folder unavailable",
                message: "Burrito could not prepare the output location for \(sourceURL.lastPathComponent).",
                suggestion: "Choose a source folder where you have write permission.",
                technicalDetails: error.localizedDescription
            ))
        }

        guard fileManager.isWritableFile(atPath: optimizedDirectory.path) else {
            return .failure(ConversionFailure(
                kind: .permissionDenied,
                title: "Output folder is read-only",
                message: "Burrito cannot save beside \(sourceURL.lastPathComponent).",
                suggestion: "Move the source to a writable folder, then try again.",
                technicalDetails: optimizedDirectory.path
            ))
        }

        let sourceBaseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputBaseName = savesBesideOriginals ? "\(sourceBaseName) optimized" : sourceBaseName
        let finalURL = savesBesideOriginals
            ? reserveOutputURL(
                in: optimizedDirectory,
                baseName: outputBaseName,
                extension: targetFormat.fileExtension
            )
            : optimizedDirectory
                .appendingPathComponent(outputBaseName)
                .appendingPathExtension(targetFormat.fileExtension)
        let temporaryURL = optimizedDirectory
            .appendingPathComponent(".burrito-\(UUID().uuidString)")
            .appendingPathExtension(targetFormat.fileExtension)
        var shouldRemoveTemporaryFile = true
        var shouldRemoveOutputReservation = savesBesideOriginals
        defer {
            if shouldRemoveTemporaryFile { try? fileManager.removeItem(at: temporaryURL) }
            if shouldRemoveOutputReservation { try? fileManager.removeItem(at: finalURL) }
        }

        do {
            switch targetFormat {
            case .pdf:
                do {
                    let pdfcpu = try bundledTool(named: "pdfcpu")
                    let stagingURL = optimizedDirectory
                        .appendingPathComponent(".burrito-pdf-stage-\(UUID().uuidString)")
                        .appendingPathExtension("pdf")
                    var pdfInputURL = sourceURL
                    var shouldRemoveStagingFile = false

                    if enginePreset != "fast", let document = PDFDocument(url: sourceURL) {
                        let optimizeImages = PDFDocumentWriteOption(rawValue: "PDFDocumentOptimizeImagesForScreenOption")
                        let encodeImagesAsJPEG = PDFDocumentWriteOption(rawValue: "PDFDocumentSaveImagesAsJPEGOption")
                        let options: [PDFDocumentWriteOption: Any]
                        switch enginePreset {
                        case "smallest":
                            options = [optimizeImages: true, encodeImagesAsJPEG: true]
                        default:
                            options = [encodeImagesAsJPEG: true]
                        }

                        if document.write(to: stagingURL, withOptions: options) {
                            pdfInputURL = stagingURL
                            shouldRemoveStagingFile = true
                        }
                    }
                    defer {
                        if shouldRemoveStagingFile { try? fileManager.removeItem(at: stagingURL) }
                    }

                    let command = try runProcess(
                        executableURL: pdfcpu,
                        arguments: [
                            "optimize", pdfInputURL.path, temporaryURL.path,
                            "--conf=disable", "--offline", "--quiet"
                        ]
                    )
                    guard command.status == 0 else {
                        return .failure(failure(for: command, tool: "PDF optimizer", sourceURL: sourceURL))
                    }
                }

            case .mp4, .webm:
                let ffmpeg = try bundledTool(named: "ffmpeg")
                let arguments: [String]
                if targetFormat == .mp4 {
                    arguments = [
                        "-hide_banner", "-nostdin", "-i", sourceURL.path,
                        "-map", "0:v:0", "-map", "0:a?",
                        "-c:v", "libx264", "-preset", x264Preset, "-crf", "\(videoCRF)",
                        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                        "-c:a", "aac", "-b:a", aacBitrate, "-threads", "0",
                        "-y", temporaryURL.path
                    ]
                } else {
                    let threads = min(ProcessInfo.processInfo.activeProcessorCount, 8)
                    arguments = [
                        "-hide_banner", "-nostdin", "-i", sourceURL.path,
                        "-map", "0:v:0", "-map", "0:a?",
                        "-c:v", "libvpx-vp9", "-crf", "\(videoCRF)", "-b:v", "0",
                        "-deadline", "good", "-cpu-used", vp9CPUUsed, "-row-mt", "1",
                        "-tile-columns", "2", "-threads", "\(threads)",
                        "-c:a", "libopus", "-b:a", opusBitrate,
                        "-y", temporaryURL.path
                    ]
                }
                let command = try runProcess(executableURL: ffmpeg, arguments: arguments)
                guard command.status == 0 else {
                    return .failure(failure(for: command, tool: "Video encoder", sourceURL: sourceURL))
                }

            case .webp:
                let cwebp = try bundledTool(named: "cwebp")
                let command = try runProcess(
                    executableURL: cwebp,
                    arguments: ["-q", "\(imageQuality)", "-m", webPMethod, "-mt", "-quiet", sourceURL.path, "-o", temporaryURL.path]
                )
                guard command.status == 0 else {
                    return .failure(failure(for: command, tool: "WebP encoder", sourceURL: sourceURL))
                }

            case .png:
                let pngquant = try bundledTool(named: "pngquant")
                let maximumQuality = imageQuality
                let minimumQuality = max(0, maximumQuality - 15)
                let quantize = try runProcess(
                    executableURL: pngquant,
                    arguments: ["--quality=\(minimumQuality)-\(maximumQuality)", "--speed", pngQuantSpeed, "--strip", "--force", sourceURL.path, "--output", temporaryURL.path]
                )
                guard quantize.status == 0 else {
                    if quantize.status == 99 {
                        return .failure(ConversionFailure(
                            kind: .qualityThreshold,
                            title: "Couldn’t meet the quality target",
                            message: "Optimizing \(sourceURL.lastPathComponent) at the selected quality would not produce a valid result.",
                            suggestion: "Lower the image-quality setting or use WebP.",
                            technicalDetails: cleanedDetails(quantize.standardError)
                        ))
                    }
                    return .failure(failure(for: quantize, tool: "PNG optimizer", sourceURL: sourceURL))
                }

                if let oxipng = try? bundledTool(named: "oxipng") {
                    let optimize = try runProcess(
                        executableURL: oxipng,
                        arguments: ["-o", oxiPNGLevel, "--strip", "safe", "--quiet", temporaryURL.path]
                    )
                    guard optimize.status == 0 else {
                        return .failure(failure(for: optimize, tool: "PNG optimizer", sourceURL: sourceURL))
                    }
                }
            }

            var optimizedSize = ((try? fileManager.attributesOfItem(atPath: temporaryURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            guard optimizedSize > 0 else {
                return .failure(ConversionFailure(
                    kind: .invalidOutput,
                    title: "Encoder produced no output",
                    message: "The converted copy of \(sourceURL.lastPathComponent) was empty.",
                    suggestion: "Check that the source opens normally, then try another format.",
                    technicalDetails: nil
                ))
            }

            if targetFormat == .pdf, originalSize > 0, optimizedSize >= originalSize {
                try fileManager.removeItem(at: temporaryURL)
                try fileManager.copyItem(at: sourceURL, to: temporaryURL)
                optimizedSize = originalSize
            }

            outputLock.lock()
            do {
                if fileManager.fileExists(atPath: finalURL.path) {
                    try fileManager.removeItem(at: finalURL)
                }
                try fileManager.moveItem(at: temporaryURL, to: finalURL)
            } catch {
                outputLock.unlock()
                throw error
            }
            outputLock.unlock()
            shouldRemoveTemporaryFile = false
            shouldRemoveOutputReservation = false
            return .success(ConversionOutput(
                originalSize: originalSize,
                optimizedSize: optimizedSize,
                outputURL: finalURL
            ))
        } catch let failure as ConversionFailure {
            return .failure(failure)
        } catch {
            return .failure(ConversionFailure(
                kind: .unexpected,
                title: "Conversion could not finish",
                message: "Burrito could not finish \(sourceURL.lastPathComponent).",
                suggestion: "Check the source file and available disk space, then try again.",
                technicalDetails: error.localizedDescription
            ))
        }
    }

    private func reserveOutputURL(in directory: URL, baseName: String, extension fileExtension: String) -> URL {
        outputLock.lock()
        defer { outputLock.unlock() }

        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path)
                || !FileManager.default.createFile(atPath: candidate.path, contents: Data()) {
            candidate = directory.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }

    private func bundledTool(named name: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionFailure(
                kind: .toolUnavailable,
                title: "Conversion tool is missing",
                message: "The bundled \(name) tool could not be found.",
                suggestion: "Reinstall Burrito and try again.",
                technicalDetails: name
            )
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ConversionFailure(
                kind: .toolUnavailable,
                title: "Conversion tool cannot run",
                message: "macOS blocked the bundled \(name) tool.",
                suggestion: "Reinstall Burrito from a trusted build.",
                technicalDetails: url.path
            )
        }
        return url
    }

    private func runProcess(executableURL: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        let processID = ObjectIdentifier(process)
        processLock.lock()
        activeProcesses[processID] = process
        processLock.unlock()

        defer {
            processLock.lock()
            activeProcesses.removeValue(forKey: processID)
            processLock.unlock()
        }

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    private func failure(for command: CommandResult, tool: String, sourceURL: URL) -> ConversionFailure {
        let details = cleanedDetails(command.standardError)
        let lowercased = command.standardError.lowercased()

        if lowercased.contains("permission denied") || lowercased.contains("operation not permitted") {
            return ConversionFailure(
                kind: .permissionDenied,
                title: "Permission denied",
                message: "macOS blocked access while processing \(sourceURL.lastPathComponent).",
                suggestion: "Grant Burrito file access or move the source to another folder.",
                technicalDetails: details
            )
        }
        if lowercased.contains("no space left") || lowercased.contains("disk full") {
            return ConversionFailure(
                kind: .insufficientSpace,
                title: "Not enough disk space",
                message: "There is not enough room to finish \(sourceURL.lastPathComponent).",
                suggestion: "Free some disk space and retry.",
                technicalDetails: details
            )
        }
        if lowercased.contains("password") || lowercased.contains("encrypted") {
            return ConversionFailure(
                kind: .encoderRejected,
                title: "PDF is password protected",
                message: "Burrito cannot optimize \(sourceURL.lastPathComponent) without its password.",
                suggestion: "Save an unlocked copy of the PDF, then drop that copy into Burrito.",
                technicalDetails: details
            )
        }
        if lowercased.contains("signature") || lowercased.contains("signed document") {
            return ConversionFailure(
                kind: .encoderRejected,
                title: "PDF contains a digital signature",
                message: "Optimizing \(sourceURL.lastPathComponent) could invalidate its signature.",
                suggestion: "Keep the signed original or optimize an unsigned copy.",
                technicalDetails: details
            )
        }
        if lowercased.contains("invalid data") || lowercased.contains("corrupt") || lowercased.contains("cannot decode") {
            return ConversionFailure(
                kind: .encoderRejected,
                title: "File could not be decoded",
                message: "\(sourceURL.lastPathComponent) may be damaged or use an unsupported codec.",
                suggestion: "Open the file to verify it, or export it in a standard format first.",
                technicalDetails: details
            )
        }
        return ConversionFailure(
            kind: .encoderRejected,
            title: "\(tool) rejected the file",
            message: "\(sourceURL.lastPathComponent) could not be optimized.",
            suggestion: "Try the other output format or adjust the quality setting.",
            technicalDetails: details ?? "Exit status \(command.status)"
        )
    }

    private func cleanedDetails(_ text: String) -> String? {
        let lines = text
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(4).joined(separator: " · ").prefix(600).description
    }
}
