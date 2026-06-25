import SwiftUI

struct SignalMeterView: View {
    var level: Double = 0.0   // 0.0 – 1.0, will be driven by RTL-SDR later

    private let barCount = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signal").font(.headline)
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let threshold = Double(index) / Double(barCount)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(for: threshold, active: level > threshold))
                        .frame(height: 20)
                }
            }
            .animation(.linear(duration: 0.1), value: level)
        }
    }

    private func barColor(for threshold: Double, active: Bool) -> Color {
        guard active else { return Color.secondary.opacity(0.2) }
        switch threshold {
        case ..<0.6:  return .green
        case ..<0.85: return .yellow
        default:      return .red
        }
    }
}

#Preview {
    SignalMeterView(level: 0.65)
        .padding()
        .frame(width: 300)
}
