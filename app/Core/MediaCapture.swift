import AVFoundation
import VideoToolbox
import Foundation

protocol MediaCaptureDelegate: AnyObject {
    func capture(_ capture: MediaCapture, didEncodeVideo data: Data)
    func capture(_ capture: MediaCapture, didEncodeAudio data: Data)
}

final class MediaCapture: NSObject {

    weak var delegate: MediaCaptureDelegate?

    var isAudioMuted = false
    var isVideoMuted = false

    private var session:          AVCaptureSession?
    private var previewLayer:     AVCaptureVideoPreviewLayer?
    private var videoCompression: VTCompressionSession?
    private var audioConverter:   AVAudioConverter?
    private var outputFormat:     AVAudioFormat?

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
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_RealTime,           value: kCFBooleanTrue)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_ProfileLevel,        value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AverageBitRate,      value: 800_000 as CFNumber)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(cs)
        videoCompression = cs
    }

    private func _onEncodedVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isVideoMuted,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &ptr)
        guard let ptr, length > 0 else { return }
        let data = Data(bytes: ptr, count: length)
        DispatchQueue.main.async { self.delegate?.capture(self, didEncodeVideo: data) }
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
            VTCompressionSessionEncodeFrame(cs, imageBuffer: imageBuffer,
                presentationTimeStamp: pts, duration: .invalid,
                frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)

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
        let data = Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
        DispatchQueue.main.async { self.delegate?.capture(self, didEncodeAudio: data) }
    }
}
