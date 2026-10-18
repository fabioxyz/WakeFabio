import SwiftUI
import Combine

public struct MainAlarmListView: View {
    @ObservedObject var store: AlarmStore = .shared
    @ObservedObject var scheduler: AlarmSchedulerCoordinator = .shared
    @ObservedObject var audioManager: AudioAlarmManager = .shared
    @Environment(\.scenePhase) var scenePhase
    
    @State private var editingAlarm: Alarm? = nil
    @State private var isCreatingNewAlarm: Bool = false
    @State private var activeRingingOccurrence: OccurrenceState? = nil
    @State private var activeWakeUpCheckOccurrence: OccurrenceState? = nil
    @State private var testOccurrence: OccurrenceState? = nil
    @State private var alertErrorMessage: String? = nil
    @State private var isTransitioning: Bool = false
    @State private var wakeUpCheckFutureTask: Task<Void, Never>? = nil
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Banner de permissão se negada
                    if NativeAlarmKitService.shared.authorizationStatus == .denied {
                        HStack {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundColor(.red)
                            Text("Permissão AlarmKit negada. Ative nas Definições para alarmes tocarem.")
                                .font(.caption)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding()
                        .background(Color.red.opacity(0.15))
                    }
                    
                    if let error = scheduler.activeErrorMessage ?? alertErrorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.primary)
                            Spacer()
                            Button("OK") {
                                scheduler.activeErrorMessage = nil
                                alertErrorMessage = nil
                            }
                            .font(.caption)
                            .bold()
                        }
                        .padding()
                        .background(Color.yellow.opacity(0.2))
                    }
                    
                    List {
                        ForEach(store.alarms) { alarm in
                            AlarmRowView(
                                alarm: alarm,
                                onToggle: { shouldEnable in
                                    handleToggle(alarm: alarm, shouldEnable: shouldEnable)
                                },
                                onSelect: {
                                    editingAlarm = alarm
                                }
                            )
                        }
                        .onDelete(perform: deleteAlarms)
                    }
                    .listStyle(InsetGroupedListStyle())
                    .disabled(isTransitioning)
                    
                    // Botão de Teste Rápido
                    VStack {
                        Button(action: {
                            triggerImmediateTest()
                        }) {
                            Label("Testar Missão de Despertar", systemImage: "bell.badge.fill")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.red)
                                .cornerRadius(16)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        }
                        .disabled(isTransitioning || activeRingingOccurrence != nil || activeWakeUpCheckOccurrence != nil)
                        Text("Feito por Fábio, para Fábio")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 10)
                    }
                }
            }
            .navigationTitle("WakeFabio")
            .navigationBarItems(
                trailing: Button(action: {
                    isCreatingNewAlarm = true
                }) {
                    Image(systemName: "plus")
                        .font(.title2)
                }
                .disabled(isTransitioning)
            )
            .sheet(item: $editingAlarm) { alarm in
                AlarmEditView(alarm: alarm) { updatedAlarm in
                    try await scheduler.saveAlarm(updatedAlarm)
                }
            }
            .sheet(isPresented: $isCreatingNewAlarm) {
                AlarmEditView(alarm: nil) { newAlarm in
                    try await scheduler.saveAlarm(newAlarm)
                }
            }
            // Modo Teste Isolado: cover própria, sem store, sem scheduler
            .fullScreenCover(item: $testOccurrence) { occurrence in
                AlarmRingMissionContainerView(occurrence: occurrence) {
                    audioManager.stopAlarm()
                    testOccurrence = nil
                }
            }
            // Missão Real: só fecha e áudio stop APÓS scheduler.completeMission com sucesso
            .fullScreenCover(item: $activeRingingOccurrence) { occurrence in
                RealMissionCoverHostView(
                    occurrence: occurrence,
                    onSuccess: {
                        audioManager.stopAlarm()
                        activeRingingOccurrence = nil
                        checkPendingTransitions()
                    }
                )
            }
            // Wake Up Check Real: só fecha após confirmação no scheduler com sucesso
            .fullScreenCover(item: $activeWakeUpCheckOccurrence) { occurrence in
                WakeUpCheckHostView(
                    occurrence: occurrence,
                    onConfirmed: {
                        activeWakeUpCheckOccurrence = nil
                        checkPendingTransitions()
                    },
                    onFailed: {
                        activeWakeUpCheckOccurrence = nil
                        audioManager.playAlarm(soundName: occurrence.soundName)
                        activeRingingOccurrence = occurrence
                    }
                )
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                scheduler.reconcileInForeground()
                checkPendingTransitions()
            }
        }
        .onAppear {
            scheduler.reconcileInForeground()
            checkPendingTransitions()
        }
        // @Published emits in willSet, inside the store's serial transaction.
        // Dispatch the read until the transaction has returned to avoid reentry.
        .onReceive(store.$occurrences.receive(on: DispatchQueue.main)) { _ in
            checkPendingTransitions()
        }
        .onDisappear {
            wakeUpCheckFutureTask?.cancel()
            wakeUpCheckFutureTask = nil
        }
    }
    
    private func handleToggle(alarm: Alarm, shouldEnable: Bool) {
        isTransitioning = true
        Task {
            defer { isTransitioning = false }
            do {
                if shouldEnable {
                    try await scheduler.enableAlarm(alarm)
                } else {
                    try await scheduler.disableAlarm(alarm)
                }
            } catch {
                alertErrorMessage = error.localizedDescription
            }
        }
    }
    
    private func deleteAlarms(at offsets: IndexSet) {
        for index in offsets {
            guard index < store.alarms.count else { continue }
            let alarm = store.alarms[index]
            isTransitioning = true
            Task {
                defer { isTransitioning = false }
                do {
                    try await scheduler.deleteAlarm(id: alarm.id)
                } catch {
                    alertErrorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func triggerImmediateTest() {
        guard let firstAlarm = store.alarms.first else {
            alertErrorMessage = "Nenhum alarme configurado para testar."
            return
        }
        
        if firstAlarm.missionType == .barcode {
            guard let code = firstAlarm.registeredBarcode, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                alertErrorMessage = "Não é possível testar: o alarme selecionado não possui um Código QR / Barras de referência registado."
                return
            }
        }
        
        let testOcc = OccurrenceState(
            id: UUID(),
            alarmId: firstAlarm.id,
            scheduledFireDate: Date(),
            missionType: firstAlarm.missionType,
            registeredBarcode: firstAlarm.registeredBarcode,
            mathDifficulty: firstAlarm.mathDifficulty,
            mathProblemsCount: firstAlarm.mathProblemsCount,
            soundName: firstAlarm.soundName,
            status: .ringing
        )
        // Isolamento total do teste: NUNCA salvar na store nem agendar no SO
        audioManager.playAlarm(soundName: firstAlarm.soundName)
        testOccurrence = testOcc
    }
    
    private func checkPendingTransitions() {
        // Uma cover real por vez, sem competir com teste
        guard testOccurrence == nil else { return }
        
        if let missionOcc = store.getPendingMissionOccurrence() {
            wakeUpCheckFutureTask?.cancel()
            wakeUpCheckFutureTask = nil
            if activeWakeUpCheckOccurrence != nil {
                activeWakeUpCheckOccurrence = nil
            }
            if activeRingingOccurrence == nil {
                activeRingingOccurrence = missionOcc
                audioManager.playAlarm(soundName: missionOcc.soundName)
            }
        } else if let checkOcc = store.getPendingWakeUpCheckOccurrence() {
            let now = Date()
            let checkAt = checkOcc.wakeUpCheckAt ?? checkOcc.scheduledFireDate
            if now >= checkAt {
                wakeUpCheckFutureTask?.cancel()
                wakeUpCheckFutureTask = nil
                if activeRingingOccurrence == nil && activeWakeUpCheckOccurrence == nil {
                    activeWakeUpCheckOccurrence = checkOcc
                }
            } else {
                // Reavalia no checkAt exato via Task UI cancelável
                let waitSeconds = checkAt.timeIntervalSince(now)
                wakeUpCheckFutureTask?.cancel()
                wakeUpCheckFutureTask = Task { @MainActor in
                    if waitSeconds > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    }
                    guard !Task.isCancelled else { return }
                    checkPendingTransitions()
                }
            }
        }
    }
}

// MARK: - Host de Missão Real com Tratamento de Erro e Retry

public struct RealMissionCoverHostView: View {
    let occurrence: OccurrenceState
    let onSuccess: () -> Void
    
    @ObservedObject var scheduler: AlarmSchedulerCoordinator = .shared
    @State private var missionError: String? = nil
    @State private var isCompleting: Bool = false
    @State private var missionViewId: UUID = UUID()
    
    public var body: some View {
        ZStack {
            AlarmRingMissionContainerView(occurrence: occurrence) {
                completeMissionAction()
            }
            .id(missionViewId)
            .disabled(isCompleting)
            
            if isCompleting {
                Color.black.opacity(0.6).ignoresSafeArea()
                ProgressView("A registar conclusão da missão...")
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .foregroundColor(.white)
            }
        }
        .alert(isPresented: Binding(
            get: { missionError != nil },
            set: { if !$0 { missionError = nil } }
        )) {
            Alert(
                title: Text("Falha ao Concluir Missão"),
                message: Text(missionError ?? "Ocorreu um erro no agendamento."),
                primaryButton: .default(Text("Tentar Novamente")) {
                    missionError = nil
                    completeMissionAction()
                },
                secondaryButton: .cancel(Text("Reiniciar Leitor")) {
                    missionError = nil
                    missionViewId = UUID()
                }
            )
        }
    }
    
    private func completeMissionAction() {
        guard !isCompleting else { return }
        isCompleting = true
        Task {
            do {
                try await scheduler.completeMission(for: occurrence.id)
                isCompleting = false
                onSuccess()
            } catch {
                isCompleting = false
                missionError = error.localizedDescription
            }
        }
    }
}

// MARK: - Host de Wake Up Check com Tratamento de Erro e Transição Desativada

public struct WakeUpCheckHostView: View {
    let occurrence: OccurrenceState
    let onConfirmed: () -> Void
    let onFailed: () -> Void
    
    @ObservedObject var scheduler: AlarmSchedulerCoordinator = .shared
    @State private var checkError: String? = nil
    @State private var isConfirming: Bool = false
    
    public var body: some View {
        ZStack {
            WakeUpCheckView(
                occurrenceId: occurrence.id,
                deadline: occurrence.wakeUpCheckDeadline ?? Date().addingTimeInterval(100),
                onConfirmedAwake: {
                    confirmAction()
                },
                onFailedToConfirm: {
                    guard !isConfirming else { return }
                    scheduler.failWakeUpCheck(for: occurrence.id)
                    onFailed()
                }
            )
            .disabled(isConfirming)
            
            if isConfirming {
                Color.black.opacity(0.6).ignoresSafeArea()
                ProgressView("A confirmar despertar...")
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .foregroundColor(.white)
            }
        }
        .alert(isPresented: Binding(
            get: { checkError != nil },
            set: { if !$0 { checkError = nil } }
        )) {
            Alert(
                title: Text("Falha no Wake Up Check"),
                message: Text(checkError ?? "Ocorreu um erro ao confirmar."),
                primaryButton: .default(Text("Tentar Novamente")) {
                    checkError = nil
                    confirmAction()
                },
                secondaryButton: .cancel(Text("OK")) {
                    checkError = nil
                }
            )
        }
    }
    
    private func confirmAction() {
        guard !isConfirming else { return }
        isConfirming = true
        Task {
            do {
                try await scheduler.confirmWakeUpCheck(for: occurrence.id)
                isConfirming = false
                onConfirmed()
            } catch {
                isConfirming = false
                checkError = error.localizedDescription
            }
        }
    }
}

public struct AlarmRowView: View {
    let alarm: Alarm
    let onToggle: (Bool) -> Void
    let onSelect: () -> Void
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }
    
    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(timeFormatter.string(from: alarm.time))
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(alarm.isEnabled ? .primary : .secondary)
                
                HStack(spacing: 8) {
                    Image(systemName: alarm.missionType.iconName)
                        .foregroundColor(.blue)
                    Text(alarm.missionType.rawValue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if alarm.isWakeUpCheckEnabled {
                        Text("• Wake Up Check (\(alarm.wakeUpCheckDelayMinutes)m)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                
                Text(alarm.repeatDaysSummaryPt)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { alarm.isEnabled },
                set: { newValue in
                    onToggle(newValue)
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 8)
    }
}

public struct AlarmRingMissionContainerView: View {
    let occurrence: OccurrenceState
    let onCompleted: () -> Void
    
    public var body: some View {
        switch occurrence.missionType {
        case .barcode:
            if let target = occurrence.registeredBarcode, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                BarcodeScannerContainerView(mode: .validate(targetCode: target, onCodeMatched: onCompleted))
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.red)
                    Text("Código QR não registado")
                        .font(.title2)
                        .foregroundColor(.white)
                    Text("Não existe código de referência registado para este alarme.")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Button("Desligar Emergência") {
                        onCompleted()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        case .math:
            MathMissionView(
                difficulty: occurrence.mathDifficulty,
                totalProblems: occurrence.mathProblemsCount,
                onMissionCompleted: onCompleted
            )
        case .typing:
            TypingAndMemoryMissionView(mode: .typing, onMissionCompleted: onCompleted)
        case .memory:
            TypingAndMemoryMissionView(mode: .memory, onMissionCompleted: onCompleted)
        }
    }
}
