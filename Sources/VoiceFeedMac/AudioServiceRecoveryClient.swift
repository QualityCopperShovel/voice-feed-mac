import Foundation
import ServiceManagement
import Security
import AudioRecoveryProtocol

/// All completion and deadline transitions belong to the main queue.
final class AudioServiceRecoveryClient {
    let service = SMAppService.daemon(plistName: AudioRecoveryIdentity.plist)
    private var connection: NSXPCConnection?
    private var completion: ((Bool, String) -> Void)?
    var approved: Bool { service.status == .enabled }
    var signedRelease: Bool {
        var code: SecCode?; var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(AudioRecoveryIdentity.appRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    func restart(completion: @escaping (Bool, String) -> Void) {
        guard self.completion == nil else { completion(false, "Audio recovery is already running."); return }
        guard approved, signedRelease else { completion(false, "Automatic audio recovery needs administrator approval in macOS Login Items."); return }
        self.completion = completion
        let connection = NSXPCConnection(machServiceName: AudioRecoveryIdentity.service, options: .privileged)
        self.connection = connection
        connection.setCodeSigningRequirement(AudioRecoveryIdentity.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: AudioRecoveryProtocol.self)
        connection.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.finish(false, "Audio recovery helper disconnected.") } }
        connection.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.finish(false, "Audio recovery helper became unavailable.") } }
        connection.resume()
        let remote = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.finish(false, "Audio recovery request failed: \(error.localizedDescription)") }
        } as? AudioRecoveryProtocol
        guard let remote else { finish(false, "Audio recovery returned an invalid service interface."); return }
        remote.restartAudio { [weak self] ok, message in DispatchQueue.main.async { self?.finish(ok, message) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let self, self.connection === connection else { return }
            self.finish(false, "Audio recovery timed out after 10 seconds; microphone retries will continue.")
        }
    }
    private func finish(_ ok: Bool, _ message: String) {
        guard let completion else { return }
        self.completion = nil
        let old = connection; connection = nil
        old?.interruptionHandler = nil; old?.invalidationHandler = nil; old?.invalidate()
        completion(ok, message)
    }
}
