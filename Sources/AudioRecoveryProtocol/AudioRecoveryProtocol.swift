import Foundation

@objc public protocol AudioRecoveryProtocol {
    // No executable, PID, signal, path or arguments may be supplied by a caller.
    func restartAudio(withReply reply: @escaping (Bool, String) -> Void)
}

public enum AudioRecoveryIdentity {
    public static let service = "com.aisloppy.voice-feed.audio-recovery"
    public static let plist = service + ".plist"
    public static let appRequirement = "anchor apple generic and identifier \"com.aisloppy.voice-feed\" and certificate leaf[subject.OU] = \"7ZPTPEXGRC\""
    public static let helperRequirement = "anchor apple generic and identifier \"com.aisloppy.voice-feed.audio-recovery\" and certificate leaf[subject.OU] = \"7ZPTPEXGRC\""
}
