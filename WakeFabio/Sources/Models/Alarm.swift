import Foundation

public enum Weekday: Int, Codable, CaseIterable, Identifiable, Comparable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7
    
    public var id: Int { rawValue }
    
    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    public var shortNamePt: String {
        switch self {
        case .sunday: return "Dom"
        case .monday: return "Seg"
        case .tuesday: return "Ter"
        case .wednesday: return "Qua"
        case .thursday: return "Qui"
        case .friday: return "Sex"
        case .saturday: return "Sáb"
        }
    }
    
    public var fullNamePt: String {
        switch self {
        case .sunday: return "Domingo"
        case .monday: return "Segunda-feira"
        case .tuesday: return "Terça-feira"
        case .wednesday: return "Quarta-feira"
        case .thursday: return "Quinta-feira"
        case .friday: return "Sexta-feira"
        case .saturday: return "Sábado"
        }
    }
}

public enum MissionType: String, Codable, CaseIterable, Identifiable {
    case barcode = "Código QR / Barras"
    case math = "Matemática"
    case typing = "Digitação"
    case memory = "Memória"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .barcode: return "qrcode.viewfinder"
        case .math: return "plus.slash.minus"
        case .typing: return "keyboard"
        case .memory: return "square.grid.3x3.fill"
        }
    }
    
    public var subtitle: String {
        switch self {
        case .barcode: return "Escaneie o código registado para desligar"
        case .math: return "Resolva problemas matemáticos"
        case .typing: return "Digite frases com precisão"
        case .memory: return "Memorize a sequência de blocos"
        }
    }
}

public enum MathDifficulty: Int, Codable, CaseIterable, Identifiable {
    case veryEasy = 1
    case easy = 2
    case medium = 3
    case hard = 4
    case extreme = 5
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .veryEasy: return "Muito Fácil (ex: 2 + 5)"
        case .easy: return "Fácil (ex: 23 + 45)"
        case .medium: return "Médio (ex: 12 × 14)"
        case .hard: return "Difícil (ex: (34 × 12) + 75)"
        case .extreme: return "Extremo (ex: (124 × 32) + 542)"
        }
    }
}

public struct Alarm: Identifiable, Codable, Equatable {
    public var id: UUID
    public var time: Date
    public var isEnabled: Bool
    public var label: String
    public var repeatDays: Set<Int> // 1=Dom, 2=Seg, ..., 7=Sab
    public var soundName: String
    
    // Configurações de Missões (QR Prioritário)
    public var missionType: MissionType
    public var registeredBarcode: String?
    public var mathDifficulty: MathDifficulty
    public var mathProblemsCount: Int
    public var memoryRoundsCount: Int
    public var memoryGridSize: Int
    
    // Wake Up Check Anti-Sono
    public var isWakeUpCheckEnabled: Bool
    public var wakeUpCheckDelayMinutes: Int
    public var wakeUpCheckCountdownSeconds: Int
    
    // Metadados
    public var createdAt: Date
    public var updatedAt: Date
    
    public init(
        id: UUID = UUID(),
        time: Date,
        isEnabled: Bool = false,
        label: String = "Alarme",
        repeatDays: Set<Int> = [],
        soundName: String = "loud1.mp3",
        missionType: MissionType = .barcode,
        registeredBarcode: String? = nil,
        mathDifficulty: MathDifficulty = .medium,
        mathProblemsCount: Int = 3,
        memoryRoundsCount: Int = 3,
        memoryGridSize: Int = 4,
        isWakeUpCheckEnabled: Bool = true,
        wakeUpCheckDelayMinutes: Int = 5,
        wakeUpCheckCountdownSeconds: Int = 100,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.time = time
        self.isEnabled = isEnabled
        self.label = label
        self.repeatDays = repeatDays
        self.soundName = soundName
        self.missionType = missionType
        self.registeredBarcode = registeredBarcode
        self.mathDifficulty = mathDifficulty
        self.mathProblemsCount = mathProblemsCount
        self.memoryRoundsCount = memoryRoundsCount
        self.memoryGridSize = memoryGridSize
        self.isWakeUpCheckEnabled = isWakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = wakeUpCheckDelayMinutes
        self.wakeUpCheckCountdownSeconds = wakeUpCheckCountdownSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    /// Calcula a próxima data de disparo a partir de uma data de referência e calendário especificado
    public func nextFireDate(after referenceDate: Date = Date(), calendar: Calendar = .current) -> Date {
        let targetHour = calendar.component(.hour, from: time)
        let targetMinute = calendar.component(.minute, from: time)
        
        var dateComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        dateComponents.hour = targetHour
        dateComponents.minute = targetMinute
        dateComponents.second = 0
        dateComponents.nanosecond = 0
        
        let sameDayCandidate = calendar.date(from: dateComponents) ?? referenceDate
        
        if repeatDays.isEmpty {
            // Alarme de disparo único (não repete)
            if sameDayCandidate > referenceDate {
                return sameDayCandidate
            } else {
                return calendar.date(byAdding: .day, value: 1, to: sameDayCandidate) ?? sameDayCandidate.addingTimeInterval(86400)
            }
        } else {
            // Alarme recorrente por dias da semana (1 = Dom ... 7 = Sáb)
            for dayOffset in 0..<7 {
                guard let candidateDate = calendar.date(byAdding: .day, value: dayOffset, to: sameDayCandidate) else { continue }
                let weekday = calendar.component(.weekday, from: candidateDate)
                
                if repeatDays.contains(weekday) {
                    if candidateDate > referenceDate {
                        return candidateDate
                    }
                }
            }
            // Caso caia exatamente no mesmo dia da próxima semana
            return calendar.date(byAdding: .day, value: 7, to: sameDayCandidate) ?? sameDayCandidate.addingTimeInterval(7 * 86400)
        }
    }
    
    /// Retorna uma descrição amigável dos dias de repetição
    public var repeatDaysSummaryPt: String {
        if repeatDays.isEmpty {
            return "Apenas uma vez"
        }
        if repeatDays.count == 7 {
            return "Todos os dias"
        }
        let weekdaysOnly: Set<Int> = [2, 3, 4, 5, 6]
        let weekendOnly: Set<Int> = [1, 7]
        if repeatDays == weekdaysOnly {
            return "Dias úteis (Seg-Sex)"
        }
        if repeatDays == weekendOnly {
            return "Fim de semana (Sáb-Dom)"
        }
        let sorted = repeatDays.compactMap { Weekday(rawValue: $0) }.sorted()
        return sorted.map { $0.shortNamePt }.joined(separator: ", ")
    }
}
