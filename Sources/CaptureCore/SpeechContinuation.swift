/// A transport chunk boundary is not an end of speech.
public func continuesSpeech(heardSpeech: Bool, secondsSinceSpeech: Double, tailSeconds: Double) -> Bool {
    heardSpeech && secondsSinceSpeech >= 0 && secondsSinceSpeech <= tailSeconds
}
