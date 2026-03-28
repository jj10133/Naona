// Media/VideoSurface.swift
// Decodes VP8 via VTDecompressionSession and displays via AVSampleBufferDisplayLayer.

import AVFoundation
import VideoToolbox
import CoreMedia

#if os(iOS)
import UIKit
typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
typealias PlatformView = NSView
#endif

final class VideoSurface: PlatformView {

    let displayLayer   = AVSampleBufferDisplayLayer()
    private var decomSession:   VTDecompressionSession?
    private var formatDesc:     CMVideoFormatDescription?
    private let WIDTH:  Int32  = 1280
    private let HEIGHT: Int32  = 720

    override init(frame: CGRect) {
        super.init(frame: frame)
        _setup()
        _buildFormatAndSession()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Feed VP8 packet

    func enqueue(h264 pts: UInt32, data: Data) {
        _decodeAndDisplay(pts: pts, data: data)
    }

    // MARK: - Setup

    private func _setup() {
        #if os(iOS)
        layer.addSublayer(displayLayer)
        backgroundColor = .black
        #elseif os(macOS)
        wantsLayer = true
        layer?.addSublayer(displayLayer)
        layer?.backgroundColor = NSColor.black.cgColor
        #endif
        displayLayer.videoGravity = .resizeAspectFill
    }

    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
    #elseif os(macOS)
    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
    #endif

    // MARK: - VP8 format description + decompression session

    private func _buildFormatAndSession() {
        // VP8 codec type: 'vp08'
        let vp8: CMVideoCodecType = 0x76703038

        // Create format description for VP8 1280x720
        var fmtDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreate(
            allocator:          nil,
            codecType:          vp8,
            width:              WIDTH,
            height:             HEIGHT,
            extensions:         nil,
            formatDescriptionOut: &fmtDesc
        )
        guard fmtStatus == noErr, let fmtDesc else {
            print("[VideoSurface] failed to create VP8 format desc: \(fmtStatus)")
            return
        }
        self.formatDesc = fmtDesc

        // Destination pixel format: 32BGRA for display
        let destFmt: OSType = kCVPixelFormatType_32BGRA
        let destAttrs = [
            kCVPixelBufferPixelFormatTypeKey: destFmt,
            kCVPixelBufferWidthKey:           WIDTH,
            kCVPixelBufferHeightKey:          HEIGHT,
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: _decompressionCallback,
            decompressionOutputRefCon:   Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator:                  nil,
            formatDescription:          fmtDesc,
            decoderSpecification:       nil,
            imageBufferAttributes:      destAttrs,
            outputCallback:             &outputCallback,
            decompressionSessionOut:    &session
        )

        if sessionStatus == noErr, let session {
            self.decomSession = session
            print("[VideoSurface] VP8 VTDecompressionSession ready")
        } else {
            print("[VideoSurface] VTDecompressionSession failed: \(sessionStatus)")
            // Fallback: try direct enqueue to displayLayer (may work on some OS versions)
        }
    }

    // MARK: - Decode and display

    private func _decodeAndDisplay(pts: UInt32, data: Data) {
        guard let formatDesc else { return }
        guard !data.isEmpty else { return }

        // Build CMSampleBuffer from raw VP8 packet
        var dataCopy  = data
        let dataLen   = dataCopy.count
        var blockBuf: CMBlockBuffer?

        dataCopy.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator:          nil,
                memoryBlock:        ptr.baseAddress,
                blockLength:        dataLen,
                blockAllocator:     kCFAllocatorNull,
                customBlockSource:  nil,
                offsetToData:       0,
                dataLength:         dataLen,
                flags:              0,
                blockBufferOut:     &blockBuf
            )
        }
        guard let blockBuf else { return }

        let ptsTime = CMTime(value: CMTimeValue(pts), timescale: 1000)
        var timing  = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: 30),
            presentationTimeStamp:  ptsTime,
            decodeTimeStamp:        .invalid
        )
        var sampleSize = dataLen
        var sampleBuf: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator:              nil,
            dataBuffer:             blockBuf,
            dataReady:              true,
            makeDataReadyCallback:  nil,
            refcon:                 nil,
            formatDescription:      formatDesc,
            sampleCount:            1,
            sampleTimingEntryCount: 1,
            sampleTimingArray:      &timing,
            sampleSizeEntryCount:   1,
            sampleSizeArray:        &sampleSize,
            sampleBufferOut:        &sampleBuf
        )
        guard let sampleBuf else { return }

        if let session = decomSession {
            // Decode via VTDecompressionSession
            var infoFlags = VTDecodeInfoFlags(rawValue: 0)
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer:    sampleBuf,
                flags:           [._EnableAsynchronousDecompression],
                frameRefcon:     nil,
                infoFlagsOut:    &infoFlags
            )
        } else {
            // Fallback: enqueue directly to displayLayer
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuf)
            }
        }
    }
}

// MARK: - VTDecompressionSession callback (C function)

private func _decompressionCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon:         UnsafeMutableRawPointer?,
    status:                    OSStatus,
    infoFlags:                 VTDecodeInfoFlags,
    imageBuffer:               CVImageBuffer?,
    presentationTimeStamp:     CMTime,
    presentationDuration:      CMTime
) {
    guard status == noErr, let imageBuffer,
          let refCon = decompressionOutputRefCon else {
        if status != noErr { print("[VideoSurface] decode error: \(status)") }
        return
    }

    let surface = Unmanaged<VideoSurface>.fromOpaque(refCon).takeUnretainedValue()

    // Convert CVPixelBuffer → CMSampleBuffer for AVSampleBufferDisplayLayer
    var timingInfo = CMSampleTimingInfo(
        duration:               CMTime(value: 1, timescale: 30),
        presentationTimeStamp:  presentationTimeStamp,
        decodeTimeStamp:        .invalid
    )
    var formatDesc: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator:              nil,
        imageBuffer:            imageBuffer,
        formatDescriptionOut:   &formatDesc
    )
    guard let formatDesc else { return }

    var sampleBuf: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator:              nil,
        imageBuffer:            imageBuffer,
        formatDescription:      formatDesc,
        sampleTiming:           &timingInfo,
        sampleBufferOut:        &sampleBuf
    )
    guard let sampleBuf else { return }

    DispatchQueue.main.async {
        if surface.displayLayer.isReadyForMoreMediaData {
            surface.displayLayer.enqueue(sampleBuf)
        } else {
            surface.displayLayer.flush()
        }
    }
}
