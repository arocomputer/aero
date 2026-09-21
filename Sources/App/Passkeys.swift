import AuthenticationServices
import Security

/// Reports and requests browser-wide passkey access after Apple grants Aero's managed entitlement.
enum Passkeys {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    static var hasEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        else { return false }
        return value as? Bool == true
    }

    static var status: String {
        guard hasEntitlement else {
            return "Passkeys are unavailable in this build because it lacks the managed browser passkey entitlement."
        }
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .authorized: return "\(appName) can use passkeys from iCloud Keychain and credential managers."
        case .denied: return "Passkey access is denied for \(appName)."
        case .notDetermined: return "\(appName) needs permission before websites can use your passkeys."
        @unknown default: return "Passkey access is unavailable."
        }
    }

    static var canRequestAccess: Bool {
        hasEntitlement
            && ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials
                == .notDetermined
    }

    static func requestAccess(completion: @escaping () -> Void) {
        guard hasEntitlement else { return completion() }
        ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in
            DispatchQueue.main.async(execute: completion)
        }
    }
}
