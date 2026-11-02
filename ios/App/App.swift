import UIKit

/// China Train: train.deyaochen.com's route planner as an iPhone app with no server. The planner runs on the phone,
/// the timetable is the site's static file (cached), and live seats come straight from 12306. The screen is UIKit,
/// drawn to the site's own layout, so it can ride iOS's rotation; `-reference` shows the site's page instead.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = Flags.reference ? ReferenceController() : Screen()
        window.makeKeyAndVisible()
        self.window = window
    }
}
