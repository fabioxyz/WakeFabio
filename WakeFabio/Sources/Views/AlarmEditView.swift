import SwiftUI

public struct AlarmEditView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var store: AlarmStore = .shared
    @ObservedObject var audioManager: AudioAlarmManager = .shared
    @ObservedObject var scheduler: AlarmSchedulerCoordinator = .shared
    
    let alarmToEdit: Alarm?
    let onSave: (Alarm) async throws -> Void
    @State private var draftID: UUID
    @State private var isSaving = false
    
    @State private var time: Date
    @State private var label: String
    @State private var isEnabled: Bool
    @State private var repeatDays: Set<Int>
    @State private var soundName: String
    
    // Missão
    @State private var missionType: MissionType
    @State private var registeredBarcode: String?
    @State private var mathDifficulty: MathDifficulty
    @State private var mathProblemsCount: Int
    @State private var memoryRoundsCount: Int
    
    // Wake Up Check
    @State private var isWakeUpCheckEnabled: Bool
    @State private var wakeUpCheckDelayMinutes: Int
    @State private var wakeUpCheckCountdownSeconds: Int
    
    // Modais do Scanner
    @State private var isRegisteringBarcode: Bool = false
    @State private var isTestingBarcode: Bool = false
    @State private var validationErrorMessage: String? = nil
    
    public init(alarm: Alarm? = nil, onSave: @escaping (Alarm) async throws -> Void) {
        self.alarmToEdit = alarm
        self.onSave = onSave
        
        let initial = alarm ?? Alarm(
            time: Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date(),
            isEnabled: false,
            label: "Alarme",
            repeatDays: [2, 3, 4, 5, 6],
            soundName: "loud1.mp3",
            missionType: .barcode,
            registeredBarcode: nil
        )
        
        self._time = State(initialValue: initial.time)
        self._draftID = State(initialValue: initial.id)
        self._label = State(initialValue: initial.label)
        self._isEnabled = State(initialValue: initial.isEnabled)
        self._repeatDays = State(initialValue: initial.repeatDays)
        self._soundName = State(initialValue: initial.soundName)
        self._missionType = State(initialValue: initial.missionType)
        self._registeredBarcode = State(initialValue: initial.registeredBarcode)
        self._mathDifficulty = State(initialValue: initial.mathDifficulty)
        self._mathProblemsCount = State(initialValue: initial.mathProblemsCount)
        self._memoryRoundsCount = State(initialValue: initial.memoryRoundsCount)
        self._isWakeUpCheckEnabled = State(initialValue: initial.isWakeUpCheckEnabled)
        self._wakeUpCheckDelayMinutes = State(initialValue: initial.wakeUpCheckDelayMinutes)
        self._wakeUpCheckCountdownSeconds = State(initialValue: initial.wakeUpCheckCountdownSeconds)
    }
    
    public var body: some View {
        NavigationView {
            Form {
                // MARK: - Horário e Etiqueta
                Section(header: Text("Horário")) {
                    DatePicker("Hora do Alarme", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(WheelDatePickerStyle())
                        .labelsHidden()
                    
                    TextField("Nome do Alarme", text: $label)
                }
                
                // MARK: - Dias de Repetição
                Section(header: Text("Repetição Semanal")) {
                    HStack(spacing: 6) {
                        ForEach(Weekday.allCases) { weekday in
                            let isSelected = repeatDays.contains(weekday.rawValue)
                            Button(action: {
                                toggleWeekday(weekday.rawValue)
                            }) {
                                Text(weekday.shortNamePt)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(isSelected ? Color.blue : Color(UIColor.secondarySystemFill))
                                    .foregroundColor(isSelected ? .white : .primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // MARK: - Missão de Despertar (QR Prioritário)
                Section(header: Text("Missão de Despertar (Anti-Soneca)")) {
                    Picker("Tipo de Missão", selection: $missionType) {
                        ForEach(MissionType.allCases) { type in
                            Label(type.rawValue, systemImage: type.iconName)
                                .tag(type)
                        }
                    }
                    
                    if missionType == .barcode {
                        qrMissionConfigurationSection
                    } else if missionType == .math {
                        mathMissionConfigurationSection
                    }
                }
                
                // MARK: - Seleção de Toque
                Section(header: Text("Toque do Alarme")) {
                    ForEach(AudioAlarmManager.availableSounds, id: \.name) { item in
                        HStack {
                            Text(item.title)
                                .foregroundColor(soundName == item.name ? .blue : .primary)
                            Spacer()
                            if soundName == item.name {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                            Button(action: {
                                audioManager.playPreview(soundName: item.name)
                            }) {
                                Image(systemName: audioManager.isPreviewPlaying && audioManager.currentlyPreviewedSound == item.name ? "stop.circle.fill" : "play.circle")
                                    .font(.title3)
                                    .foregroundColor(.orange)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            soundName = item.name
                        }
                    }
                }
                
                // MARK: - Wake Up Check
                Section(
                    header: Text("Checagem de Despertar (Wake Up Check)"),
                    footer: Text("Após resolver a missão, o app verificará se você não voltou a dormir. Se não responder no tempo estipulado, um alarme de emergência tocará.")
                ) {
                    Toggle("Ativar Wake Up Check", isOn: $isWakeUpCheckEnabled)
                    
                    if isWakeUpCheckEnabled {
                        Stepper("Atraso: \(wakeUpCheckDelayMinutes) min após missão", value: $wakeUpCheckDelayMinutes, in: 1...30)
                        Stepper("Tempo para confirmar: \(wakeUpCheckCountdownSeconds)s", value: $wakeUpCheckCountdownSeconds, in: 30...300, step: 10)
                    }
                }
                
                if let error = validationErrorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle(alarmToEdit == nil ? "Novo Alarme" : "Editar Alarme")
            .navigationBarItems(
                leading: Button("Cancelar") {
                    audioManager.stopPreview()
                    presentationMode.wrappedValue.dismiss()
                },
                trailing: Button("Guardar") {
                    saveAlarm()
                }
                .fontWeight(.bold)
            )
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .fullScreenCover(isPresented: $isRegisteringBarcode) {
                BarcodeScannerContainerView(mode: .register(onCodeScanned: { code in
                    self.registeredBarcode = code
                    self.validationErrorMessage = nil
                    self.isRegisteringBarcode = false
                }))
            }
            .fullScreenCover(isPresented: $isTestingBarcode) {
                if let target = registeredBarcode {
                    BarcodeScannerContainerView(mode: .test(targetCode: target, onDismiss: {
                        self.isTestingBarcode = false
                    }))
                }
            }
            .onDisappear {
                audioManager.stopPreview()
            }
        }
    }
    
    // MARK: - Subviews de Missão
    
    private var qrMissionConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let code = registeredBarcode, !code.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("Código Registado com Sucesso")
                            .font(.headline)
                    }
                    Text("Valor: \(code)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
                
                HStack(spacing: 12) {
                    Button(action: {
                        isTestingBarcode = true
                    }) {
                        Label("Testar Leitura", systemImage: "qrcode")
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    
                    Button(action: {
                        isRegisteringBarcode = true
                    }) {
                        Label("Substituir Código", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(8)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Nenhum código registado")
                            .font(.headline)
                    }
                    Text("Escaneie um produto distante da cama (ex: pasta de dentes no WC) para desativar o alarme.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        isRegisteringBarcode = true
                    }) {
                        Label("Escanear e Registar Código Agora", systemImage: "camera.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                .padding(.vertical, 6)
            }
        }
    }
    
    private var mathMissionConfigurationSection: some View {
        VStack(spacing: 8) {
            Picker("Dificuldade", selection: $mathDifficulty) {
                ForEach(MathDifficulty.allCases) { diff in
                    Text(diff.title).tag(diff)
                }
            }
            Stepper("Problemas: \(mathProblemsCount)", value: $mathProblemsCount, in: 1...10)
        }
    }
    
    private func toggleWeekday(_ day: Int) {
        if repeatDays.contains(day) {
            repeatDays.remove(day)
        } else {
            repeatDays.insert(day)
        }
    }
    
    private func saveAlarm() {
        guard !isSaving else { return }
        audioManager.stopPreview()
        
        // Validação: Se a missão for QR mas não houver código
        if missionType == .barcode {
            if registeredBarcode == nil || registeredBarcode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                validationErrorMessage = "Atenção: É obrigatório escanear e registar um código QR/Barras antes de salvar com esta missão."
                return
            }
        }
        
        var updated = alarmToEdit ?? Alarm(time: time)
        updated.id = draftID
        updated.isEnabled = isEnabled
        updated.time = time
        updated.label = label.isEmpty ? "Alarme" : label
        updated.repeatDays = repeatDays
        updated.soundName = soundName
        updated.missionType = missionType
        updated.registeredBarcode = registeredBarcode
        updated.mathDifficulty = mathDifficulty
        updated.mathProblemsCount = mathProblemsCount
        updated.memoryRoundsCount = memoryRoundsCount
        updated.isWakeUpCheckEnabled = isWakeUpCheckEnabled
        updated.wakeUpCheckDelayMinutes = wakeUpCheckDelayMinutes
        updated.wakeUpCheckCountdownSeconds = wakeUpCheckCountdownSeconds
        
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await onSave(updated)
                presentationMode.wrappedValue.dismiss()
            } catch {
                // Keep the draft and editor open for retry.
                validationErrorMessage = error.localizedDescription
            }
        }
    }
}
