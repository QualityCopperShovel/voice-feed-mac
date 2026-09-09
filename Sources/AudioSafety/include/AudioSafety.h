#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// AVFAudio uses Objective-C exceptions that Swift do/catch cannot catch.
NSError * _Nullable VFAudioPerform(void (^operation)(void));
NS_ASSUME_NONNULL_END
