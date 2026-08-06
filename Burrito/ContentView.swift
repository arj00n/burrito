import SwiftUI

struct ContentView: View {
    @State private var showSettings = false
    @StateObject private var processor = ImageProcessor()
    
    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(showSettings: $showSettings)
                    .transition(.opacity)
                    .zIndex(1)
            } else {
                DropZoneView(showSettings: $showSettings, processor: processor)
                    .transition(.opacity)
                    .zIndex(0)
            }
        }
        .frame(width: 340, height: 180)
        .burritoGlass(cornerRadius: 16, tint: .black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.16), value: showSettings)
    }
}

extension View {
    @ViewBuilder
    func burritoGlass(cornerRadius: CGFloat, tint: Color = .clear, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                Glass.regular.tint(tint).interactive(interactive),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint)
                    }
            }
        }
    }
}
