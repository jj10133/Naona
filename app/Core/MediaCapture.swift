import AVFoundation
import VideoToolbox
import Foundation

protocol MediaCaptureDelegate: AnyObject {
    func capture(_ capture: MediaCapture, didEncodeVideo data: Data)
    func capture(_ capture: MediaCapture, didEncodeAudio data: Data)
}

final class MediaCapture: NSObject {

    weak var delegate: MediaCaptureDelegate?

    var isAudioMuted    = false
    var isVideoMuted    = false
    private var _frameIndex: Int64 = 0

    private var session:          AVCaptureSession?
    private var previewLayer:     AVCaptureVideoPreviewLayer?
    private var videoCompression: VTCompressionSession?
    private var audioConverter:   AVAudioConverter?
    private var outputFormat:     AVAudioFormat?
    private(set) var encodedSampleRate: Double = 44100
    private(set) var encodedChannels:   UInt32 = 1

    private let videoQueue = DispatchQueue(label: "naona.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "naona.audio", qos: .userInteractive)

    func start(position: AVCaptureDevice.Position = .front) {
        let s = AVCaptureSession()
        s.sessionPreset = .hd1280x720
        session = s

        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: cam), s.canAddInput(input) {
            s.addInput(input)
        }

        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), s.canAddInput(input) {
            s.addInput(input)
        }

        let vo = AVCaptureVideoDataOutput()
        vo.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        vo.setSampleBufferDelegate(self, queue: videoQueue)
        if s.canAddOutput(vo) { s.addOutput(vo) }

        let ao = AVCaptureAudioDataOutput()
        ao.setSampleBufferDelegate(self, queue: audioQueue)
        if s.canAddOutput(ao) { s.addOutput(ao) }

        previewLayer = AVCaptureVideoPreviewLayer(session: s)
        previewLayer?.videoGravity = .resizeAspectFill

        _setupVideoCompressor()
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    func stop() {
        session?.stopRunning()
        session = nil
        previewLayer = nil
        if let c = videoCompression { VTCompressionSessionInvalidate(c) }
        videoCompression = nil
        audioConverter = nil
    }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer? { previewLayer }

    private func _setupVideoCompressor() {
        var cs: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil,
            width: 1280, height: 720,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard status == noErr, let buf = sampleBuffer, let ref = refcon else { return }
                Unmanaged<MediaCapture>.fromOpaque(ref).takeUnretainedValue()._onEncodedVideo(buf)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &cs
        )
        guard let cs else { return }
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_RealTime,                value: kCFBooleanTrue)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_ProfileLevel,            value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AverageBitRate,          value: 800_000 as CFNumber)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,     value: 60 as CFNumber)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AllowFrameReordering,    value: kCFBooleanFalse)
        // Emit SPS+PPS inline with every keyframe
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_H264EntropyMode,         value: kVTH264EntropyMode_CABAC)
        VTCompressionSessionPrepareToEncodeFrames(cs)
        videoCompression = cs
    }

    private func _appendParameterSets(from avcc: Data, into data: inout Data) {
        // avcC format: [1:version][1:profile][1:compat][1:level][1:nal_len-1][1:num_sps]
        //              [2:sps_len][sps_bytes]...[1:num_pps][2:pps_len][pps_bytes]...
        let bytes = [UInt8](avcc)
        guard bytes.count > 6 else { return }
        var i = 5  // skip version/profile/compat/level/nal_size
        let numSPS = Int(bytes[i] & 0x1F); i += 1
        for _ in 0..<numSPS {
            guard i + 2 <= bytes.count else { return }
            let len = Int(bytes[i]) << 8 | Int(bytes[i+1]); i += 2
            guard i + len <= bytes.count else { return }
            let lenBE = UInt32(len).bigEndian
            data.append(contentsOf: withUnsafeBytes(of: lenBE) { Array($0) })
            data.append(contentsOf: bytes[i..<(i+len)]); i += len
        }
        guard i < bytes.count else { return }
        let numPPS = Int(bytes[i]); i += 1
        for _ in 0..<numPPS {
            guard i + 2 <= bytes.count else { return }
            let len = Int(bytes[i]) << 8 | Int(bytes[i+1]); i += 2
            guard i + len <= bytes.count else { return }
            let lenBE = UInt32(len).bigEndian
            data.append(contentsOf: withUnsafeBytes(of: lenBE) { Array($0) })
            data.append(contentsOf: bytes[i..<(i+len)]); i += len
        }
    }

    private func _onEncodedVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isVideoMuted,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Check if this is a keyframe — if so, prepend SPS+PPS from format description
        let isKeyframe: Bool = {
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
                  CFArrayGetCount(atts) > 0 else { return false }
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            let val = CFDictionaryGetValue(dict, key)
            return val == nil  // NotSync absent = sync (keyframe)
        }()

        var frameData = Data()

        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Extract SPS+PPS via extensions dictionary
            // kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms contains
            // the avcC box which has the parameter sets
            let exts = CMFormatDescriptionGetExtensions(fmt) as? [String: Any]
            let atoms = exts?["SampleDescriptionExtensionAtoms"] as? [String: Any]
            if let avcc = atoms?["avcC"] as? Data, avcc.count > 8 {
                // Parse avcC box: skip 6-byte header, then read SPS and PPS
                _appendParameterSets(from: avcc, into: &frameData)
            }
        }

        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &ptr)
        guard let ptr, length > 0 else { return }
        frameData.append(Data(bytes: ptr, count: length))
        DispatchQueue.main.async { self.delegate?.capture(self, didEncodeVideo: frameData) }
    }
}

extension MediaCapture: AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            guard !isVideoMuted,
                  let cs = videoCompression,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            _frameIndex += 1
            // Force keyframe every 2 seconds (60 frames) or on first frame
            var frameProps: CFDictionary? = nil
            if _frameIndex == 1 || _frameIndex % 60 == 0 {
                frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }
            VTCompressionSessionEncodeFrame(cs, imageBuffer: imageBuffer,
                presentationTimeStamp: pts, duration: .invalid,
                frameProperties: frameProps, sourceFrameRefcon: nil, infoFlagsOut: nil)

        } else if output is AVCaptureAudioDataOutput {
            guard !isAudioMuted else { return }
            _encodeAudio(sampleBuffer)
        }
    }

    private func _encodeAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        if audioConverter == nil {
            let inputFormat = AVAudioFormat(streamDescription: streamDesc)!
            let outputFormat = AVAudioFormat(
                commonFormat:  .pcmFormatFloat32,
                sampleRate:    streamDesc.pointee.mSampleRate,
                channels:      streamDesc.pointee.mChannelsPerFrame,
                interleaved:   false
            )!
            self.outputFormat = outputFormat

            // Use AVAudioFormat directly for AAC-LC — avoids ASBD misconfiguration
            guard let aacFormat = AVAudioFormat(
                commonFormat:  .pcmFormatFloat32,
                sampleRate:    streamDesc.pointee.mSampleRate,
                channels:      streamDesc.pointee.mChannelsPerFrame,
                interleaved:   false
            ) else { return }

            // Build AAC output format via settings dict — most reliable approach
            let aacSettings: [String: Any] = [
                AVFormatIDKey:            kAudioFormatMPEG4AAC,
                AVSampleRateKey:          streamDesc.pointee.mSampleRate,
                AVNumberOfChannelsKey:    streamDesc.pointee.mChannelsPerFrame,
                AVEncoderBitRateKey:      64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            guard let aacOutputFormat = AVAudioFormat(settings: aacSettings) else { return }
            audioConverter = AVAudioConverter(from: inputFormat, to: aacOutputFormat)
        }

        guard let converter = audioConverter,
              let inputFormat = converter.inputFormat as AVAudioFormat?,
              let outputFormat = converter.outputFormat as AVAudioFormat?
        else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
        else { return }
        inputBuffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        var audioBufferListSize = Int(MemoryLayout<AudioBufferList>.size)
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &audioBufferListSize,
            bufferListOut: &audioBufferList,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        let dstList = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        withUnsafePointer(to: audioBufferList.mBuffers) { ptr in
            let count = min(Int(audioBufferList.mNumberBuffers), dstList.count)
            let buffers = UnsafeBufferPointer(start: ptr, count: count)
            for i in 0..<count {
                memcpy(dstList[i].mData, buffers[i].mData, Int(buffers[i].mDataByteSize))
                dstList[i].mDataByteSize = buffers[i].mDataByteSize
            }
        }

        let outputBuffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 8,
            maximumPacketSize: converter.maximumOutputPacketSize
        )

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if inputConsumed { status.pointee = .noDataNow; return nil }
            inputConsumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard error == nil, outputBuffer.packetCount > 0 else { return }
        // Send raw bytes as-is — includes ADTS header if AVAudioConverter adds one
        // Receiver uses same format settings so it can decode directly
        let raw = Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
        DispatchQueue.main.async { self.delegate?.capture(self, didEncodeAudio: raw) }
    }
}
