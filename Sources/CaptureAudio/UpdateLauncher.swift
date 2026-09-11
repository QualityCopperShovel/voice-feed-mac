import AppKit
import Foundation

/// LaunchServices reports launch success before the old process exits. The
/// returned cancellation closure also closes a late, owned successor.
public enum UpdateLauncher {
    public static func launch(at url: URL, completion done: @escaping (Result<Void, Error>) -> Void) -> () -> Void {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true; configuration.activates = false
        var abandoned = false
        var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                if abandoned { application?.terminate(); return }
                launched = application
                if let error { done(.failure(error)) }
                else if let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier, !application.isTerminated {
                    done(.success(()))
                } else {
                    done(.failure(NSError(domain: "VoiceFeedUpdate", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "macOS did not launch the updated app"])))
                }
            }
        }
        return { abandoned = true; launched?.terminate() }
    }
}
