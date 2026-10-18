import SwiftUI
import UserNotifications

@main
struct BackDownApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var browser = BrowserModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                BrowserView(model: browser)
                    .tabItem { Label("브라우저", systemImage: "globe") }
                DownloadsView(manager: downloads) { url in
                    browser.download(url: url, suggestedName: nil, referer: nil)
                }
                .tabItem { Label("다운로드", systemImage: "arrow.down.circle") }
                .badge(downloads.items.filter(\.isActive).count)
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background: KeepAlive.shared.appDidEnterBackground()
                case .active: KeepAlive.shared.appWillEnterForeground()
                default: break
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorization()
        _ = DownloadManager.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == DownloadManager.sessionIdentifier {
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
