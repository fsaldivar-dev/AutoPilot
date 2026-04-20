#import <Foundation/Foundation.h>

// Exported by IPCServer.swift via @_silgen_name — no header needed.
extern void autopilot_observer_start(void);

/// Bootstrap class — +load runs before main(), before UIKit is ready.
/// Dispatch to main queue so UIApplication.shared is available when
/// IPCServer starts binding to 127.0.0.1:7002.
@interface AutoPilotObserverBootstrap : NSObject
@end

@implementation AutoPilotObserverBootstrap

+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        autopilot_observer_start();
    });
}

@end
