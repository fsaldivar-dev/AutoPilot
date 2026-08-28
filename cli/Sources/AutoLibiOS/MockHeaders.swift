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
    #import <CoreImage/CoreImage.h>
    #import <objc/runtime.h>
    #include <string.h>
    #include <sys/stat.h>

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
    // Replacement: AVCaptureMetadataOutput  (escaneo en vivo, issue #120+)
    // ============================================================
    //
    // Antes esto era no-op: se guardaba el delegate y nunca se le entregaba nada,
    // asi que una app con escaneo continuo (AVCaptureMetadataOutput + .qr) se
    // quedaba esperando para siempre. El test de QR que si pasaba va por otro
    // camino — QrScanViewModel es un AVCapturePhotoCaptureDelegate: dispara foto
    // y decodifica con Vision — que no cubre el patron dominante en scanners.
    //
    // El payload NO se configura aparte: se DECODIFICA de la misma imagen que ya
    // usa el resto del mock. Un solo concepto de "que ve la camara", y de regalo
    // los bounds salen del QR real en vez de un rectangulo inventado.

    // Definida en la seccion del preview, mas abajo en este mismo archivo.
    static NSString *ap_resolveImagePath(void);

    static const void *kAPMetaDelegateBoxKey = &kAPMetaDelegateBoxKey;
    static const void *kAPMetaQueueKey       = &kAPMetaQueueKey;
    static const void *kAPMetaTypesKey       = &kAPMetaTypesKey;

    // Caja debil. AVFoundation retiene su delegate DEBILMENTE; guardarlo fuerte en
    // un associated object crea un ciclo con el view controller del scanner y la
    // pantalla no se libera nunca al cerrarla.
    @interface APWeakBox : NSObject
    @property (nonatomic, weak) id target;
    @end
    @implementation APWeakBox
    @end

    // Subclase con storage propio: class_createInstance reserva el instanceSize de
    // la subclase, asi que estos ivars existen de verdad. Los getters heredados
    // leerian ivars de AVFoundation que ningun -init suyo lleno nunca.
    @interface APFakeMetadataObject : AVMetadataMachineReadableCodeObject {
        NSString *_apValue;
        CGRect    _apBounds;
    }
    - (void)ap_setValue:(NSString *)value bounds:(CGRect)bounds;
    @end

    @implementation APFakeMetadataObject

    - (void)ap_setValue:(NSString *)value bounds:(CGRect)bounds {
        _apValue = [value copy];
        _apBounds = bounds;
    }

    - (NSString *)stringValue    { return _apValue; }
    - (AVMetadataObjectType)type { return AVMetadataObjectTypeQRCode; }
    - (CGRect)bounds             { return _apBounds; }
    - (CMTime)time               { return kCMTimeZero; }
    - (CMTime)duration           { return kCMTimeZero; }

    // corners es NSArray<NSDictionary *> con la representacion de diccionario de
    // CGPoint. El getter heredado lee un ivar que nunca se lleno.
    - (NSArray *)corners {
        CGRect b = _apBounds;
        CGPoint pts[4] = {
            CGPointMake(CGRectGetMinX(b), CGRectGetMinY(b)),
            CGPointMake(CGRectGetMaxX(b), CGRectGetMinY(b)),
            CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b)),
            CGPointMake(CGRectGetMinX(b), CGRectGetMaxY(b)),
        };
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:4];
        for (int i = 0; i < 4; i++) {
            [out addObject:(__bridge_transfer NSDictionary *)CGPointCreateDictionaryRepresentation(pts[i])];
        }
        return out;
    }

    - (NSString *)description {
        return [NSString stringWithFormat:@"<APFakeMetadataObject: %@>", _apValue];
    }

    @end

    // El delegate recibe una connection en cada callback y en Swift ese parametro
    // NO es opcional: pasar nil hace que la app crashee al primer acceso. Subclase
    // y no una instancia pelada de AVCaptureConnection porque los accessors
    // heredados que devuelven objetos leerian ivars en cero, y el puntero basura
    // crashea al primer mensaje. Este objeto solo lo ve la app.
    @interface APFakeConnection : AVCaptureConnection
    @end

    @implementation APFakeConnection
    - (AVCaptureOutput *)output                       { return nil; }
    - (NSArray *)inputPorts                           { return @[]; }
    - (AVCaptureVideoPreviewLayer *)videoPreviewLayer { return nil; }
    - (BOOL)isEnabled                                 { return YES; }
    - (BOOL)isActive                                  { return YES; }
    // Soportado = NO en todo lo ajustable: una app que pregunte antes de escribir
    // se queda quieta, que es lo que haria con una camara sin esa capacidad.
    - (BOOL)isVideoOrientationSupported               { return NO; }
    - (AVCaptureVideoOrientation)videoOrientation     { return AVCaptureVideoOrientationPortrait; }
    - (BOOL)isVideoMirroringSupported                 { return NO; }
    - (BOOL)isVideoMirrored                           { return NO; }
    @end

    // Outputs con delegate registrado. Debil: si la pantalla del scanner se cierra
    // y su output muere, la entrada desaparece sola y no emitimos a un objeto muerto.
    static NSHashTable *gAPMetaOutputs = nil;
    static NSObject *gAPMetaLock = nil;

    // Lienzo fijo del preview compuesto; la capa lo estira con kCAGravityResize.
    static const CGFloat kAPPreviewCanvasW = 400;
    static const CGFloat kAPPreviewCanvasH = 600;

    // Tamano de la ultima imagen decodificada. Hace falta para reproducir el
    // aspect-fill al convertir coordenadas, y evita releerla en cada llamada.
    static CGSize gAPLastImageSize = {0, 0};

    // Aspect-fill de la imagen dentro del lienzo. Una sola definicion, usada por
    // el compositor del preview Y por la conversion de coordenadas: si divergen,
    // el recuadro deja de caer sobre el QR y el error es dificil de ver.
    static CGRect ap_previewDrawRect(CGSize imgSize) {
        CGFloat w = kAPPreviewCanvasW;
        CGFloat h = kAPPreviewCanvasH;
        if (imgSize.width <= 0 || imgSize.height <= 0) return CGRectMake(0, 0, w, h);

        CGFloat imgAspect = imgSize.width / imgSize.height;
        CGFloat viewAspect = w / h;
        if (imgAspect > viewAspect) {
            CGFloat drawH = h;
            CGFloat drawW = h * imgAspect;
            return CGRectMake(-(drawW - w) / 2, 0, drawW, drawH);
        }
        CGFloat drawW = w;
        CGFloat drawH = w / imgAspect;
        return CGRectMake(0, -(drawH - h) / 2, drawW, drawH);
    }

    // Todo objeto nacido de class_createInstance se retiene para siempre: su
    // -dealloc heredado correria sobre ivars de AVF que nunca se inicializaron.
    // Son un punado por proceso y el proceso es una app bajo prueba.
    static NSMutableArray *gAPKeepAlive = nil;

    static id ap_keepAlive(id obj) {
        if (obj == nil) return nil;
        @synchronized (gAPMetaLock) { [gAPKeepAlive addObject:obj]; }
        return obj;
    }

    // Decodifica el primer QR de la imagen inyectada. Devuelve NO si no hay imagen
    // o no hay codigo — que es un resultado legitimo, no un error.
    //
    // CIDetector y no Vision, y esto se midio: VNDetectBarcodesRequest falla dentro
    // del simulador con "Could not create inference context" porque su backend de
    // ML no levanta ahi. CIDetector no pasa por esa pila y decodifica QR desde
    // iOS 8. (La app demo si usa Vision, pero corre esa decodificacion sobre una
    // foto ya capturada, no desde la dylib inyectada.)
    static BOOL ap_decodeQRFromImage(NSString **outPayload, CGRect *outBounds) {
        NSString *path = ap_resolveImagePath();
        if (path == nil) return NO;

        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data == nil) return NO;

        CIImage *image = [CIImage imageWithData:data];
        if (image == nil) return NO;

        CGRect extent = image.extent;
        if (CGRectIsEmpty(extent)) return NO;
        gAPLastImageSize = extent.size;

        static CIDetector *detector = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                          context:nil
                                          options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        });
        if (detector == nil) return NO;

        for (CIFeature *feature in [detector featuresInImage:image]) {
            if (![feature isKindOfClass:[CIQRCodeFeature class]]) continue;
            NSString *payload = [(CIQRCodeFeature *)feature messageString];
            if (payload.length == 0) continue;

            // CIImage tiene el origen ABAJO-izquierda y bounds en pixeles;
            // AVMetadataObject los quiere normalizados y con origen ARRIBA-izquierda.
            // Sin el volteo el recuadro sale reflejado en Y, y de forma plausible:
            // con un QR centrado no se nota.
            CGRect b = feature.bounds;
            *outBounds = CGRectMake(b.origin.x / extent.size.width,
                                    1.0 - (b.origin.y + b.size.height) / extent.size.height,
                                    b.size.width / extent.size.width,
                                    b.size.height / extent.size.height);
            *outPayload = payload;
            return YES;
        }
        return NO;
    }

    static AVCaptureConnection *ap_fakeConnection(void) {
        static AVCaptureConnection *connection = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            connection = ap_keepAlive(class_createInstance([APFakeConnection class], 0));
        });
        return connection;
    }

    // Cacheados por payload+rect: cada objeto se retiene para siempre (su -dealloc
    // heredado correria sobre ivars de AVF sin inicializar), asi que fabricar uno
    // por llamada haria crecer la memoria sin techo en una sesion larga.
    static NSMutableDictionary *gAPMetaCache = nil;

    static AVMetadataMachineReadableCodeObject *ap_metadataObject(NSString *payload, CGRect bounds) {
        NSString *key = [NSString stringWithFormat:@"%@|%@", payload, NSStringFromCGRect(bounds)];
        @synchronized (gAPMetaLock) {
            APFakeMetadataObject *object = gAPMetaCache[key];
            if (object == nil) {
                object = class_createInstance([APFakeMetadataObject class], 0);
                [object ap_setValue:payload bounds:bounds];
                gAPMetaCache[key] = object;
                ap_keepAlive(object);
            }
            return object;
        }
    }

    static void ap_emitToOutput(AVCaptureMetadataOutput *output, NSString *payload, CGRect bounds) {
        APWeakBox *box = objc_getAssociatedObject(output, kAPMetaDelegateBoxKey);
        id delegate = box.target;
        if (delegate == nil) return;

        SEL sel = @selector(captureOutput:didOutputMetadataObjects:fromConnection:);
        if (![delegate respondsToSelector:sel]) {
            NSLog(@"[AutoPilot] %@ no implementa captureOutput:didOutputMetadataObjects:",
                  NSStringFromClass([delegate class]));
            return;
        }

        // Respetamos lo que la app pidio: emitir un QR a un output configurado solo
        // para codigos de barras seria mentirle de una forma que no pasa con
        // hardware real.
        NSArray *types = objc_getAssociatedObject(output, kAPMetaTypesKey);
        if (types.count > 0 && ![types containsObject:AVMetadataObjectTypeQRCode]) return;

        dispatch_queue_t queue = objc_getAssociatedObject(output, kAPMetaQueueKey);
        if (queue == nil) queue = dispatch_get_main_queue();

        AVMetadataMachineReadableCodeObject *object = ap_metadataObject(payload, bounds);
        dispatch_async(queue, ^{
            [delegate captureOutput:output didOutputMetadataObjects:@[object] fromConnection:ap_fakeConnection()];
        });
        NSLog(@"[AutoPilot] QR emitido a %@: %@", NSStringFromClass([delegate class]), payload);
    }

    static void ap_emitQRToAllOutputs(void) {
        NSString *payload = nil;
        CGRect bounds = CGRectZero;
        if (!ap_decodeQRFromImage(&payload, &bounds)) return;

        NSArray *outputs;
        @synchronized (gAPMetaLock) { outputs = gAPMetaOutputs.allObjects; }
        for (AVCaptureMetadataOutput *output in outputs) {
            ap_emitToOutput(output, payload, bounds);
        }
    }

    // Sondeo de la imagen inyectada. El resto del mock la relee en cada captura de
    // foto —el disparo es el evento— pero el escaneo en vivo no tiene evento que
    // disparar la relectura: la app solo espera. 250 ms de stat no se miden, y
    // cubren creacion, reemplazo y borrado con el mismo camino.
    static void ap_startImageWatcher(void) {
        static dispatch_source_t timer = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
            dispatch_source_set_timer(timer,
                                      dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                                      250 * NSEC_PER_MSEC,
                                      50 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer, ^{
                static ino_t lastIno = 0;
                static off_t lastSize = 0;
                static long lastMtime = 0;

                NSString *path = ap_resolveImagePath();
                if (path == nil) return;

                struct stat st;
                if (stat(path.fileSystemRepresentation, &st) != 0) return;
                if (st.st_ino == lastIno && st.st_size == lastSize &&
                    st.st_mtimespec.tv_sec == lastMtime) return;

                lastIno = st.st_ino;
                lastSize = st.st_size;
                lastMtime = st.st_mtimespec.tv_sec;

                NSLog(@"[AutoPilot] imagen de camara cambio, redecodificando QR");
                ap_emitQRToAllOutputs();
            });
            dispatch_resume(timer);
        });
    }

    static IMP orig_setMetadataDelegate = NULL;
    static IMP orig_setMetadataObjectTypes = NULL;

    static void ap_setMetadataDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
        APWeakBox *box = [APWeakBox new];
        box.target = delegate;
        objc_setAssociatedObject(self, kAPMetaDelegateBoxKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kAPMetaQueueKey,
                                 queue ?: dispatch_get_main_queue(),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized (gAPMetaLock) { [gAPMetaOutputs addObject:self]; }

        NSLog(@"[AutoPilot] delegate de metadata registrado: %@", NSStringFromClass([delegate class]));

        ap_startImageWatcher();

        // Diferido: la pantalla del scanner acaba de montar su sesion y suele
        // terminar de construirse en el mismo ciclo de runloop. Emitir aqui mismo
        // llega antes de que la UI pueda reaccionar.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            ap_emitQRToAllOutputs();
        });
    }

    // El setter real valida contra los tipos que soporta el hardware conectado. Con
    // un device fabricado esa lista sale vacia y asignar .qr lanza
    // NSInvalidArgumentException. Solo guardamos, nunca llamamos al original.
    static void ap_setMetadataObjectTypes(id self, SEL _cmd, NSArray *types) {
        objc_setAssociatedObject(self, kAPMetaTypesKey, [types copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    static NSArray *ap_metadataObjectTypes(id self, SEL _cmd) {
        return objc_getAssociatedObject(self, kAPMetaTypesKey) ?: @[];
    }

    // Mas ancho que solo QR a proposito: muchas apps intersectan lo que quieren con
    // availableMetadataObjectTypes y abortan el setup si la interseccion sale vacia.
    static NSArray *ap_availableMetadataObjectTypes(id self, SEL _cmd) {
        return @[AVMetadataObjectTypeQRCode,
                 AVMetadataObjectTypeEAN13Code,
                 AVMetadataObjectTypeEAN8Code,
                 AVMetadataObjectTypeCode128Code,
                 AVMetadataObjectTypeCode39Code,
                 AVMetadataObjectTypePDF417Code,
                 AVMetadataObjectTypeAztecCode,
                 AVMetadataObjectTypeDataMatrixCode];
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

        // Aspect fill — misma geometria que usa la conversion de coordenadas.
        [img drawInRect:ap_previewDrawRect(img.size)];

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

    // Convierte el objeto detectado a coordenadas de la capa.
    //
    // Sin este hook la implementacion real devuelve el objeto sin tocar: la app
    // recibe bounds NORMALIZADOS (0..1) donde espera puntos y dibuja el recuadro
    // de deteccion como un cuadrado de menos de un punto en la esquina. No
    // crashea — solo sale mal, que cuesta mas de encontrar.
    //
    // Son dos etapas encadenadas, porque el preview no muestra la imagen directa:
    //   1. imagen -> lienzo 400x600, con el aspect-fill de ap_previewDrawRect
    //   2. lienzo -> capa, estirado lineal (la capa usa kCAGravityResize)
    static AVMetadataObject *ap_transformedMetadataObject(CALayer *self, SEL _cmd,
                                                          AVMetadataObject *object) {
        if (![object isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) return object;

        CGRect bounds = self.bounds;
        // Con la capa aun sin medir, devolver el objeto sin tocar es mas honesto
        // que multiplicar por cero.
        if (CGRectIsEmpty(bounds)) return object;

        CGRect draw = ap_previewDrawRect(gAPLastImageSize);
        CGRect n = object.bounds;

        CGFloat canvasX = draw.origin.x + n.origin.x * draw.size.width;
        CGFloat canvasY = draw.origin.y + n.origin.y * draw.size.height;
        CGFloat canvasW = n.size.width  * draw.size.width;
        CGFloat canvasH = n.size.height * draw.size.height;

        CGFloat sx = CGRectGetWidth(bounds)  / kAPPreviewCanvasW;
        CGFloat sy = CGRectGetHeight(bounds) / kAPPreviewCanvasH;

        CGRect mapped = CGRectMake(CGRectGetMinX(bounds) + canvasX * sx,
                                   CGRectGetMinY(bounds) + canvasY * sy,
                                   canvasW * sx,
                                   canvasH * sy);

        return ap_metadataObject([(AVMetadataMachineReadableCodeObject *)object stringValue], mapped);
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
    // VisionKit private SPI shims — issue #120
    // ============================================================
    // VNDocumentCameraViewController (VisionKit → DocumentCamera.framework,
    // internal class ICDocCamViewController) calls PRIVATE AVCaptureDevice
    // setters during setupCaptureSession. Our mock hands out real
    // [[AVCaptureDevice alloc] init] instances (see ap_defaultDevice /
    // ap_defaultDeviceWithType), and the simulator device does not implement
    // those SPI selectors, so the call dies with:
    //   NSInvalidArgumentException:
    //   "-[AVCaptureDevice setProvidesStortorgetMetadata:] Not supported by this device"
    //
    // Strategy — two ADDITIVE layers. We only class_addMethod when the
    // selector is missing; we NEVER replace an existing (real) implementation:
    //   1. Eager no-ops for the known VisionKit SPI setters (and their
    //      getters, returning NO), registered in the constructor.
    //   2. A +resolveInstanceMethod: hook on AVCaptureDevice as a safety
    //      net: any still-unknown single-argument "setXxx:" selector gets a
    //      dynamic no-op, so future iOS/VisionKit SPI additions degrade
    //      gracefully instead of crashing.
    //
    // respondsToSelector: stays coherent for free: NSObject's implementation
    // consults +resolveInstanceMethod: before answering NO, so a VisionKit
    // feature-check and the subsequent call see the same answer. Because the
    // resolver installs a real IMP, normal dispatch handles the call and no
    // forwardingTargetForSelector: override is needed.

    static void ap_spiSetterNoop(id self, SEL _cmd, id value) {
        NSLog(@"[AutoPilot] SPI setter no-op %@ (issue #120)", NSStringFromSelector(_cmd));
    }

    static BOOL ap_spiGetterNo(id self, SEL _cmd) {
        return NO;
    }

    // Adds a no-op ONLY if the class (or a superclass) does not already
    // implement the selector. Never clobbers a real implementation.
    static void ap_add_noop_if_missing(Class cls, NSString *selName, IMP imp, const char *types) {
        SEL sel = NSSelectorFromString(selName);
        if (class_getInstanceMethod(cls, sel)) return; // real impl exists — leave it alone
        if (class_addMethod(cls, sel, imp, types)) {
            NSLog(@"[AutoPilot] Added SPI no-op %@ to %@ (issue #120)", selName, NSStringFromClass(cls));
        }
    }

    static BOOL (*orig_resolveInstanceMethod)(Class, SEL, SEL) = NULL;

    static BOOL ap_resolveInstanceMethod(Class self, SEL _cmd, SEL sel) {
        // Give the original resolver (NSObject's or AVFoundation's) first shot.
        if (orig_resolveInstanceMethod && orig_resolveInstanceMethod(self, _cmd, sel)) {
            return YES;
        }
        // Safety net: unknown single-argument property setter → dynamic no-op.
        // Matches "setXxx…:" with exactly one trailing colon (plain property
        // setters). Multi-argument "set…" methods (e.g. with completion
        // handlers) are left untouched — a silent no-op there could hang
        // callers waiting on a callback.
        const char *name = sel_getName(sel);
        size_t len = strlen(name);
        // NOTE: no class_getInstanceMethod() here — it would re-enter method
        // resolution and could recurse. The resolver only fires for selectors
        // the runtime could not find, and class_addMethod already refuses to
        // override a method added in the meantime.
        if (len > 4 &&
            strncmp(name, "set", 3) == 0 &&
            (name[3] >= 'A' && name[3] <= 'Z') &&
            name[len - 1] == ':' &&
            strchr(name, ':') == name + len - 1) {
            NSLog(@"[AutoPilot] Resolving unknown private setter %s as no-op (issue #120)", name);
            return class_addMethod(self, sel, (IMP)ap_spiSetterNoop, "v@:@");
        }
        return NO;
    }

    // ============================================================
    // Constructor — runs at load time
    // ============================================================

    __attribute__((constructor))
    static void AutoPilotCaptureInit(void) {
        NSString *imagePath = ap_resolveImagePath();
        NSLog(@"[AutoPilot] Camera mock activating... Image: %@", imagePath ?: @"(none yet, use 'auto inject <image>')");

        // Estado del escaneo en vivo. Sin esto, [nil addObject:] es un no-op
        // silencioso: los outputs nunca se registran y nada se emite jamas.
        gAPMetaLock = [NSObject new];
        gAPMetaOutputs = [NSHashTable weakObjectsHashTable];
        gAPKeepAlive = [NSMutableArray array];
        gAPMetaCache = [NSMutableDictionary dictionary];

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

        // --- VisionKit SPI shims (issue #120) ---
        // Known private BOOL properties that ICDocCamViewController sets on
        // the capture device. Added ONLY if the simulator runtime does not
        // implement them (ap_add_noop_if_missing never overrides real IMPs).
        ap_add_noop_if_missing(deviceClass, @"setProvidesStortorgetMetadata:", (IMP)ap_spiSetterNoop, "v@:B");
        ap_add_noop_if_missing(deviceClass, @"setSpatialOverCaptureEnabled:", (IMP)ap_spiSetterNoop, "v@:B");
        ap_add_noop_if_missing(deviceClass, @"setMultiCamSessionEnabled:", (IMP)ap_spiSetterNoop, "v@:B");
        // Matching getters (VisionKit may read the property back) — report NO.
        ap_add_noop_if_missing(deviceClass, @"providesStortorgetMetadata", (IMP)ap_spiGetterNo, "B@:");
        ap_add_noop_if_missing(deviceClass, @"isSpatialOverCaptureEnabled", (IMP)ap_spiGetterNo, "B@:");
        ap_add_noop_if_missing(deviceClass, @"isMultiCamSessionEnabled", (IMP)ap_spiGetterNo, "B@:");

        // Safety net for SPI we have not enumerated: hook
        // +resolveInstanceMethod: on AVCaptureDevice (metaclass). Prefer
        // class_addMethod so we never touch NSObject's shared implementation;
        // fall back to method_setImplementation only if AVCaptureDevice
        // already overrides the resolver directly. Original is chained.
        {
            Method resolveM = class_getClassMethod(deviceClass, @selector(resolveInstanceMethod:));
            orig_resolveInstanceMethod = (BOOL (*)(Class, SEL, SEL))method_getImplementation(resolveM);
            Class deviceMeta = object_getClass(deviceClass);
            if (!class_addMethod(deviceMeta, @selector(resolveInstanceMethod:),
                                 (IMP)ap_resolveInstanceMethod, method_getTypeEncoding(resolveM))) {
                method_setImplementation(resolveM, (IMP)ap_resolveInstanceMethod);
            }
            NSLog(@"[AutoPilot] resolveInstanceMethod hook on AVCaptureDevice active (issue #120)");
        }

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

        ap_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
            @selector(transformedMetadataObjectForMetadataObject:),
            (IMP)ap_transformedMetadataObject, NULL);

        // Swizzle AVCaptureMetadataOutput
        Class metadataOutputClass = [AVCaptureMetadataOutput class];
        ap_swizzle_instance_method(metadataOutputClass,
            @selector(setMetadataObjectsDelegate:queue:),
            (IMP)ap_setMetadataDelegate, &orig_setMetadataDelegate);
        ap_swizzle_instance_method(metadataOutputClass,
            @selector(setMetadataObjectTypes:),
            (IMP)ap_setMetadataObjectTypes, &orig_setMetadataObjectTypes);
        ap_swizzle_instance_method(metadataOutputClass,
            @selector(metadataObjectTypes),
            (IMP)ap_metadataObjectTypes, NULL);
        ap_swizzle_instance_method(metadataOutputClass,
            @selector(availableMetadataObjectTypes),
            (IMP)ap_availableMetadataObjectTypes, NULL);

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
