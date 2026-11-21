import AVFoundation

/// Whole-file decoding to mono at a chosen rate, for analysis front-ends that need more
/// bandwidth than `TrackAnalyzer.decodeMono`'s 12 kHz (such as a beat model's 22.05 kHz
/// spectrogram). Times line up with `TrackAnalyzer.decodeMono`: both start at the first
/// decoded sample of the file.
enum AudioDecode {
    /// Mono samples at the file's own rate (48 kHz for Opus).
    static func mono(file: URL) -> (samples: [Float], rate: Double)? {
        if file.pathExtension.lowercased() == "webm" {
            let demuxer = WebMDemuxer(source: FileByteSource(url: file))
            var decoder: OpusDecoder?
            var samples: [Float] = []
            samples.reserveCapacity(48_000 * 300)
            while case .packet(let packet) = demuxer.next() {
                if decoder == nil { decoder = OpusDecoder(channels: demuxer.track?.channels ?? 2) }
                guard let buffer = decoder?.decode(packet.data), let channels = buffer.floatChannelData else { continue }
                let left = channels[0]
                let right = channels[min(1, Int(buffer.format.channelCount) - 1)]
                for frame in 0 ..< Int(buffer.frameLength) { samples.append((left[frame] + right[frame]) * 0.5) }
            }
            return samples.isEmpty ? nil : (samples, 48_000)
        }
        guard let audio = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_384)
        else { return nil }
        var samples: [Float] = []
        while audio.framePosition < audio.length, (try? audio.read(into: buffer)) != nil, buffer.frameLength > 0,
              let channels = buffer.floatChannelData {
            let left = channels[0]
            let right = channels[min(1, Int(buffer.format.channelCount) - 1)]
            for frame in 0 ..< Int(buffer.frameLength) { samples.append((left[frame] + right[frame]) * 0.5) }
        }
        return samples.isEmpty ? nil : (samples, audio.processingFormat.sampleRate)
    }

    /// Both channels at the file's own rate (48 kHz for Opus), for stem separation.
    ///
    /// `offset`: seconds to add to `index / rate` to get the time playback gives that sample.
    /// Playback (`OpusReader`) labels audio with the container's packet times, while this
    /// counts from the first decoded sample, and the system's Opus decoder swallows part of the
    /// stream's priming samples (about 6.5 ms) in the first packet. Removing a stem 6.5 ms out of
    /// step adds bass instead of taking it away, so the offset is read off the second packet.
    static func stereo(file: URL) -> (left: [Float], right: [Float], rate: Double, offset: Double)? {
        var left: [Float] = []
        var right: [Float] = []
        if file.pathExtension.lowercased() == "webm" {
            let demuxer = WebMDemuxer(source: FileByteSource(url: file))
            var decoder: OpusDecoder?
            var offset: Double?
            left.reserveCapacity(48_000 * 300)
            right.reserveCapacity(48_000 * 300)
            while case .packet(let packet) = demuxer.next() {
                if decoder == nil { decoder = OpusDecoder(channels: demuxer.track?.channels ?? 2) }
                guard let buffer = decoder?.decode(packet.data), let channels = buffer.floatChannelData else { continue }
                if offset == nil, !left.isEmpty {
                    // This packet's first sample sits at index left.count and plays at its time.
                    offset = Double(packet.timeNs) / 1_000_000_000 - Double(left.count) / 48_000
                }
                let count = Int(buffer.frameLength)
                left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
                right.append(contentsOf: UnsafeBufferPointer(start: channels[min(1, Int(buffer.format.channelCount) - 1)], count: count))
            }
            return left.isEmpty ? nil : (left, right, 48_000, offset ?? 0)
        }
        guard let audio = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_384)
        else { return nil }
        while audio.framePosition < audio.length, (try? audio.read(into: buffer)) != nil, buffer.frameLength > 0,
              let channels = buffer.floatChannelData {
            let count = Int(buffer.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[min(1, Int(buffer.format.channelCount) - 1)], count: count))
        }
        return left.isEmpty ? nil : (left, right, audio.processingFormat.sampleRate, 0)
    }

    /// Band-limited sample-rate conversion through Core Audio.
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float]? {
        guard source != target else { return samples }
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(inBuffer.floatChannelData![0], $0.baseAddress!, samples.count * 4) }
        let capacity = AVAudioFrameCount(Double(samples.count) * target / source) + 4_096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, state in
            if supplied {
                state.pointee = .endOfStream
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return inBuffer
        }
        guard status != .error, error == nil else { return nil }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }

    /// Mono at `rate` (22 050 Hz by default, the rate the beat model was trained at).
    static func mono(file: URL, rate: Double) -> [Float]? {
        guard let (samples, source) = mono(file: file) else { return nil }
        return resample(samples, from: source, to: rate)
    }

    /// Writes mono float samples as a WAV file.
    static func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress! + start, count * 4) }
            try file.write(from: buffer)
            start += count
        }
    }
}
