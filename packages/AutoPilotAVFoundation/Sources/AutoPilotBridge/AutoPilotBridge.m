#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Se ejecuta automaticamente al cargar el modulo — no requiere llamada explicita
__attribute__((constructor))
static void AutoPilotBridgeInit(void) {
    // Buscar la clase Swift y llamar activate()
    Class cls = NSClassFromString(@"AutoPilotAVFoundation.AutoPilotLoader");
    if (cls) {
        SEL sel = NSSelectorFromString(@"setup");
        if ([cls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [cls performSelector:sel];
#pragma clang diagnostic pop
        }
    }
}

void AutoPilotForceLoad(void) {
    // Existe solo para que el linker no elimine este modulo
}
