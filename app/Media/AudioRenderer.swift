// Media/AudioRenderer.swift
// Plays raw S16 interleaved PCM buffers via AVAudioEngine.
// One instance per remote peer.

import AVFoundation

final class AudioRenderer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate:   48000,  // opus outputs at 48000Hz
        channels:     2,
        interleaved:  true
    )!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            print("[AudioRenderer] engine start error: \(error)")
        }
        player.play()
    }

    /// Schedule a PCM buffer for playback. Safe to call from any thread.
    func render(pcm: Data) {
        let frameCount = pcm.count / 4   // 2 ch × 2 bytes (S16)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount))
        else { return }

        buf.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress,
                  let dst = buf.int16ChannelData?.pointee
            else { return }
            memcpy(dst, src, pcm.count)
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
