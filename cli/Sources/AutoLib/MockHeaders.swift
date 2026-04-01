import Foundation

// MARK: - ObjC source for camera mock via swizzling
// Compiled into a static library and force-loaded into the target app.
// At runtime, swizzled methods replace AVFoundation camera behavior.

enum MockHeaders {

    /// ObjC implementation that swizzles AVFoundation camera classes at load time.
    /// Uses `#define AV_INIT_UNAVAILABLE` to bypass compile-time init restriction
    /// on AVCapturePhoto, allowing us to create real instances.
    static let captureImplementation = """
    // Import AVBase.h first (defines AV_INIT_UNAVAILABLE macro), then undef it
    // so that AVCapturePhoto's init becomes available at compile time.
    #import <AVFoundation/AVBase.h>
    #undef AV_INIT_UNAVAILABLE
    #define AV_INIT_UNAVAILABLE

    #import <AVFoundation/AVFoundation.h>
    #import <UIKit/UIKit.h>
    #import <objc/runtime.h>

    static const void *kAPImageDataKey = &kAPImageDataKey;
    static const void *kAPTimestampKey = &kAPTimestampKey;
    static const void *kAPSessionInputsKey = &kAPSessionInputsKey;
    static const void *kAPSessionOutputsKey = &kAPSessionOutputsKey;

    // ============================================================
    // Swizzle helper
    // ============================================================

    static void ap_swizzle_class_method(Class cls, SEL original, IMP replacement, IMP *outOriginal) {
        Method m = class_getClassMethod(cls, original);
        if (!m) return;
        IMP prev = method_setImplementation(m, replacement);
        if (outOriginal) *outOriginal = prev;
    }

    static void ap_swizzle_instance_method(Class cls, SEL original, IMP replacement, IMP *outOriginal) {
        Method m = class_getInstanceMethod(cls, original);
        if (!m) {
            NSLog(@"[AutoPilot] WARN: method %@ not found on %@", NSStringFromSelector(original), NSStringFromClass(cls));
            return;
        }
        // Try to add the method first (in case it's inherited, not directly on this class)
        BOOL added = class_addMethod(cls, original, replacement, method_getTypeEncoding(m));
        if (added) {
            if (outOriginal) *outOriginal = method_getImplementation(m);
            NSLog(@"[AutoPilot] Added %@ to %@", NSStringFromSelector(original), NSStringFromClass(cls));
        } else {
            IMP prev = method_setImplementation(m, replacement);
            if (outOriginal) *outOriginal = prev;
            NSLog(@"[AutoPilot] Swizzled %@ on %@", NSStringFromSelector(original), NSStringFromClass(cls));
        }
    }

    // ============================================================
    // Original IMPs
    // ============================================================

    static IMP orig_authorizationStatus = NULL;
    static IMP orig_requestAccess = NULL;
    static IMP orig_defaultDevice = NULL;
    static IMP orig_defaultDeviceWithType = NULL;
    static IMP orig_deviceInputWithDevice = NULL;
    static IMP orig_startRunning = NULL;
    static IMP orig_stopRunning = NULL;
    static IMP orig_canAddInput = NULL;
    static IMP orig_canAddOutput = NULL;
    static IMP orig_capturePhoto = NULL;
    static IMP orig_fileDataRepresentation = NULL;
    static IMP orig_cgImageRepresentation = NULL;
    static IMP orig_timestamp = NULL;
    static IMP orig_photoCount = NULL;
    static IMP orig_isRawPhoto = NULL;

    // ============================================================
    // Replacement: AVCaptureDevice
    // ============================================================

    static AVAuthorizationStatus ap_authorizationStatus(id self, SEL _cmd, AVMediaType mediaType) {
        NSLog(@"[AutoPilot] authorizationStatus → .authorized");
        return AVAuthorizationStatusAuthorized;
    }

    static void ap_requestAccess(id self, SEL _cmd, AVMediaType mediaType, void (^handler)(BOOL)) {
        NSLog(@"[AutoPilot] requestAccess → YES");
        dispatch_async(dispatch_get_main_queue(), ^{ handler(YES); });
    }

    static AVCaptureDevice *ap_defaultDevice(id self, SEL _cmd, AVMediaType mediaType) {
        NSLog(@"[AutoPilot] defaultDevice(mediaType:) → mock");
        AVCaptureDevice *real = ((AVCaptureDevice *(*)(id, SEL, AVMediaType))orig_defaultDevice)(self, _cmd, mediaType);
        if (real) return real;
        // Create a mock device via alloc+init (works because AV_INIT_UNAVAILABLE is suppressed)
        return [[AVCaptureDevice alloc] init];
    }

    static AVCaptureDevice *ap_defaultDeviceWithType(id self, SEL _cmd, AVCaptureDeviceType type, AVMediaType mediaType, AVCaptureDevicePosition position) {
        NSLog(@"[AutoPilot] defaultDevice(type:mediaType:position:) → mock");
        AVCaptureDevice *real = ((AVCaptureDevice *(*)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition))orig_defaultDeviceWithType)(self, _cmd, type, mediaType, position);
        if (real) return real;
        return [[AVCaptureDevice alloc] init];
    }

    // ============================================================
    // Replacement: AVCaptureDeviceInput
    // ============================================================

    static AVCaptureDeviceInput *ap_deviceInputWithDevice(id self, SEL _cmd, AVCaptureDevice *device, NSError **outError) {
        NSLog(@"[AutoPilot] deviceInputWithDevice (class) → mock input");
        if (outError) *outError = nil;
        return [[AVCaptureDeviceInput alloc] init];
    }

    static IMP orig_initWithDevice = NULL;

    static AVCaptureDeviceInput *ap_initWithDevice(AVCaptureDeviceInput *self, SEL _cmd, AVCaptureDevice *device, NSError **outError) {
        NSLog(@"[AutoPilot] initWithDevice (instance) → mock input");
        if (outError) *outError = nil;
        // Skip original (would fail with mock device). Just call NSObject's init.
        typedef id (*InitIMP)(id, SEL);
        InitIMP nsObjectInit = (InitIMP)class_getMethodImplementation([NSObject class], @selector(init));
        return (AVCaptureDeviceInput *)nsObjectInit(self, @selector(init));
    }

    // ============================================================
    // Replacement: AVCaptureSession
    // ============================================================

    static IMP orig_isRunning = NULL;
    static const void *kAPSessionRunningKey = &kAPSessionRunningKey;

    static void ap_startRunning(id self, SEL _cmd) {
        NSLog(@"[AutoPilot] startRunning (mock no-op)");
        objc_setAssociatedObject(self, kAPSessionRunningKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    static void ap_stopRunning(id self, SEL _cmd) {
        NSLog(@"[AutoPilot] stopRunning (mock no-op)");
        objc_setAssociatedObject(self, kAPSessionRunningKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    static BOOL ap_isRunning(id self, SEL _cmd) {
        NSNumber *val = objc_getAssociatedObject(self, kAPSessionRunningKey);
        return val ? val.boolValue : NO;
    }

    static BOOL ap_canAddInput(id self, SEL _cmd, id input) {
        NSLog(@"[AutoPilot] canAddInput → YES");
        return YES;
    }

    static BOOL ap_canAddOutput(id self, SEL _cmd, id output) {
        NSLog(@"[AutoPilot] canAddOutput → YES");
        return YES;
    }

    static IMP orig_addInput = NULL;
    static IMP orig_addOutput = NULL;
    static IMP orig_removeInput = NULL;
    static IMP orig_removeOutput = NULL;
    static IMP orig_beginConfiguration = NULL;
    static IMP orig_commitConfiguration = NULL;
    static IMP orig_inputs = NULL;
    static IMP orig_outputs = NULL;

    static void ap_addInput(id self, SEL _cmd, id input) {
        NSLog(@"[AutoPilot] addInput (tracked)");
        NSMutableArray *arr = objc_getAssociatedObject(self, kAPSessionInputsKey);
        if (!arr) { arr = [NSMutableArray new]; objc_setAssociatedObject(self, kAPSessionInputsKey, arr, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        [arr addObject:input];
    }

    static void ap_addOutput(id self, SEL _cmd, id output) {
        NSLog(@"[AutoPilot] addOutput (tracked)");
        NSMutableArray *arr = objc_getAssociatedObject(self, kAPSessionOutputsKey);
        if (!arr) { arr = [NSMutableArray new]; objc_setAssociatedObject(self, kAPSessionOutputsKey, arr, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        [arr addObject:output];
    }

    static void ap_removeInput(id self, SEL _cmd, id input) {
        NSMutableArray *arr = objc_getAssociatedObject(self, kAPSessionInputsKey);
        [arr removeObject:input];
    }

    static void ap_removeOutput(id self, SEL _cmd, id output) {
        NSMutableArray *arr = objc_getAssociatedObject(self, kAPSessionOutputsKey);
        [arr removeObject:output];
    }

    static void ap_beginConfiguration(id self, SEL _cmd) {}
    static void ap_commitConfiguration(id self, SEL _cmd) {}

    static NSArray *ap_inputs(id self, SEL _cmd) {
        NSArray *arr = objc_getAssociatedObject(self, kAPSessionInputsKey);
        return arr ?: @[];
    }
    static NSArray *ap_outputs(id self, SEL _cmd) {
        NSArray *arr = objc_getAssociatedObject(self, kAPSessionOutputsKey);
        return arr ?: @[];
    }

    // ============================================================
    // Replacement: AVCaptureMetadataOutput
    // ============================================================

    static IMP orig_setMetadataDelegate = NULL;
    static IMP orig_setMetadataObjectTypes = NULL;

    static void ap_setMetadataDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
        NSLog(@"[AutoPilot] setMetadataObjectsDelegate (mock no-op)");
        // Store delegate via associated object for potential QR injection
        objc_setAssociatedObject(self, "ap_metaDelegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    static void ap_setMetadataObjectTypes(id self, SEL _cmd, NSArray *types) {
        NSLog(@"[AutoPilot] setMetadataObjectTypes (mock no-op)");
    }

    // ============================================================
    // Replacement: AVCaptureVideoPreviewLayer
    // ============================================================

    static IMP orig_previewSetSession = NULL;

    static void ap_previewSetSession(CALayer *self, SEL _cmd, AVCaptureSession *session) {
        NSLog(@"[AutoPilot] PreviewLayer.setSession → showing mock image");

        // Load the image and set it as the layer contents
        NSString *imagePath = [NSProcessInfo processInfo].environment[@"AUTOPILOT_CAMERA_IMAGE"];
        if (imagePath) {
            NSData *data = [NSData dataWithContentsOfFile:imagePath];
            if (data) {
                UIImage *img = [UIImage imageWithData:data];
                if (img) {
                    self.contents = (__bridge id)img.CGImage;
                    self.contentsGravity = kCAGravityResizeAspectFill;
                    self.masksToBounds = YES;
                    return;
                }
            }
        }

        // Fallback: red placeholder
        UIGraphicsBeginImageContext(CGSizeMake(400, 600));
        [[UIColor darkGrayColor] setFill];
        UIRectFill(CGRectMake(0, 0, 400, 600));
        UIImage *placeholder = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        self.contents = (__bridge id)placeholder.CGImage;
        self.contentsGravity = kCAGravityResizeAspectFill;
    }

    // ============================================================
    // Replacement: AVCapturePhotoOutput
    // ============================================================

    static void ap_capturePhoto(AVCapturePhotoOutput *self, SEL _cmd,
                                AVCapturePhotoSettings *settings,
                                id<AVCapturePhotoCaptureDelegate> delegate) {
        NSLog(@"[AutoPilot] capturePhoto intercepted");

        // Load image from env var
        NSString *imagePath = [NSProcessInfo processInfo].environment[@"AUTOPILOT_CAMERA_IMAGE"];
        NSData *imageData = nil;

        if (imagePath) {
            imageData = [NSData dataWithContentsOfFile:imagePath];
            if (imageData) {
                NSLog(@"[AutoPilot] Loaded image: %@ (%lu bytes)", imagePath, (unsigned long)imageData.length);
            } else {
                NSLog(@"[AutoPilot] WARNING: could not load image at %@", imagePath);
            }
        }

        if (!imageData) {
            // Generate placeholder
            UIGraphicsBeginImageContext(CGSizeMake(100, 100));
            [[UIColor redColor] setFill];
            UIRectFill(CGRectMake(0, 0, 100, 100));
            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            imageData = UIImageJPEGRepresentation(img, 0.9);
            NSLog(@"[AutoPilot] Using placeholder image (no AUTOPILOT_CAMERA_IMAGE set)");
        }

        // Create a REAL AVCapturePhoto via init (possible because we #defined away AV_INIT_UNAVAILABLE)
        AVCapturePhoto *photo = [[AVCapturePhoto alloc] init];

        // Store our data via associated objects (avoids touching internal ivars)
        objc_setAssociatedObject(photo, kAPImageDataKey, imageData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Deliver to delegate on main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
                [delegate captureOutput:self didFinishProcessingPhoto:photo error:nil];
                NSLog(@"[AutoPilot] Photo delivered to delegate");
            }
        });
    }

    // ============================================================
    // Replacement: AVCapturePhoto methods
    // ============================================================

    static NSData *ap_fileDataRepresentation(id self, SEL _cmd) {
        NSData *mockData = objc_getAssociatedObject(self, kAPImageDataKey);
        if (mockData) return mockData;
        // Fallback to original for non-mock photos
        if (orig_fileDataRepresentation) {
            return ((NSData *(*)(id, SEL))orig_fileDataRepresentation)(self, _cmd);
        }
        return nil;
    }

    static CGImageRef ap_cgImageRepresentation(id self, SEL _cmd) {
        NSData *mockData = objc_getAssociatedObject(self, kAPImageDataKey);
        if (mockData) {
            UIImage *img = [UIImage imageWithData:mockData];
            return img.CGImage; // Note: caller must retain if needed
        }
        if (orig_cgImageRepresentation) {
            return ((CGImageRef(*)(id, SEL))orig_cgImageRepresentation)(self, _cmd);
        }
        return NULL;
    }

    static CMTime ap_timestamp(id self, SEL _cmd) {
        NSData *mockData = objc_getAssociatedObject(self, kAPImageDataKey);
        if (mockData) {
            return CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        }
        if (orig_timestamp) {
            return ((CMTime(*)(id, SEL))orig_timestamp)(self, _cmd);
        }
        return kCMTimeZero;
    }

    static NSInteger ap_photoCount(id self, SEL _cmd) {
        NSData *mockData = objc_getAssociatedObject(self, kAPImageDataKey);
        if (mockData) return 1;
        if (orig_photoCount) {
            return ((NSInteger(*)(id, SEL))orig_photoCount)(self, _cmd);
        }
        return 1;
    }

    static BOOL ap_isRawPhoto(id self, SEL _cmd) {
        NSData *mockData = objc_getAssociatedObject(self, kAPImageDataKey);
        if (mockData) return NO;
        if (orig_isRawPhoto) {
            return ((BOOL(*)(id, SEL))orig_isRawPhoto)(self, _cmd);
        }
        return NO;
    }

    // ============================================================
    // Constructor — runs at load time
    // ============================================================

    __attribute__((constructor))
    static void AutoPilotCaptureInit(void) {
        NSString *imagePath = [NSProcessInfo processInfo].environment[@"AUTOPILOT_CAMERA_IMAGE"];
        NSString *qrCode = [NSProcessInfo processInfo].environment[@"AUTOPILOT_QR_CODE"];

        if (!imagePath && !qrCode) {
            NSLog(@"[AutoPilot] Camera mock inactive (no AUTOPILOT_CAMERA_IMAGE or AUTOPILOT_QR_CODE)");
            return;
        }

        NSLog(@"[AutoPilot] Camera mock activating...");

        Class deviceClass = [AVCaptureDevice class];
        Class sessionClass = [AVCaptureSession class];
        Class photoOutputClass = [AVCapturePhotoOutput class];
        Class photoClass = [AVCapturePhoto class];

        // Swizzle AVCaptureDevice class methods
        ap_swizzle_class_method(deviceClass,
            @selector(authorizationStatusForMediaType:),
            (IMP)ap_authorizationStatus, &orig_authorizationStatus);

        ap_swizzle_class_method(deviceClass,
            @selector(requestAccessForMediaType:completionHandler:),
            (IMP)ap_requestAccess, &orig_requestAccess);

        ap_swizzle_class_method(deviceClass,
            @selector(defaultDeviceWithMediaType:),
            (IMP)ap_defaultDevice, &orig_defaultDevice);

        ap_swizzle_class_method(deviceClass,
            @selector(defaultDeviceWithDeviceType:mediaType:position:),
            (IMP)ap_defaultDeviceWithType, &orig_defaultDeviceWithType);

        // Swizzle AVCaptureDeviceInput
        Class deviceInputClass = [AVCaptureDeviceInput class];
        ap_swizzle_class_method(deviceInputClass,
            @selector(deviceInputWithDevice:error:),
            (IMP)ap_deviceInputWithDevice, &orig_deviceInputWithDevice);
        ap_swizzle_instance_method(deviceInputClass,
            @selector(initWithDevice:error:),
            (IMP)ap_initWithDevice, &orig_initWithDevice);

        // Swizzle AVCaptureSession instance methods
        ap_swizzle_instance_method(sessionClass,
            @selector(startRunning), (IMP)ap_startRunning, &orig_startRunning);

        ap_swizzle_instance_method(sessionClass,
            @selector(stopRunning), (IMP)ap_stopRunning, &orig_stopRunning);

        ap_swizzle_instance_method(sessionClass,
            @selector(isRunning), (IMP)ap_isRunning, &orig_isRunning);
        ap_swizzle_instance_method(sessionClass,
            @selector(canAddInput:), (IMP)ap_canAddInput, &orig_canAddInput);

        ap_swizzle_instance_method(sessionClass,
            @selector(canAddOutput:), (IMP)ap_canAddOutput, &orig_canAddOutput);

        ap_swizzle_instance_method(sessionClass,
            @selector(addInput:), (IMP)ap_addInput, &orig_addInput);
        ap_swizzle_instance_method(sessionClass,
            @selector(addOutput:), (IMP)ap_addOutput, &orig_addOutput);
        ap_swizzle_instance_method(sessionClass,
            @selector(removeInput:), (IMP)ap_removeInput, &orig_removeInput);
        ap_swizzle_instance_method(sessionClass,
            @selector(removeOutput:), (IMP)ap_removeOutput, &orig_removeOutput);
        ap_swizzle_instance_method(sessionClass,
            @selector(beginConfiguration), (IMP)ap_beginConfiguration, &orig_beginConfiguration);
        ap_swizzle_instance_method(sessionClass,
            @selector(commitConfiguration), (IMP)ap_commitConfiguration, &orig_commitConfiguration);
        ap_swizzle_instance_method(sessionClass,
            @selector(inputs), (IMP)ap_inputs, &orig_inputs);
        ap_swizzle_instance_method(sessionClass,
            @selector(outputs), (IMP)ap_outputs, &orig_outputs);

        // Swizzle AVCapturePhotoOutput
        ap_swizzle_instance_method(photoOutputClass,
            @selector(capturePhotoWithSettings:delegate:),
            (IMP)ap_capturePhoto, &orig_capturePhoto);

        // Swizzle AVCapturePhoto methods
        ap_swizzle_instance_method(photoClass,
            @selector(fileDataRepresentation),
            (IMP)ap_fileDataRepresentation, &orig_fileDataRepresentation);

        ap_swizzle_instance_method(photoClass,
            @selector(CGImageRepresentation),
            (IMP)ap_cgImageRepresentation, &orig_cgImageRepresentation);

        ap_swizzle_instance_method(photoClass,
            @selector(timestamp),
            (IMP)ap_timestamp, &orig_timestamp);

        ap_swizzle_instance_method(photoClass,
            @selector(photoCount),
            (IMP)ap_photoCount, &orig_photoCount);

        ap_swizzle_instance_method(photoClass,
            @selector(isRawPhoto),
            (IMP)ap_isRawPhoto, &orig_isRawPhoto);

        // Swizzle AVCaptureMetadataOutput
        Class metadataOutputClass = [AVCaptureMetadataOutput class];
        ap_swizzle_instance_method(metadataOutputClass,
            @selector(setMetadataObjectsDelegate:queue:),
            (IMP)ap_setMetadataDelegate, &orig_setMetadataDelegate);
        ap_swizzle_instance_method(metadataOutputClass,
            @selector(setMetadataObjectTypes:),
            (IMP)ap_setMetadataObjectTypes, &orig_setMetadataObjectTypes);

        // Swizzle AVCaptureVideoPreviewLayer to show our image
        Class previewLayerClass = [AVCaptureVideoPreviewLayer class];
        ap_swizzle_instance_method(previewLayerClass,
            @selector(setSession:),
            (IMP)ap_previewSetSession, &orig_previewSetSession);

        NSLog(@"[AutoPilot] Camera mock active. Image: %@. Swizzled %d methods.",
              imagePath ?: @"(placeholder)",
              (orig_authorizationStatus ? 1 : 0) + (orig_startRunning ? 1 : 0) +
              (orig_addInput ? 1 : 0) + (orig_addOutput ? 1 : 0) +
              (orig_capturePhoto ? 1 : 0) + (orig_defaultDeviceWithType ? 1 : 0) +
              (orig_initWithDevice ? 1 : 0) + (orig_fileDataRepresentation ? 1 : 0));
    }
    """
}
