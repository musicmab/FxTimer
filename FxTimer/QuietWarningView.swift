import SwiftUI

struct QuietWarningView: View {
    let text: String
    @State private var flash = false

    var body: some View {
        Text(text)
            .font(.title)
            .padding()
            .background(flash ? Color.red.opacity(0.8) : Color.red.opacity(0.3))
            .foregroundColor(.white)
            .cornerRadius(12)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                    flash.toggle()
                }
            }
    }
}
