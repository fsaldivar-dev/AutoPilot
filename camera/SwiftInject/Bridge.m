#import <Foundation/Foundation.h>

// Declarado en Swift
extern void AutoPilotCameraInit(void);

__attribute__((constructor))
static void AutoPilotBridgeInit(void) {
    NSLog(@"[AutoPilot Bridge] Constructor — llamando Swift init");
    AutoPilotCameraInit();
}
