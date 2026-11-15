import Foundation
import Metal
import CoreMedia
import CoreVideo
import VideoToolbox

/// The remote stream is compressed; native dimensions do not imply lossless
/// chroma. The local Retina presenter is never passed through this encoder.
final class LinkEncoder {
    let mode: LinkMode
    private let mirrorsPrimary:Bool
    private let device: MTLDevice
    private let plain: MTLRenderPipelineState, linear: MTLRenderPipelineState, cursor: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let slots = DispatchSemaphore(value: 3)
    private let credits = LinkFrameCredits()
    private var acknowledged: UInt64 = 0
    private var worstRoundTripMS = 0.0
    private let work = DispatchQueue(label: "henge.link.encoder", qos: .userInitiated)
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool
    private var cache: CVMetalTextureCache
    private let lock = NSLock()
    private var stopped = false, captured: UInt64 = 0, congested: UInt64 = 0
    private var visible = true, visibilityEpoch: UInt64 = 0
    private var budget=LinkCaptureBudget()
    private var refreshQueued=false,deferredFrame=false
    private let requestFrame:()->Void
    private var sequence: UInt64 = 0
    private let send: (Data, @escaping (Bool) -> Void) -> Void
    private let report: (String) -> Void
    private final class Ticket {
        let owner: LinkEncoder
        let epoch: UInt64
        init(_ owner: LinkEncoder, epoch: UInt64) { self.owner = owner; self.epoch = epoch }
    }
    init(mode: LinkMode, mirrorsPrimary:Bool = false, library: MTLLibrary? = nil, requestFrame:@escaping ()->Void = {}, send: @escaping (Data, @escaping (Bool) -> Void) -> Void, report: @escaping (String) -> Void) throws {
        guard #available(iOS 17.4, *) else { throw LinkError.invalid("Henge Link hardware encoding requires iOS/iPadOS 17.4 or later") }
        try mode.validate(); guard mode.codedWidth * mode.codedHeight <= 33_554_432 else { throw LinkError.invalid("Codec canvas exceeds the supported size") }; self.mode = mode;self.mirrorsPrimary=mirrorsPrimary;self.requestFrame=requestFrame; self.send = send; self.report = report
        guard let device = MTLCreateSystemDefaultDevice(), let lib = library ?? device.makeDefaultLibrary() else { throw LinkError.invalid("Native Metal shaders unavailable") }
        self.device = device
        func pipeline(_ fragment: String, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor(); d.vertexFunction = lib.makeFunction(name: "screen_v"); d.fragmentFunction = lib.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true; a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        plain = try pipeline("screen_plain"); linear = try pipeline("screen_linear"); cursor = try pipeline("screen_cursor", blend: true)
        let sd = MTLSamplerDescriptor(); sd.minFilter = .nearest; sd.magFilter = .nearest
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw LinkError.invalid("Metal sampler unavailable") }; self.sampler = sampler
        var createdPool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: mode.codedWidth, kCVPixelBufferHeightKey as String: mode.codedHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &createdPool) == noErr, let createdPool else { throw LinkError.invalid("Video pixel pool unavailable") }; pool = createdPool
        var createdCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &createdCache) == noErr, let createdCache else { throw LinkError.invalid("Video Metal texture cache unavailable") }; cache = createdCache
        var selected = ""
        let candidates: [(CMVideoCodecType, Bool)] = [(kCMVideoCodecType_HEVC, true), (kCMVideoCodecType_H264, true), (kCMVideoCodecType_HEVC, false), (kCMVideoCodecType_H264, false)]
        for (codec, lowLatency) in candidates {
            var candidate: VTCompressionSession?
            var options: [String: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
            if lowLatency { options[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true }
            let specification = options as CFDictionary
            let status = VTCompressionSessionCreate(allocator: nil, width: Int32(mode.codedWidth), height: Int32(mode.codedHeight), codecType: codec,
                encoderSpecification: specification, imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
                outputCallback: { _, source, status, _, sample in
                    guard let source else { return }
                    let ticket = Unmanaged<Ticket>.fromOpaque(source).takeRetainedValue()
                    ticket.owner.work.async { ticket.owner.encoded(status: status, sample: sample, epoch: ticket.epoch) }
                }, refcon: nil, compressionSessionOut: &candidate)
            guard status == noErr, let candidate else { continue }
            func set(_ key: CFString, _ value: CFTypeRef) -> Bool {
                let status = VTSessionSetProperty(candidate, key: key, value: value)
                if status != noErr { report("encoder property \(key) unavailable: \(status)") }
                return status == noErr
            }
            let okay = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue) && set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
                && set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: mode.hz))
                && set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: mode.hz * 2))
                && (lowLatency ? set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: max(12_000_000, Int(Double(mode.width * mode.height * mode.hz) * 0.35)))) : set(kVTCompressionPropertyKey_Quality, NSNumber(value: 0.9)))
                && set(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
                && set(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_sRGB)
                && set(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
            if okay && VTCompressionSessionPrepareToEncodeFrames(candidate) == noErr { session = candidate; selected = (codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264") + (lowLatency ? " low-latency" : " realtime fallback"); break }
            VTCompressionSessionInvalidate(candidate)
        }
        guard session != nil else { throw LinkError.invalid("No supported hardware encoder for this native resolution. The iPad display is unchanged.") }
        report("hardware encoder \(selected) \(mode.width)x\(mode.height) target=\(mode.hz)Hz; codec canvas=\(mode.codedWidth)x\(mode.codedHeight), visible pixels unchanged; decode-ack-window=3, no CPU pixel readback")
    }
    /// Called synchronously by the serial guest GPU worker. Commit on its queue
    /// before returning so later guest writes cannot overtake this snapshot.
    func capture(texture: MTLTexture, queue: MTLCommandQueue, halfMode: UInt32, cursorTexture: MTLTexture?, rect: SIMD4<Float>) {
        lock.lock(); let active = !stopped && visible; let epoch = visibilityEpoch; lock.unlock(); guard active else { return }
        guard mirrorsPrimary || (texture.width == mode.width && texture.height == mode.height) else { return }
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock();let delay=budget.delay(now:now)
        let arrange=delay>0 && !refreshQueued
        if arrange { refreshQueued=true }
        lock.unlock()
        if delay>0 {
            if arrange { work.asyncAfter(deadline:.now()+delay) { [self] in
                lock.lock();let refresh = !stopped && visible && epoch==visibilityEpoch
                if epoch==visibilityEpoch { refreshQueued=false };lock.unlock()
                if refresh { requestFrame() }
            } }
            return
        }
        guard slots.wait(timeout: .now()) == .success else {
            lock.lock();deferredFrame=true; congested &+= 1; let n = congested; lock.unlock()
            if n == 1 || n % 120 == 0 { report("remote capture backpressure=\(n); primary display/guest completions unchanged") }; return
        }
        lock.lock();budget.accepted(now:now,hz:mode.hz);lock.unlock()
        var pixel: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &pixel) == noErr, let pixel else { slots.signal(); return }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixel, nil, .bgra8Unorm, mode.codedWidth, mode.codedHeight, 0, &cvTexture) == noErr,
              let cvTexture, let target = CVMetalTextureGetTexture(cvTexture), let command = queue.makeCommandBuffer() else { slots.signal(); return }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        let padded = mode.codedWidth != mode.width || mode.codedHeight != mode.height
        pass.colorAttachments[0].loadAction = padded ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let e = command.makeRenderCommandEncoder(descriptor: pass) else { slots.signal(); return }
        let contentW = Float(mode.width) / Float(mode.codedWidth) * 2
        let contentH = Float(mode.height) / Float(mode.codedHeight) * 2
        var full = SIMD4<Float>(-1, 1 - contentH, contentW, contentH), modeValue = halfMode
        let half = texture.pixelFormat == .rgba16Float
        e.setRenderPipelineState(half ? linear : plain)
        e.setVertexBytes(&full, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        e.setFragmentTexture(texture, index: 0); e.setFragmentSamplerState(sampler, index: 0)
        if half { e.setFragmentBytes(&modeValue, length: 4, index: 0) }
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if let cursorTexture {
            var r = SIMD4<Float>(rect.x / Float(mode.codedWidth) * 2 - 1, 1 - (rect.y + rect.w) / Float(mode.codedHeight) * 2, rect.z / Float(mode.codedWidth) * 2, rect.w / Float(mode.codedHeight) * 2)
            e.setRenderPipelineState(cursor); e.setVertexBytes(&r, length: 16, index: 0)
            e.setFragmentTexture(cursorTexture, index: 0); e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        e.endEncoding(); command.label = mirrorsPrimary ? "Henge Link primary mirror snapshot" : "Henge Link port 1 snapshot"
        let stamp = CMClockGetTime(CMClockGetHostTimeClock())
        command.addCompletedHandler { [self, pixel, cvTexture, texture, cursorTexture] done in
            _ = cvTexture; _ = texture; _ = cursorTexture // keep aliased resources alive until the GPU completes
            guard done.status == .completed else { slots.signal(); report("Link GPU snapshot failed"); return }
            work.async { [self] in
                lock.lock(); let active = !stopped && visible && epoch == visibilityEpoch; lock.unlock()
                guard active, let session else { slots.signal(); return }
                let ticket = Unmanaged.passRetained(Ticket(self, epoch: epoch))
                let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: stamp, duration: CMTime(value: 1, timescale: Int32(mode.hz)), frameProperties: nil, sourceFrameRefcon: ticket.toOpaque(), infoFlagsOut: nil)
                if status != noErr { ticket.release(); slots.signal(); report("Hardware encode failed: \(status)") }
            }
        }
        command.commit()
        lock.lock(); captured &+= 1; let n = captured; lock.unlock()
        if n == 1 { report(mirrorsPrimary ? "first primary mirror Metal frame captured" : "first independent port-1 Metal frame captured") }
    }
    private func encoded(status: OSStatus, sample: CMSampleBuffer?, epoch: UInt64) {
        lock.lock(); let mayEncode = !stopped && visible && epoch == visibilityEpoch; lock.unlock()
        guard mayEncode else { slots.signal(); return }
        guard status == noErr, let sample, CMSampleBufferDataIsReady(sample), let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { slots.signal(); report("Hardware encoder produced no frame: \(status)"); return }
        let hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
        var sets = [Data]()
        for i in 0..<(hevc ? 3 : 2) {
            var ptr: UnsafePointer<UInt8>?, length = 0, count = 0, nal: Int32 = 0
            let result: OSStatus
            if hevc { result = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &length, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nal) }
            else { result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &length, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nal) }
            guard result == noErr, nal == 4, let ptr, length <= 16384 else { slots.signal(); return }; sets.append(Data(bytes: ptr, count: length))
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length < LinkPacket.maximum - 65540 else { slots.signal(); return }
        var bytes = Data(count: length)
        let copied = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { slots.signal(); return }
        // VT output is serialized by the encoder when reordering is disabled.
        let n=LinkFrameSequence.next()
        lock.lock(); sequence=n; let active = !stopped && visible && epoch == visibilityEpoch; lock.unlock()
        guard active else { slots.signal(); return }
        do {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            guard dimensions.width == mode.codedWidth, dimensions.height == mode.codedHeight else { slots.signal(); report("Encoder changed the requested codec canvas"); return }
            let data = try LinkVideoHeader(codec: hevc ? "hevc" : "h264", width: mode.width, height: mode.height, sequence: n, parameterSets: sets, codedWidth: mode.codedWidth, codedHeight: mode.codedHeight).pack(bytes)
            guard credits.begin(n) else { slots.signal(); report("Invalid frame credit state"); return }
            send(data) { [self] okay in
                if !okay { lock.lock(); stopped = true; lock.unlock() }
                if let receipt = credits.sent(n, success: okay) { retire(receipt) }
                if n == 1 || n % 600 == 0 { report("video sequence=\(n) bytes=\(length) transport=\(okay ? "sent" : "disconnected"); awaiting decoder consumption") }
            }
        } catch { slots.signal(); report(error.localizedDescription) }
    }
    func acknowledge(_ sequence: UInt64) {
        if let receipt = credits.consumed(sequence) { retire(receipt) }
    }
    func setVisible(_ value: Bool) {
        lock.lock()
        if visible != value { visible = value; visibilityEpoch &+= 1;refreshQueued=false;deferredFrame=false;budget.reset() }
        lock.unlock()
    }
    func trimMemory() {
        work.async { [self] in
            CVMetalTextureCacheFlush(cache, 0)
            CVPixelBufferPoolFlush(pool, .excessBuffers)
        }
    }
    private func retire(_ receipt: LinkFrameCredits.Receipt) {
        slots.signal()
        lock.lock();let refresh=deferredFrame && !stopped && visible;deferredFrame=false;lock.unlock()
        if refresh { requestFrame() }
        guard receipt.consumed else { return }
        lock.lock(); acknowledged &+= 1; let count = acknowledged
        worstRoundTripMS = max(worstRoundTripMS, receipt.seconds * 1000)
        let worst = worstRoundTripMS; lock.unlock()
        if count == 1 || count % 600 == 0 {
            report(String(format: "decode-ack=%llu pending=%d/3 max-consume-roundtrip-ms=%.2f; primary display and guest completions unchanged", count, credits.pending, worst))
        }
    }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        work.async { [self] in
            if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session); self.session = nil }
            for _ in 0..<credits.cancel() { slots.signal() }
        }
    }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}

final class LinkDecoder {
    private var session: VTDecompressionSession?
    private var sets = [Data](), codec = ""
    private var format: CMVideoFormatDescription?
    private var sequence: UInt64 = 0
    private var codedWidth = 0, codedHeight = 0
    private let mode: LinkMode
    private let output: (CVPixelBuffer) -> Void
    private let outputLock = NSLock()
    private var outputStatus: OSStatus = noErr
    init(mode: LinkMode, output: @escaping (CVPixelBuffer) -> Void) { self.mode = mode; self.output = output }
    @discardableResult func decode(_ payload: Data) throws -> UInt64 {
        guard #available(iOS 17.4, *) else { throw LinkError.invalid("Hardware display decoding requires iOS 17.4 or later") }
        let (header, bytes) = try LinkVideoHeader.unpack(payload)
        guard header.width == mode.width, header.height == mode.height, header.sequence > sequence else { throw LinkError.invalid("Video mode or sequence changed; reconnect") }
        sequence = header.sequence
        if sets != header.parameterSets || codec != header.codec || codedWidth != header.encodedWidth || codedHeight != header.encodedHeight {
            if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session); self.session = nil }
            sets = header.parameterSets; codec = header.codec
            codedWidth = header.encodedWidth; codedHeight = header.encodedHeight
            // NSData owners keep each parameter-set pointer alive during creation.
            let owners = sets.map { $0 as NSData }
            var pointers = owners.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }, sizes = owners.map { $0.length }
            var desc: CMFormatDescription?
            let result: OSStatus
            if codec == "hevc" { result = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc) }
            else { result = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc) }
            guard result == noErr, let desc else { throw LinkError.invalid("Invalid compressed video format: \(result)") }
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            guard dimensions.width == codedWidth, dimensions.height == codedHeight else { throw LinkError.invalid("Codec dimensions do not match the paired display") }
            format = desc
            var record = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, image, _, _ in
                guard let context else { return }
                let owner = Unmanaged<LinkDecoder>.fromOpaque(context).takeUnretainedValue()
                if status != noErr { owner.outputLock.lock(); owner.outputStatus = status; owner.outputLock.unlock() }
                else if let image { owner.deliver(image) }
            }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
            let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
            let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true] as CFDictionary
            let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: specification, imageBufferAttributes: attrs, outputCallback: &record, decompressionSessionOut: &session)
            guard status == noErr else { throw LinkError.invalid("Hardware decoder unavailable: \(status)") }
            if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        }
        guard let session, let format else { throw LinkError.invalid("Decoder configuration is unavailable") }
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw LinkError.invalid("Decoder buffer allocation failed") }
        let copied = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        var sample: CMSampleBuffer?, size = bytes.count
        let created = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard copied == noErr, created == noErr, let sample else { throw LinkError.invalid("Decoder sample failed") }
        // Synchronous decode bounds outstanding frames and avoids a dangling
        // output refcon during disconnect. Network receive runs on its own queue.
        outputLock.lock(); outputStatus = noErr; outputLock.unlock()
        let decoded = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        guard decoded == noErr else { throw LinkError.invalid("Decode failed: \(decoded)") }
        outputLock.lock(); let result = outputStatus; outputLock.unlock()
        guard result == noErr else { throw LinkError.invalid("Hardware output failed: \(result)") }
        return header.sequence
    }
    private func deliver(_ image: CVPixelBuffer) {
        // Core Media's clean aperture keeps the original top-left native image
        // and excludes only the encoder's right/bottom padding. The video layer
        // receives the presentation size rather than stretching the canvas.
        if codedWidth != mode.width || codedHeight != mode.height {
            let aperture: [String: Any] = [
                kCVImageBufferCleanApertureWidthKey as String: mode.width,
                kCVImageBufferCleanApertureHeightKey as String: mode.height,
                kCVImageBufferCleanApertureHorizontalOffsetKey as String: Double(mode.width - codedWidth) / 2,
                kCVImageBufferCleanApertureVerticalOffsetKey as String: Double(mode.height - codedHeight) / 2]
            CVBufferSetAttachment(image, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
        }
        output(image)
    }
    deinit { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) } }
}
