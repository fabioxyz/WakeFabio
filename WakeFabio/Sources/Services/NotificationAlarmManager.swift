import Foundation
import UserNotifications

public final class NotificationAlarmManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationAlarmManager()
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    /// Solicita autorização padrão de notificações locais (sem presumir critical-alert restrito)
    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[Notifications] Erro ao pedir autorização: \(error)")
            }
            completion(granted)
        }
    }
    
    /// Agenda notificação complementar padrão para o Wake Up Check (disparada no horário checkAt)
    public func scheduleWakeUpCheckNotification(occurrenceId: UUID, alarmId: UUID, fireDate: Date) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "👀 Wake Up Check: WakeFabio"
        content.body = "Confirme que continua acordado antes que o alarme de resgate toque!"
        content.sound = UNNotificationSound.default
        content.userInfo = [
            "route": "wakeUpCheck",
            "occurrenceId": occurrenceId.uuidString,
            "alarmId": alarmId.uuidString
        ]
        
        let interval = max(1.0, fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: "wakefabio_check_\(occurrenceId.uuidString)",
            content: content,
            trigger: trigger
        )
        
        center.add(request) { error in
            if let error = error {
                print("[Notifications] Erro ao agendar notificação de Wake Up Check: \(error)")
            } else {
                print("[Notifications] Notificação de Wake Up Check agendada para daqui a \(Int(interval))s")
            }
        }
    }
    
    public func cancelWakeUpCheckNotification(occurrenceId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["wakefabio_check_\(occurrenceId.uuidString)"]
        )
    }
    
    public func cancelNotifications(for occurrenceId: UUID) {
        let identifier = "wakefabio_check_\(occurrenceId.uuidString)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Apresenta banner e som mesmo com app no foreground
        completionHandler([.banner, .sound])
    }
    
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let route = userInfo["route"] as? String, route == "wakeUpCheck",
           let occString = userInfo["occurrenceId"] as? String,
           let occUUID = UUID(uuidString: occString) {
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenWakeUpCheckRoute"),
                object: nil,
                userInfo: ["occurrenceId": occUUID]
            )
        }
        completionHandler()
    }
}
