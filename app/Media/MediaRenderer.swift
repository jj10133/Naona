// Media/MediaRenderer.swift
// One per remote peer. Renders H264 via AVSampleBufferDisplayLayer
// and plays Opus audio via AVAudioEngine with AVAudioConverter.

import AVFoundation
import Foundation

final class MediaRenderer: Identifiable {

    let id: String   // peerId

    // Video
    let videoSurface = VideoSurface(frame: .zero)

    // Audio — Opus decode via AVAudioConverter → AVAudioPlayerNode
    private let engine      = AVAudioEngine()
    private let playerNode  = AVAudioPlayerNode()
    private var converter:  AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate:   48000,
        channels:     2,
        interleaved:  false
    )!

    init(peerId: String) {
        self.id = peerId
        _setupAudio()
    }

    // MARK: - Feed frames

    func handleVideo(_ frame: VideoFrame) {
        videoSurface.enqueue(h264: frame.pts, data: frame.h264)
    }

    func handleAudio(_ frame: AudioFrame) {
        _playOpus(frame.opus, pts: frame.pts)
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    // MARK: - Audio setup

    private func _setupAudio() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        do { try engine.start() } catch { print("[MediaRenderer] audio engine error:", error) }
        playerNode.play()
    }

    // Decode Opus → PCM using AVAudioConverter
    // AVAudioConverter can decode Opus on iOS 16+ / macOS 13+
    private func _playOpus(_ opus: Data, pts: UInt32) {
        // Build AVAudioCompressedBuffer for Opus input
        // Opus format: kAudioFormatOpus
        var opusASBD = AudioStreamBasicDescription(
            mSampleRate:       48000,
            mFormatID:         kAudioFormatOpus,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  960,
            mBytesPerFrame:    0,
            mChannelsPerFrame: 2,
            mBitsPerChannel:   0,
            mReserved:         0
        )
        guard let opusFormat = AVAudioFormat(streamDescription: &opusASBD) else { return }

        if converter == nil {
            converter = AVAudioConverter(from: opusFormat, to: outputFormat)
        }
        guard let converter else { return }

        let inputBuffer = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: opus.count
        )
        inputBuffer.packetCount = 1
        inputBuffer.byteLength  = UInt32(opus.count)
        opus.withUnsafeBytes { src in
            memcpy(inputBuffer.data, src.baseAddress!, opus.count)
        }
        inputBuffer.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 960,
            mDataByteSize: UInt32(opus.count)
        )

        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: 960
        )!

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if error == nil && outputBuffer.frameLength > 0 {
            playerNode.scheduleBuffer(outputBuffer, completionHandler: nil)
        }
    }
}
