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
    static const void *kAPVideoDelegateKey = &kAPVideoDelegateKey;
    static const void *kAPVideoQueueKey = &kAPVideoQueueKey;

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

    // Forward declarations for video frame pump (defined further below).
    static void ap_startFrameTimerIfNeeded(void);
    static void ap_stopFrameTimerIfIdle(void);
    // ap_resolveImagePath is defined later but used by the frame pump.
    static NSString *ap_resolveImagePath(void);

    static void ap_startRunning(id self, SEL _cmd) {
        NSLog(@"[AutoPilot] startRunning");
        objc_setAssociatedObject(self, kAPSessionRunningKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Kick the video frame pump for any AVCaptureVideoDataOutput delegates
        // that were attached to this session (or any other). VisionKit's
        // VNDocumentCameraViewController needs a continuous stream of
        // CMSampleBuffers — without it, FigCaptureSourceSimulator dereferences
        // null and crashes with SIGSEGV.
        ap_startFrameTimerIfNeeded();
    }

    static void ap_stopRunning(id self, SEL _cmd) {
        NSLog(@"[AutoPilot] stopRunning");
        objc_setAssociatedObject(self, kAPSessionRunningKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ap_stopFrameTimerIfIdle();
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
    // Replacement: AVCaptureVideoDataOutput
    // ============================================================
    // VisionKit (VNDocumentCameraViewController, ICDocCamViewController)
    // and any custom video pipeline (AR, ML, real-time filters) attaches a
    // delegate to AVCaptureVideoDataOutput and expects a continuous stream
    // of CMSampleBuffers. Without that stream, FigCaptureSourceSimulator
    // pushes a malformed FormatDescription and code paths that don't null-
    // check segfault. We:
    //   1. Capture every (delegate, queue) pair via swizzled setter.
    //   2. Run a dispatch_source_t timer at ~15fps.
    //   3. On each tick: load the mock image, build a fresh CVPixelBuffer +
    //      CMSampleBuffer, fan out to every tracked delegate on its queue.

    static NSMutableArray *ap_videoOutputs = nil;          // strong refs
    static dispatch_queue_t ap_outputsQueue = nil;          // serializes mutations
    static dispatch_source_t ap_frameTimer = nil;
    static dispatch_queue_t ap_frameTimerQueue = nil;

    static CVPixelBufferRef ap_pixelBufferFromImage(UIImage *image) {
        if (!image || !image.CGImage) return NULL;

        size_t width = (size_t)CGImageGetWidth(image.CGImage);
        size_t height = (size_t)CGImageGetHeight(image.CGImage);
        // Cap at a reasonable preview size to keep CPU low; document detection
        // works fine at 720p.
        const size_t maxEdge = 1280;
        if (width > maxEdge || height > maxEdge) {
            double scale = (double)maxEdge / (double)MAX(width, height);
            width = (size_t)(width * scale);
            height = (size_t)(height * scale);
        }

        NSDictionary *attrs = @{
            (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferRef pxBuf = NULL;
        CVReturn ok = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attrs, &pxBuf);
        if (ok != kCVReturnSuccess || !pxBuf) return NULL;

        CVPixelBufferLockBaseAddress(pxBuf, 0);
        void *base = CVPixelBufferGetBaseAddress(pxBuf);
        size_t bpr = CVPixelBufferGetBytesPerRow(pxBuf);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(base, width, height, 8, bpr, cs,
            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image.CGImage);
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(pxBuf, 0);
        return pxBuf;
    }

    static CMSampleBufferRef ap_sampleBufferFromPixelBuffer(CVPixelBufferRef pxBuf, CMTime presentationTime) {
        if (!pxBuf) return NULL;
        CMVideoFormatDescriptionRef fmt = NULL;
        OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pxBuf, &fmt);
        if (s != noErr || !fmt) return NULL;

        CMSampleTimingInfo timing;
        timing.duration = CMTimeMake(1, 15);
        timing.presentationTimeStamp = presentationTime;
        timing.decodeTimeStamp = kCMTimeInvalid;

        CMSampleBufferRef sampleBuf = NULL;
        s = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pxBuf, true,
                                               NULL, NULL, fmt, &timing, &sampleBuf);
        CFRelease(fmt);
        if (s != noErr) {
            if (sampleBuf) { CFRelease(sampleBuf); }
            return NULL;
        }
        return sampleBuf;
    }

    static void ap_pumpFrame(void) {
        // Snapshot tracked outputs to avoid holding the lock during dispatch.
        NSArray *outputs = nil;
        @synchronized (ap_videoOutputs) {
            outputs = [ap_videoOutputs copy];
        }
        if (outputs.count == 0) return;

        NSString *imagePath = ap_resolveImagePath();
        UIImage *img = nil;
        if (imagePath) {
            NSData *data = [NSData dataWithContentsOfFile:imagePath];
            if (data) img = [UIImage imageWithData:data];
        }
        if (!img) return;

        CVPixelBufferRef pxBuf = ap_pixelBufferFromImage(img);
        if (!pxBuf) return;

        CMTime ts = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        CMSampleBufferRef sample = ap_sampleBufferFromPixelBuffer(pxBuf, ts);
        CVPixelBufferRelease(pxBuf);
        if (!sample) return;

        for (id output in outputs) {
            id delegate = objc_getAssociatedObject(output, kAPVideoDelegateKey);
            dispatch_queue_t q = objc_getAssociatedObject(output, kAPVideoQueueKey);
            if (!delegate || !q) continue;
            if (![delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) continue;

            CFRetain(sample);
            dispatch_async(q, ^{
                @try {
                    [delegate captureOutput:output didOutputSampleBuffer:sample fromConnection:nil];
                } @catch (NSException *e) {
                    NSLog(@"[AutoPilot] frame delegate threw: %@", e);
                }
                CFRelease(sample);
            });
        }
        CFRelease(sample);
    }

    static void ap_startFrameTimerIfNeeded(void) {
        @synchronized (ap_videoOutputs ?: [NSNull null]) {
            if (ap_frameTimer) return;
            if (!ap_frameTimerQueue) {
                ap_frameTimerQueue = dispatch_queue_create("dev.autopilot.frame-pump", DISPATCH_QUEUE_SERIAL);
            }
            ap_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ap_frameTimerQueue);
            // ~15 fps is enough for VisionKit's document edge detection and
            // keeps the simulator's CPU happy.
            uint64_t interval = NSEC_PER_SEC / 15;
            dispatch_source_set_timer(ap_frameTimer, dispatch_time(DISPATCH_TIME_NOW, interval),
                                      interval, NSEC_PER_SEC / 30);
            dispatch_source_set_event_handler(ap_frameTimer, ^{ ap_pumpFrame(); });
            dispatch_resume(ap_frameTimer);
            NSLog(@"[AutoPilot] Frame pump started @ 15fps");
        }
    }

    static void ap_stopFrameTimerIfIdle(void) {
        // Conservative: keep pumping until shutdown. Stopping per-session is
        // tricky if multiple sessions exist; the cost of an idle 15fps timer
        // is negligible.
    }

    static void ap_setSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
        NSLog(@"[AutoPilot] AVCaptureVideoDataOutput.setSampleBufferDelegate (tracked, delegate=%@)",
              NSStringFromClass([delegate class]));
        objc_setAssociatedObject(self, kAPVideoDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kAPVideoQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!ap_videoOutputs) {
            ap_videoOutputs = [NSMutableArray new];
            ap_outputsQueue = dispatch_queue_create("dev.autopilot.video-outputs", DISPATCH_QUEUE_SERIAL);
        }
        @synchronized (ap_videoOutputs) {
            if (delegate && ![ap_videoOutputs containsObject:self]) {
                [ap_videoOutputs addObject:self];
            } else if (!delegate) {
                [ap_videoOutputs removeObject:self];
            }
        }
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

    static UIImage *ap_compositePreviewImage(UIImage *img) {
        // Render at a fixed preview size so the banner is always visible
        CGFloat w = 400;
        CGFloat h = 600;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), YES, 2.0);

        // Draw image filling the rect (aspect fill)
        CGFloat imgAspect = img.size.width / img.size.height;
        CGFloat viewAspect = w / h;
        CGRect drawRect;
        if (imgAspect > viewAspect) {
            CGFloat drawH = h;
            CGFloat drawW = h * imgAspect;
            drawRect = CGRectMake(-(drawW - w) / 2, 0, drawW, drawH);
        } else {
            CGFloat drawW = w;
            CGFloat drawH = w / imgAspect;
            drawRect = CGRectMake(0, -(drawH - h) / 2, drawW, drawH);
        }
        [img drawInRect:drawRect];

        // "LIVE" dot + text at top-left
        CGFloat dotSize = 8;
        CGFloat margin = 12;
        [[UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:1] setFill];
        UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(margin, margin + 3, dotSize, dotSize)];
        [dot fill];

        NSDictionary *liveAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        [@"LIVE" drawAtPoint:CGPointMake(margin + dotSize + 4, margin) withAttributes:liveAttrs];

        // Banner at bottom
        CGFloat bannerH = 28;
        CGFloat bannerY = h - bannerH;
        [[UIColor colorWithWhite:0 alpha:0.6] setFill];
        UIRectFill(CGRectMake(0, bannerY, w, bannerH));

        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.85]
        };
        NSString *label = @"AutoPilot  |  Mock Camera";
        CGSize textSize = [label sizeWithAttributes:attrs];
        [label drawAtPoint:CGPointMake((w - textSize.width) / 2, bannerY + (bannerH - textSize.height) / 2) withAttributes:attrs];

        UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return result;
    }

    static NSString *ap_resolveImagePath(void) {
        // 1. Fixed file (updated by "auto inject")
        NSString *fixed = @"/tmp/autopilot-camera-image.jpg";
        if ([[NSFileManager defaultManager] fileExistsAtPath:fixed]) return fixed;
        // 2. Env var (set at launch time)
        NSString *env = [NSProcessInfo processInfo].environment[@"AUTOPILOT_CAMERA_IMAGE"];
        if (env && [[NSFileManager defaultManager] fileExistsAtPath:env]) return env;
        return nil;
    }

    static void ap_previewSetSession(CALayer *self, SEL _cmd, AVCaptureSession *session) {
        NSLog(@"[AutoPilot] PreviewLayer.setSession -> showing mock image");

        NSString *imagePath = ap_resolveImagePath();
        UIImage *img = nil;
        if (imagePath) {
            NSData *data = [NSData dataWithContentsOfFile:imagePath];
            if (data) img = [UIImage imageWithData:data];
        }
        if (!img) {
            UIGraphicsBeginImageContext(CGSizeMake(400, 600));
            [[UIColor darkGrayColor] setFill];
            UIRectFill(CGRectMake(0, 0, 400, 600));
            img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }

        UIImage *preview = ap_compositePreviewImage(img);
        self.contents = (__bridge id)preview.CGImage;
        self.contentsGravity = kCAGravityResize;
        self.masksToBounds = YES;
    }

    // ============================================================
    // Replacement: AVCapturePhotoOutput
    // ============================================================

    static void ap_capturePhoto(AVCapturePhotoOutput *self, SEL _cmd,
                                AVCapturePhotoSettings *settings,
                                id<AVCapturePhotoCaptureDelegate> delegate) {
        NSLog(@"[AutoPilot] capturePhoto intercepted");

        // Load image from fixed path or env var (re-read each time to support hot-swap)
        NSString *imagePath = ap_resolveImagePath();
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
    // Catch-all no-op for unknown AVCaptureDevice setters
    // ============================================================
    // VisionKit (DocumentCamera) calls private setters on AVCaptureDevice
    // (e.g. setProvidesStortorgetMetadata:) that exist but throw
    // NSInvalidArgumentException on the simulator. We blanket-replace every
    // single-arg void setter on AVCaptureDevice with a no-op. Safe because
    // the device returned by our mock is never a real capture device.
    static void ap_noop_setter(id self, SEL _cmd, ...) {
        // Variadic signature ignores all incoming arg registers (scalar/object).
    }

    static int ap_patch_avdevice_setters(Class deviceClass) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(deviceClass, &methodCount);
        int patched = 0;
        for (unsigned int i = 0; i < methodCount; i++) {
            SEL sel = method_getName(methods[i]);
            const char *name = sel_getName(sel);
            size_t len = strlen(name);
            if (len < 5) continue;
            if (strncmp(name, "set", 3) != 0) continue;
            if (name[len-1] != ':') continue;
            int colons = 0;
            for (size_t j = 0; j < len; j++) if (name[j] == ':') colons++;
            if (colons != 1) continue;
            const char *enc = method_getTypeEncoding(methods[i]);
            if (!enc || enc[0] != 'v') continue;
            method_setImplementation(methods[i], (IMP)ap_noop_setter);
            patched++;
        }
        free(methods);
        return patched;
    }

    // ============================================================
    // Constructor — runs at load time
    // ============================================================

    __attribute__((constructor))
    static void AutoPilotCaptureInit(void) {
        NSString *imagePath = ap_resolveImagePath();
        NSLog(@"[AutoPilot] Camera mock activating... Image: %@", imagePath ?: @"(none yet, use 'auto inject <image>')");

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

        // Defuse private setters (e.g. setProvidesStortorgetMetadata: from VisionKit)
        // that throw "Not supported by this device" on simulator.
        int patchedSetters = ap_patch_avdevice_setters(deviceClass);
        NSLog(@"[AutoPilot] AVCaptureDevice: no-op'd %d single-arg void setters", patchedSetters);

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

        // Swizzle AVCaptureVideoDataOutput so VisionKit / ML / AR pipelines
        // get a real CMSampleBuffer stream instead of waiting forever (and
        // eventually segfaulting in FigCaptureSourceSimulator).
        Class videoOutputClass = [AVCaptureVideoDataOutput class];
        if (videoOutputClass) {
            ap_swizzle_instance_method(videoOutputClass,
                @selector(setSampleBufferDelegate:queue:),
                (IMP)ap_setSampleBufferDelegate, NULL);
        }

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
