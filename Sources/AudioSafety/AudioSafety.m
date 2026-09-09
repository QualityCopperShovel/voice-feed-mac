#import "AudioSafety.h"
NSError *VFAudioPerform(void (^operation)(void)) {
    @try {
        operation();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"";
        return [NSError errorWithDomain:@"VoiceFeedAudio" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Microphone configuration changed; reconnecting",
                       @"exception_name": exception.name,
                       @"exception_reason": [reason substringToIndex:MIN(reason.length, 4096)],
                       @"exception_frames": [[exception.callStackSymbols subarrayWithRange:NSMakeRange(0, MIN(exception.callStackSymbols.count, 24))] componentsJoinedByString:@"\n"]}];
    }
}
