#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kFeedImagePath = @"/tmp/autopilot-camera-feed.jpg";
static NSString *const kFeedSignalPath = @"/tmp/autopilot-camera-active";

#pragma mark - Helper

static UIImage *LoadFeedImage(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:kFeedSignalPath]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:kFeedImagePath];
    if (!data) return nil;
    return [UIImage imageWithData:data];
}

#pragma mark - Swizzle AVCaptureDevice

static BOOL (*original_isSourceTypeAvailable)(id, SEL, UIImagePickerControllerSourceType);

static BOOL swizzled_isSourceTypeAvailable(id self, SEL _cmd, UIImagePickerControllerSourceType type) {
    if (type == UIImagePickerControllerSourceTypeCamera) {
        NSLog(@"[AutoPilot Camera] isSourceTypeAvailable(.camera) -> YES");
        return YES;
    }
    return original_isSourceTypeAvailable(self, _cmd, type);
}

static BOOL (*original_isCameraDeviceAvailable)(id, SEL, UIImagePickerControllerCameraDevice);

static BOOL swizzled_isCameraDeviceAvailable(id self, SEL _cmd, UIImagePickerControllerCameraDevice device) {
    NSLog(@"[AutoPilot Camera] isCameraDeviceAvailable -> YES");
    return YES;
}

#pragma mark - Swizzle AVCaptureDevice authorizationStatus & requestAccess

static AVAuthorizationStatus (*original_authorizationStatus)(id, SEL, AVMediaType);

static AVAuthorizationStatus swizzled_authorizationStatus(id self, SEL _cmd, AVMediaType mediaType) {
    if ([mediaType isEqualToString:AVMediaTypeVideo]) {
        NSLog(@"[AutoPilot Camera] authorizationStatus(.video) -> .authorized");
        return AVAuthorizationStatusAuthorized;
    }
    return original_authorizationStatus(self, _cmd, mediaType);
}

static void (*original_requestAccess)(id, SEL, AVMediaType, void (^)(BOOL));

static void swizzled_requestAccess(id self, SEL _cmd, AVMediaType mediaType, void (^handler)(BOOL)) {
    if ([mediaType isEqualToString:AVMediaTypeVideo]) {
        NSLog(@"[AutoPilot Camera] requestAccess(.video) -> true");
        if (handler) handler(YES);
        return;
    }
    original_requestAccess(self, _cmd, mediaType, handler);
}

static AVCaptureDevice * (*original_defaultDeviceWithType)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition);

static AVCaptureDevice *swizzled_defaultDeviceWithType(id self, SEL _cmd, AVCaptureDeviceType type, AVMediaType mediaType, AVCaptureDevicePosition position) {
    AVCaptureDevice *device = original_defaultDeviceWithType(self, _cmd, type, mediaType, position);
    if (!device && [mediaType isEqualToString:AVMediaTypeVideo]) {
        NSLog(@"[AutoPilot Camera] default device nil — session will run without input");
    }
    return device;
}

#pragma mark - Swizzle AVCaptureSession

static BOOL (*original_canAddInput)(id, SEL, AVCaptureInput *);

static BOOL swizzled_canAddInput(id self, SEL _cmd, AVCaptureInput *input) {
    BOOL result = original_canAddInput(self, _cmd, input);
    if (!result) {
        NSLog(@"[AutoPilot Camera] canAddInput overridden to YES");
        return YES;
    }
    return result;
}

static BOOL (*original_canAddOutput)(id, SEL, AVCaptureOutput *);

static BOOL swizzled_canAddOutput(id self, SEL _cmd, AVCaptureOutput *output) {
    BOOL result = original_canAddOutput(self, _cmd, output);
    if (!result) {
        NSLog(@"[AutoPilot Camera] canAddOutput overridden to YES");
        return YES;
    }
    return result;
}

#pragma mark - Swizzle AVCapturePhotoOutput capturePhoto

static void (*original_capturePhoto)(id, SEL, AVCapturePhotoSettings *, id<AVCapturePhotoCaptureDelegate>);

static void swizzled_capturePhoto(id self, SEL _cmd, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate) {
    NSLog(@"[AutoPilot Camera] capturePhoto intercepted!");

    UIImage *feedImage = LoadFeedImage();
    if (!feedImage) {
        NSLog(@"[AutoPilot Camera] No feed image — using gray placeholder");
        UIGraphicsBeginImageContext(CGSizeMake(1280, 720));
        [[UIColor grayColor] setFill];
        UIRectFill(CGRectMake(0, 0, 1280, 720));
        feedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }

    NSLog(@"[AutoPilot Camera] Injecting image directly to CameraManager.onPhotoCaptured");

    __strong id strongDelegate = delegate;
    __strong UIImage *strongImage = feedImage;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Access onPhotoCaptured ivar directly
        Ivar ivar = class_getInstanceVariable([strongDelegate class], "onPhotoCaptured");
        if (!ivar) {
            NSLog(@"[AutoPilot Camera] onPhotoCaptured ivar not found");
            return;
        }

        // Get the closure pointer — Swift optional closure is stored as a nullable function pointer
        id closureObj = object_getIvar(strongDelegate, ivar);
        if (!closureObj) {
            NSLog(@"[AutoPilot Camera] onPhotoCaptured is nil");
            return;
        }

        NSLog(@"[AutoPilot Camera] Found onPhotoCaptured closure, invoking with image");

        // Swift closure ((UIImage) -> Void)? is bridged as an ObjC block
        void (^callback)(UIImage *) = (void (^)(UIImage *))closureObj;
        callback(strongImage);

        NSLog(@"[AutoPilot Camera] Image injected successfully!");
    });
}

#pragma mark - Swizzle AVCaptureDeviceInput

static AVCaptureDeviceInput * (*original_initWithDevice)(id, SEL, AVCaptureDevice *, NSError **);

static AVCaptureDeviceInput *swizzled_initWithDevice(id self, SEL _cmd, AVCaptureDevice *device, NSError **outError) {
    if (device == nil) {
        NSLog(@"[AutoPilot Camera] DeviceInput with nil device — allowing");
        if (outError) *outError = nil;
        return self;
    }
    return original_initWithDevice(self, _cmd, device, outError);
}

#pragma mark - Swizzle AVCaptureSession startRunning/stopRunning

static void (*original_startRunning)(id, SEL);

static void swizzled_startRunning(id self, SEL _cmd) {
    NSLog(@"[AutoPilot Camera] AVCaptureSession.startRunning() intercepted");
    // Don't call original — it will fail without a real camera
    // Just pretend the session is running
}

static void (*original_stopRunning)(id, SEL);

static void swizzled_stopRunning(id self, SEL _cmd) {
    NSLog(@"[AutoPilot Camera] AVCaptureSession.stopRunning()");
    // Don't call original
}

#pragma mark - Constructor

__attribute__((constructor))
static void AutoPilotCameraInit(void) {
    NSLog(@"[AutoPilot Camera] === Dylib loaded — swizzling camera APIs ===");

    // UIImagePickerController
    Method m1 = class_getClassMethod([UIImagePickerController class], @selector(isSourceTypeAvailable:));
    original_isSourceTypeAvailable = (void *)method_getImplementation(m1);
    method_setImplementation(m1, (IMP)swizzled_isSourceTypeAvailable);

    Method m2 = class_getClassMethod([UIImagePickerController class], @selector(isCameraDeviceAvailable:));
    original_isCameraDeviceAvailable = (void *)method_getImplementation(m2);
    method_setImplementation(m2, (IMP)swizzled_isCameraDeviceAvailable);

    // AVCaptureDevice authorizationStatus
    Method m_auth = class_getClassMethod([AVCaptureDevice class], @selector(authorizationStatusForMediaType:));
    original_authorizationStatus = (void *)method_getImplementation(m_auth);
    method_setImplementation(m_auth, (IMP)swizzled_authorizationStatus);

    // AVCaptureDevice requestAccess
    Method m_req = class_getClassMethod([AVCaptureDevice class], @selector(requestAccessForMediaType:completionHandler:));
    original_requestAccess = (void *)method_getImplementation(m_req);
    method_setImplementation(m_req, (IMP)swizzled_requestAccess);

    // AVCaptureDevice default(_:for:position:)
    Method m_def = class_getClassMethod([AVCaptureDevice class], @selector(defaultDeviceWithDeviceType:mediaType:position:));
    original_defaultDeviceWithType = (void *)method_getImplementation(m_def);
    method_setImplementation(m_def, (IMP)swizzled_defaultDeviceWithType);

    // AVCaptureSession
    Method m3 = class_getInstanceMethod([AVCaptureSession class], @selector(canAddInput:));
    original_canAddInput = (void *)method_getImplementation(m3);
    method_setImplementation(m3, (IMP)swizzled_canAddInput);

    Method m4 = class_getInstanceMethod([AVCaptureSession class], @selector(canAddOutput:));
    original_canAddOutput = (void *)method_getImplementation(m4);
    method_setImplementation(m4, (IMP)swizzled_canAddOutput);

    Method m5 = class_getInstanceMethod([AVCaptureSession class], @selector(startRunning));
    original_startRunning = (void *)method_getImplementation(m5);
    method_setImplementation(m5, (IMP)swizzled_startRunning);

    Method m6 = class_getInstanceMethod([AVCaptureSession class], @selector(stopRunning));
    original_stopRunning = (void *)method_getImplementation(m6);
    method_setImplementation(m6, (IMP)swizzled_stopRunning);

    // AVCaptureDeviceInput
    Method m7 = class_getInstanceMethod([AVCaptureDeviceInput class], @selector(initWithDevice:error:));
    original_initWithDevice = (void *)method_getImplementation(m7);
    method_setImplementation(m7, (IMP)swizzled_initWithDevice);

    // AVCapturePhotoOutput — the key interception
    Method m8 = class_getInstanceMethod([AVCapturePhotoOutput class], @selector(capturePhotoWithSettings:delegate:));
    original_capturePhoto = (void *)method_getImplementation(m8);
    method_setImplementation(m8, (IMP)swizzled_capturePhoto);

    NSLog(@"[AutoPilot Camera] === Swizzle complete ===");
    NSLog(@"[AutoPilot Camera] Feed: %@  Signal: %@", kFeedImagePath, kFeedSignalPath);
}
