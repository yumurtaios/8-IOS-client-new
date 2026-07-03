import UIKit
import UserNotifications

// Slim AppDelegate нового premium-клиента.
// В отличие от старого мотора здесь НЕ подключён Firebase — push регистрируется
// напрямую через APNs. Контракт с бэкендом не меняется: токен уходит тем же
// POST /api/v1/push/register (см. Core/Push.swift), platform: "ios".
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func requestPushAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    // APNs-токен → в шестнадцатеричную строку → в Push для отправки на бэкенд.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Push.shared.fcmToken = hex
        Task { await Push.shared.registerIfPossible() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Тихо игнорируем: push не критичен для работы приложения.
    }

    // Показ уведомления, когда приложение открыто.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}
