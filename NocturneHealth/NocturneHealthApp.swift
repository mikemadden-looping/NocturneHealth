import SwiftUI
import BackgroundTasks

@main
struct NocturneHealthApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await SyncEngine.shared.sync() }
            case .background:
                AppDelegate.scheduleRefresh()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskID = "nocturnehealth.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // HealthKit background delivery needs its observers set up on every launch,
        // including the background launches it triggers.
        if Prefs.healthRequested {
            AppDelegate.startObserving()
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            Self.handleRefresh(task)
        }
        return true
    }

    static func startObserving() {
        HealthReader.shared.startObserving {
            await SyncEngine.shared.sync()
        }
    }

    /// A backup to background delivery: ask iOS for a periodic chance to sync.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(_ task: BGTask) {
        scheduleRefresh()
        let work = Task {
            await SyncEngine.shared.sync()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
