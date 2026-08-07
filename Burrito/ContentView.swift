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
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.58))
        }
        .burritoGlass()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.16), value: showSettings)
    }
}

extension View {
    @ViewBuilder
    func burritoGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                Glass.regular.tint(.black.opacity(0.42)),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        } else {
            background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.42))
                    }
            }
        }
    }
}
