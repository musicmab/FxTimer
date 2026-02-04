import SwiftUI

struct IntervalProgressBar: View {
    let minutes: Int
    let progress: Double        // 0.0‥1.0

    private var label: String {
        switch minutes {
        case 60:  return "1時間足"
        case 240: return "4時間足"
        case 480: return "8時間足"
        default:  return "\(minutes)分足"
        }
    }

    private var remainingSec: Int {
        Int((1.0 - progress) * Double(minutes) * 60.0)
    }

    private var barColor: Color {
        remainingSec <= 10 ? .red : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(barColor)
        }
    }
}
