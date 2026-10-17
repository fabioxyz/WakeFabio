import SwiftUI
import Combine

public struct WakeUpCheckView: View {
    let occurrenceId: UUID
    let deadline: Date
    let onConfirmedAwake: () -> Void
    let onFailedToConfirm: () -> Void
    
    @State private var remainingSeconds: Int = 100
    @State private var totalSeconds: Int = 100
    @State private var timerSubscription: AnyCancellable?
    
    public init(
        occurrenceId: UUID,
        deadline: Date,
        onConfirmedAwake: @escaping () -> Void,
        onFailedToConfirm: @escaping () -> Void
    ) {
        self.occurrenceId = occurrenceId
        self.deadline = deadline
        self.onConfirmedAwake = onConfirmedAwake
        self.onFailedToConfirm = onFailedToConfirm
    }
    
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 28) {
                Spacer()
                
                Image(systemName: "eyes.inverse")
                    .font(.system(size: 70))
                    .foregroundColor(.yellow)
                
                Text("Checagem de Despertar")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Confirme que continua acordado antes que o alarme de resgate toque no volume máximo!")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.gray)
                    .padding(.horizontal, 28)
                
                // Indicador circular baseado no tempo absoluto
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 12)
                        .frame(width: 180, height: 180)
                    
                    Circle()
                        .trim(from: 0, to: totalSeconds > 0 ? CGFloat(remainingSeconds) / CGFloat(totalSeconds) : 0)
                        .stroke(
                            remainingSeconds < 20 ? Color.red : (remainingSeconds < 50 ? Color.orange : Color.green),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 180, height: 180)
                        .animation(.linear(duration: 0.5), value: remainingSeconds)
                    
                    VStack(spacing: 4) {
                        Text("\(remainingSeconds)s")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("restantes")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding()
                
                Spacer()
                
                Button(action: {
                    AudioAlarmManager.shared.playSuccessChime()
                    onConfirmedAwake()
                }) {
                    Text("ESTOU ACORDADO! ☀️")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(Color.yellow)
                        .cornerRadius(18)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            updateRemainingSeconds()
            startClockTicker()
        }
        .onDisappear {
            timerSubscription?.cancel()
        }
    }
    
    private func updateRemainingSeconds() {
        let diff = Int(deadline.timeIntervalSinceNow)
        if totalSeconds == 100 && diff > 100 {
            totalSeconds = diff
        }
        remainingSeconds = max(0, diff)
        
        if remainingSeconds <= 0 {
            timerSubscription?.cancel()
            onFailedToConfirm()
        }
    }
    
    private func startClockTicker() {
        timerSubscription = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                self.updateRemainingSeconds()
            }
    }
}
