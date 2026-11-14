import AVFoundation

/// Decodes raw Opus packets to float PCM using the system AudioToolbox codec.
final class OpusDecoder {
    let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(channels: Int) {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(1, min(channels, 2))),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard
            let input = AVAudioFormat(streamDescription: &description),
            let output = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
            let converter = AVAudioConverter(from: input, to: output)
        else { return nil }
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    func reset() {
        converter.reset()
    }

    /// Drains the frames the codec is still holding once the last packet has been decoded.
    func finish() -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 5_760) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard !packet.isEmpty else { return nil }
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: packet.count)
        }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count)
        )

        // An Opus packet holds at most 120 ms of audio.
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 5_760) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
