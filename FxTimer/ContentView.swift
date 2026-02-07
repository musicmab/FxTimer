import SwiftUI

struct ContentView: View {
    @EnvironmentObject var mgr: IntervalManager
    @State private var isFlashingWarning = false

    var body: some View {
        NavigationStack {
            ZStack {
                //──────────────── レイアウト土台 ────────────────
                VStack {
                    //── ❶ 時計 ＋ プログレスバー（常に最上部） ──
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

                    //── ❸ ボタン ＋ 設定リンク（常に最下部） ─────
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
                    .padding(.bottom, 40)
                }

                //──────────────── カウントダウン ───────────────
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
            .overlay(alignment: .top) {
                if !mgr.warningText.isEmpty {
                    Text(mgr.warningText)
                        .font(.system(size: 24, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(Color.red.opacity(0.9))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 6)
                        .padding(.top, 10)
                        .opacity(isFlashingWarning ? 1 : 0.2)
                        .onAppear { startWarningFlash() }
                        .onChange(of: mgr.warningText) { _, newValue in
                            if newValue.isEmpty {
                                isFlashingWarning = false
                            } else {
                                startWarningFlash()
                            }
                        }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("FX Interval")
        }
    }

    private func startWarningFlash() {
        isFlashingWarning = false
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            isFlashingWarning = true
        }
    }
}
