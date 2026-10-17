import SwiftUI

@main
struct WakeFabioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            MainAlarmListView()
                .onAppear {
                    // Inicializa listeners e permissões no primeiro launch
                    NotificationAlarmManager.shared.requestAuthorization { _ in }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private var alarmKitObserverTask: Task<Void, Never>?
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        _ = NotificationAlarmManager.shared
        _ = AudioAlarmManager.shared
        _ = AlarmStore.shared
        
        startAlarmKitObserver()
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        alarmKitObserverTask?.cancel()
        alarmKitObserverTask = nil
    }
    
    private func startAlarmKitObserver() {
        alarmKitObserverTask?.cancel()
        alarmKitObserverTask = NativeAlarmKitService.shared.startObservingAlarmUpdates { firedAlarmId in
            Task { @MainActor in
                let store = AlarmStore.shared
                let activeMatches = store.occurrences
                    .filter { occ in
                        (occ.primaryAlarmKitId == firedAlarmId ||
                         occ.rescueAlarmKitId == firedAlarmId ||
                         occ.wakeUpCheckRescueId == firedAlarmId ||
                         occ.id == firedAlarmId) &&
                        occ.status != .completed &&
                        occ.status != .cancelled &&
                        occ.status != .failed &&
                        occ.status != .preparing && occ.status != .cleanupPending &&
                        occ.scheduledFireDate <= Date()
                    }
                    .sorted { $0.scheduledFireDate > $1.scheduledFireDate }
                
                if let matched = activeMatches.first {
                    if firedAlarmId == matched.wakeUpCheckRescueId {
                        if matched.status != .ringing {
                            try? store.updateOccurrenceStatus(id: matched.id, status: .ringing)
                        }
                    } else {
                        if matched.status != .missionPending && matched.status != .wakeUpCheckPending {
                            try? store.updateOccurrenceStatus(id: matched.id, status: .missionPending)
                        }
                    }
                }
                AlarmSchedulerCoordinator.shared.reconcileInForeground()
            }
        }
    }
}
