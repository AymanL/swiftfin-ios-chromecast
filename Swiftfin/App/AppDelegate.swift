//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import GoogleCast
import PreferencesView
import UIKit

#if DEBUG
import Defaults
#endif

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let receiverAppID: String = {
            #if DEBUG
            if Defaults[.useUnstableJellyfinChromecastReceiver] {
                return JellyfinCastReceiverID.unstable
            }
            #endif
            return JellyfinCastReceiverID.stable
        }()

        let discoveryCriteria = GCKDiscoveryCriteria(applicationID: receiverAppID)
        let options = GCKCastOptions(discoveryCriteria: discoveryCriteria)
        GCKCastContext.setSharedInstanceWith(options)
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {

        guard UIDevice.isPhone else {
            return .allButUpsideDown
        }

        if let presentedViewController = window?.rootViewController?.presentedViewController,
           let preferencesHostingController = presentedViewController as? UIPreferencesHostingController
        {
            return preferencesHostingController.supportedInterfaceOrientations
        }

        return .portrait
    }
}
