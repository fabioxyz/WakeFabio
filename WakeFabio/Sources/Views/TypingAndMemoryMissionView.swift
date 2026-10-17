import SwiftUI

struct TypingAndMemoryMissionView: View {
    let mode: MissionType // .typing ou .memory
    let onMissionCompleted: () -> Void
    
    // Modo Digitação
    @State private var motivationalQuotes = [
        "Hoje será um dia produtivo e cheio de conquistas.",
        "A disciplina de acordar cedo constrói o meu futuro.",
        "Vou levantar da cama agora e fazer acontecer."
    ]
    @State private var currentQuoteIndex = 0
    @State private var typedText: String = ""
    
    // Modo Memória (Blocos 4x4)
    @State private var targetTiles: Set<Int> = []
    @State private var selectedTiles: Set<Int> = []
    @State private var isShowingPreview: Bool = true
    @State private var currentRound: Int = 1
    @State private var totalRounds: Int = 3
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if mode == .typing {
                typingBody
            } else {
                memoryBody
            }
        }
        .onAppear {
            if mode == .memory {
                generateMemoryRound()
            }
        }
    }
    
    // MARK: - Digitação
    var typingBody: some View {
        VStack(spacing: 24) {
            Text("Missão de Digitação")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Digite a frase exatamente igual para acordar a mente:")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            Text("\"\(motivationalQuotes[currentQuoteIndex])\"")
                .font(.headline)
                .italic()
                .padding()
                .background(Color.blue.opacity(0.2))
                .cornerRadius(12)
                .foregroundColor(.yellow)
                .padding(.horizontal)
            
            TextEditor(text: $typedText)
                .frame(height: 120)
                .padding(8)
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)
                .foregroundColor(.white)
                .padding(.horizontal)
            
            Button(action: {
                if typedText.trimmingCharacters(in: .whitespacesAndNewlines) == motivationalQuotes[currentQuoteIndex] {
                    AudioAlarmManager.shared.playSuccessChime()
                    onMissionCompleted()
                } else {
                    AudioAlarmManager.shared.playFailureChime()
                }
            }) {
                Text("VERIFICAR FRASE")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 55)
                    .background(Color.green)
                    .cornerRadius(16)
                    .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding(.top, 40)
    }
    
    // MARK: - Memória (Blocos)
    var memoryBody: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Jogo da Memória (Rodada \(currentRound)/\(totalRounds))")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal)
            
            Text(isShowingPreview ? "Memorize os blocos iluminados!" : "Toque nos blocos que estavam acesos:")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            // Grid 4x4 de Blocos
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(0..<16, id: \.self) { index in
                    Button(action: {
                        tileTapped(index)
                    }) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(tileColor(for: index))
                            .frame(height: 70)
                    }
                    .disabled(isShowingPreview)
                }
            }
            .padding(.horizontal, 24)
            
            Spacer()
        }
        .padding(.top, 40)
    }
    
    private func tileColor(for index: Int) -> Color {
        if isShowingPreview {
            return targetTiles.contains(index) ? Color.yellow : Color.gray.opacity(0.3)
        } else {
            return selectedTiles.contains(index) ? Color.blue : Color.gray.opacity(0.3)
        }
    }
    
    private func generateMemoryRound() {
        isShowingPreview = true
        selectedTiles.removeAll()
        targetTiles.removeAll()
        
        // Sorteia 5 blocos
        while targetTiles.count < 5 {
            targetTiles.insert(Int.random(in: 0..<16))
        }
        
        // Mostra por 2 segundos e esconde
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            isShowingPreview = false
        }
    }
    
    private func tileTapped(_ index: Int) {
        if targetTiles.contains(index) {
            selectedTiles.insert(index)
            if selectedTiles == targetTiles {
                AudioAlarmManager.shared.playSuccessChime()
                if currentRound >= totalRounds {
                    onMissionCompleted()
                } else {
                    currentRound += 1
                    generateMemoryRound()
                }
            }
        } else {
            // Errou o bloco
            AudioAlarmManager.shared.playFailureChime()
            generateMemoryRound()
        }
    }
}
