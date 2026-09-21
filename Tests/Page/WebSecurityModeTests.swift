import Foundation
import Testing
import WebKit
@testable import Browser

@MainActor @Test func webSecurityModesApplyNativeRestrictions() throws {
    let systemLockdown = WKWebpagePreferences().isLockdownModeEnabled
    let preferences = WKWebpagePreferences()
    if #available(macOS 26.4, *) {
        #expect(WebSecurityMode.available.contains(.enhanced))
        for (mode, value) in [(WebSecurityMode.enhanced, 1), (.lockdown, 2), (.standard, 0)] {
            mode.apply(to: preferences)
            let applied = try #require(preferences.value(forKey: "securityRestrictionMode") as? Int)
            #expect(applied == (systemLockdown ? 2 : value), "Requested mode: \(mode.rawValue)")
        }
    } else {
        #expect(!WebSecurityMode.available.contains(.enhanced))
        WebSecurityMode.lockdown.apply(to: preferences)
        #expect(preferences.isLockdownModeEnabled)
        WebSecurityMode.standard.apply(to: preferences)
        #expect(preferences.isLockdownModeEnabled == systemLockdown)
    }
}
