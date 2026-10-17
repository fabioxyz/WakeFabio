import SwiftUI
import Combine

struct MathMissionView: View {
    let difficulty: MathDifficulty
    let totalProblems: Int
    let onMissionCompleted: () -> Void
    
    @State private var currentProblemIndex: Int = 1
    @State private var currentProblem: MathProblem = MathMissionGenerator.generateProblem(difficulty: .medium)
    @State private var isErrorShaking: Bool = false
    @State private var feedbackText: String = ""
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 30) {
                // Barra de Progresso
                HStack {
                    Text("Questão \(currentProblemIndex)/\(totalProblems)")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Spacer()
                    Text("Nível: \(difficulty.title.components(separatedBy: " ").first ?? "")")
                        .font(.subheadline)
                        .padding(6)
                        .background(Color.red.opacity(0.3))
                        .cornerRadius(8)
                        .foregroundColor(.white)
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Expressão Matemática
                VStack(spacing: 12) {
                    Text("Resolva para desligar:")
                        .font(.title3)
                        .foregroundColor(.gray)
                    
                    Text(currentProblem.expression)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .scaleEffect(isErrorShaking ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.1).repeatCount(3, autoreverses: true), value: isErrorShaking)
                }
                
                if !feedbackText.isEmpty {
                    Text(feedbackText)
                        .foregroundColor(.red)
                        .font(.headline)
                }
                
                Spacer()
                
                // Opções de Resposta
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(currentProblem.choices, id: \.self) { choice in
                        Button(action: {
                            checkAnswer(choice)
                        }) {
                            Text("\(choice)")
                                .font(.title)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .frame(height: 75)
                                .background(Color.blue.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(16)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            currentProblem = MathMissionGenerator.generateProblem(difficulty: difficulty)
        }
    }
    
    private func checkAnswer(_ choice: Int) {
        if choice == currentProblem.answer {
            AudioAlarmManager.shared.playSuccessChime()
            if currentProblemIndex >= totalProblems {
                onMissionCompleted()
            } else {
                currentProblemIndex += 1
                currentProblem = MathMissionGenerator.generateProblem(difficulty: difficulty)
                feedbackText = ""
            }
        } else {
            isErrorShaking.toggle()
            feedbackText = "Resposta incorreta! Tente novamente."
            AudioAlarmManager.shared.playFailureChime()
        }
    }
}
