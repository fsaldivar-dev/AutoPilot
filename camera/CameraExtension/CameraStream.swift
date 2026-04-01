import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import CoreImage
import os.log

class CameraStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!

    private let _streamFormat: CMIOExtensionStreamFormat
    private var _isStreaming = false
    private var _timer: DispatchSourceTimer?
    private var _lastImageModDate: Date?

    // Cache del pixel buffer para no recrearlo cada frame si la imagen no cambio
    private var _cachedPixelBuffer: CVPixelBuffer?

    // Resolucion del feed (720p)
    private let width: Int32 = 1280
    private let height: Int32 = 720

    init(localizedName: String) {
        let formatDescription = CameraStreamSource.createFormatDescription(width: 1280, height: 720)
        _streamFormat = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: 1),  // 1 FPS para imagen estatica
            minFrameDuration: CMTime(value: 1, timescale: 30), // max 30 FPS
            validFrameDurations: nil
        )

        super.init()

        let streamID = UUID()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTimeClock as CMIOExtensionStream.ClockType,
            source: self
        )
    }

    // MARK: - CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] {
        return [_streamFormat]
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            // 1 FPS — suficiente para imagen estatica
            streamProperties.frameDuration = CMTime(value: 1, timescale: 1)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        return true
    }

    func startStream() throws {
        guard !_isStreaming else { return }
        _isStreaming = true
        startTimer()
        logger.info("Stream iniciado")
    }

    func stopStream() throws {
        guard _isStreaming else { return }
        _isStreaming = false
        _timer?.cancel()
        _timer = nil
        logger.info("Stream detenido")
    }

    // MARK: - Streaming

    func startStreaming() {
        _isStreaming = true
        startTimer()
    }

    func stopStreaming() {
        _isStreaming = false
        _timer?.cancel()
        _timer = nil
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        // 2 FPS — suficiente para imagen estatica, bajo consumo de CPU
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.emitFrame()
        }
        timer.resume()
        _timer = timer
    }

    private func emitFrame() {
        guard _isStreaming else { return }

        // Verificar si la camara esta activa (archivo signal existe)
        guard FileManager.default.fileExists(atPath: kFeedSignalPath) else {
            // Si no esta activa, emitir frame negro
            if let buffer = createBlackPixelBuffer() {
                pushFrame(pixelBuffer: buffer)
            }
            return
        }

        // Verificar si la imagen cambio
        let imageModDate = fileModificationDate(kFeedImagePath)
        if imageModDate != _lastImageModDate || _cachedPixelBuffer == nil {
            // Imagen nueva o primera carga
            if let buffer = loadImageAsPixelBuffer(path: kFeedImagePath) {
                _cachedPixelBuffer = buffer
                _lastImageModDate = imageModDate
            }
        }

        if let buffer = _cachedPixelBuffer {
            pushFrame(pixelBuffer: buffer)
        }
    }

    private func pushFrame(pixelBuffer: CVPixelBuffer) {
        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        timingInfo.duration = CMTime(value: 1, timescale: 2) // 0.5s (2 FPS)

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let format = formatDescription else { return }

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard let buffer = sampleBuffer else { return }

        stream.send(
            buffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        )
    }

    // MARK: - Imagen → PixelBuffer

    private func loadImageAsPixelBuffer(path: String) -> CVPixelBuffer? {
        guard let data = FileManager.default.contents(atPath: path),
              let ciImage = CIImage(data: data) else {
            logger.warning("No se pudo cargar la imagen: \(path)")
            return nil
        }

        let context = CIContext()
        let w = Int(width)
        let h = Int(height)

        // Escalar la imagen para que llene el frame (720p)
        let scaleX = CGFloat(w) / ciImage.extent.width
        let scaleY = CGFloat(h) / ciImage.extent.height
        let scale = max(scaleX, scaleY)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Centrar y recortar
        let offsetX = (scaled.extent.width - CGFloat(w)) / 2
        let offsetY = (scaled.extent.height - CGFloat(h)) / 2
        let cropped = scaled.cropped(to: CGRect(x: offsetX, y: offsetY, width: CGFloat(w), height: CGFloat(h)))

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            w, h,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard let buffer = pixelBuffer else { return nil }

        context.render(cropped, to: buffer)
        return buffer
    }

    private func createBlackPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width), Int(height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let baseAddress = CVPixelBufferGetBaseAddress(buffer)
        memset(baseAddress, 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        return buffer
    }

    // MARK: - Helpers

    private func fileModificationDate(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private static func createFormatDescription(width: Int32, height: Int32) -> CMFormatDescription {
        var formatDescription: CMFormatDescription!
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        return formatDescription
    }
}
