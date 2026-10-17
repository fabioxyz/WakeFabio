import Foundation

struct MathProblem {
    let expression: String
    let answer: Int
    let choices: [Int] // 4 alternativas (1 correta + 3 erradas parecidas)
}

struct MathMissionGenerator {
    static func generateProblem(difficulty: MathDifficulty) -> MathProblem {
        let answer: Int
        let expression: String
        
        switch difficulty {
        case .veryEasy:
            let a = Int.random(in: 2...9)
            let b = Int.random(in: 2...9)
            answer = a + b
            expression = "\(a) + \(b)"
            
        case .easy:
            let a = Int.random(in: 11...89)
            let b = Int.random(in: 11...89)
            if Bool.random() {
                answer = a + b
                expression = "\(a) + \(b)"
            } else {
                let high = max(a, b)
                let low = min(a, b)
                answer = high - low
                expression = "\(high) - \(low)"
            }
            
        case .medium:
            let a = Int.random(in: 11...25)
            let b = Int.random(in: 4...16)
            answer = a * b
            expression = "\(a) × \(b)"
            
        case .hard:
            let a = Int.random(in: 12...35)
            let b = Int.random(in: 11...29)
            let c = Int.random(in: 15...85)
            answer = (a * b) + c
            expression = "(\(a) × \(b)) + \(c)"
            
        case .extreme:
            let a = Int.random(in: 25...99)
            let b = Int.random(in: 21...75)
            let c = Int.random(in: 120...650)
            answer = (a * b) + c
            expression = "(\(a) × \(b)) + \(c)"
        }
        
        // Gerar 3 respostas falsas verossímeis
        var choicesSet = Set<Int>([answer])
        var attempts = 0
        while choicesSet.count < 4 && attempts < 20 {
            attempts += 1
            let offset = [-10, -2, -1, 1, 2, 10, 100].randomElement()!
            let fake = answer + offset
            if fake > 0 && fake != answer {
                choicesSet.insert(fake)
            }
        }
        
        return MathProblem(
            expression: expression,
            answer: answer,
            choices: Array(choicesSet).shuffled()
        )
    }
}
