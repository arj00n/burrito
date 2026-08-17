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

    var body: some View {
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
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
