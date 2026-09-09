#import "AudioSafety.h"
NSError *VFAudioPerform(void (^operation)(void)) {
    @try {
        operation();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"VoiceFeedAudio" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Microphone configuration changed; reconnecting",
                       @"exception_name": exception.name}];
    }
}
