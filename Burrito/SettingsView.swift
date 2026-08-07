import SwiftUI

struct SettingsView: View {
    @Binding var showSettings: Bool

    @AppStorage("outputLocation") private var outputLocation = "optimizedFolder"
    @AppStorage("pdfTargetBytes") private var pdfTargetBytes = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with Back Button
            HStack {
                Button(action: { showSettings = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("Back")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))
                }
                .buttonStyle(.plain)
                
                Spacer()
                Text("Settings")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.22))
            
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("Save To")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Picker("", selection: $outputLocation) {
                        Text("Optimized Folder").tag("optimizedFolder")
                        Text("Beside Originals").tag("besideOriginals")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 142, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("PDF Target")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Picker("", selection: $pdfTargetBytes) {
                        Text("Automatic").tag(0)
                        Text("Under 500 KB").tag(480_000)
                        Text("Under 1 MB").tag(950_000)
                        Text("Under 2 MB").tag(1_900_000)
                        Text("Under 5 MB").tag(4_800_000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 142, alignment: .trailing)
                    .help("A fixed target may rasterize PDF pages and remove searchable text to meet the selected upload limit")
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Automatic Updates")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                        Text("On · checks daily")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.62))
                    }
                    Spacer()
                    Button("Check Now") {
                        NotificationCenter.default.post(name: .checkForBurritoUpdates, object: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
                }

            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            
            Spacer(minLength: 0)
        }
        .frame(width: 340, height: 180)
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }
}
