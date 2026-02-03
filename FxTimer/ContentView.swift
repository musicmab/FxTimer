import SwiftUI

struct ContentView: View {
    @EnvironmentObject var mgr: IntervalManager

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    VStack(alignment: .center, spacing: 8) {
                        Text(mgr.clockText)
                            .font(.system(size: 60, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.top, 20)
                            .frame(maxWidth: .infinity, alignment: .center)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(mgr.progress.keys.sorted(), id: \.self) { key in
                                if let p = mgr.progress[key] {
                                    IntervalProgressBar(minutes: key, progress: p)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    Spacer()

                    VStack(spacing: 16) {
                        VStack(spacing: 16) {
                            Button(mgr.isRunning ? "ストップ" : "スタート") {
                                if mgr.isRunning {
                                    mgr.stop()
                                } else {
                                    mgr.start()
                                    mgr.playFeedback(text: "スタート")
                                }
                            }
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity)
                            .background(mgr.isRunning ? Color.red : Color.blue)
                            .foregroundColor(.white)
                            .font(.title2)
                            .clipShape(Capsule())

                            NavigationLink("設定", destination: SettingsView())
                                .font(.headline)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 40)
                }

                Group {
                    if mgr.status.starts(with: " ") {
                        Text(mgr.status.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 200, weight: .bold, design: .monospaced))
                        + Text(" ")
                            .font(.system(size: 200, weight: .bold, design: .monospaced))
                    } else {
                        Text(mgr.status)
                            .font(.system(size: 50, weight: .medium, design: .monospaced))
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.top, 60)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("FX Interval")
        }
    }
}
