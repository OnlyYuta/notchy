import SwiftUI
import AppKit
import QuartzCore

public struct MusicVisualizerView: View {
    public var isPlaying: Bool
    public var barCount: Int = 5
    public var accentColor: Color = .white

    // Per-bar (min, max) heights; bars beyond this list reuse it cyclically
    private static let ranges: [(CGFloat, CGFloat)] = [(4, 10), (6, 13), (8, 14), (5, 12), (3.5, 9)]
    private static let restHeight: CGFloat = 3.0

    public init(isPlaying: Bool = true, barCount: Int = 5, accentColor: Color = .white) {
        self.isPlaying = isPlaying
        self.barCount = barCount
        self.accentColor = accentColor
    }

    public var body: some View {
        // Core Animation loop: no SwiftUI re-render per frame, and nothing at all while paused
        CAEqualizer(isPlaying: isPlaying, barCount: barCount)
            .frame(width: CGFloat(barCount) * CAEqualizer.barWidth + CGFloat(max(barCount - 1, 0)) * CAEqualizer.gap, height: 14.0)
    }
}

// MARK: - Core Animation versions of the looping animations
//
// A TimelineView re-renders the whole notch's SwiftUI graph on every tick (measured: ~4 ms each, so a working agent's
// dots + glow or a playing track's bars kept ~15-20% of a core busy for as long as they were on screen, and any
// open/close animation had to share frames with that work, which is what stuttered on 144 Hz). These loops run in
// Core Animation instead: the render server animates them, the app does nothing per frame.

/// Layer-backed host for the animated layers below.
final class LayerHostView: NSView {
    var glowLayer: CAGradientLayer?
    override var isFlipped: Bool { false }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        guard let glow = glowLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.bounds = CGRect(origin: .zero, size: bounds.size)
        glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

private extension CAAnimation {
    /// min -> max and back, eased like a sine, forever.
    static func pulse(_ keyPath: String, from: CGFloat, to: CGFloat, halfPeriod: CFTimeInterval, delay: CFTimeInterval = 0) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = halfPeriod
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        return a
    }
}

struct CAEqualizer: NSViewRepresentable {
    var isPlaying: Bool
    var barCount: Int
    
    // Per-bar (min, max) heights; bars beyond this list reuse it cyclically
    private static let ranges: [(CGFloat, CGFloat)] = [(4, 10), (6, 13), (8, 14), (5, 12), (3.5, 9)]
    private static let restHeight: CGFloat = 3.0
    static let barWidth: CGFloat = 2.4
    static let gap: CGFloat = 2.0
    static let height: CGFloat = 14.0
    private static let loop: Double = 6.0
    
    final class Coordinator { var playing: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    func makeNSView(context: Context) -> LayerHostView {
        let host = LayerHostView()
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            bar.backgroundColor = NSColor.white.cgColor
            host.layer?.addSublayer(bar)
        }
        return host
    }
    
    /// Bar heights from the live spectrum (0...1 per band), eased over one analysis tick
    static func setLevels(_ levels: [Float], in host: LayerHostView) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 30)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        for (idx, bar) in (host.layer?.sublayers ?? []).enumerated() {
            let level = CGFloat(levels[idx % levels.count])
            bar.bounds.size.height = restHeight + (height - restHeight) * level
        }
        CATransaction.commit()
    }
    
    static func dismantleNSView(_ host: LayerHostView, coordinator: Coordinator) {
        AudioSpectrum.shared.detach(host)
    }
    
    func updateNSView(_ host: LayerHostView, context: Context) {
        guard context.coordinator.playing != isPlaying else { return }
        context.coordinator.playing = isPlaying
        // The real thing: bars follow the player's sound. The looping animation below is only for macOS before 14.2
        if AudioSpectrum.shared.isSupported {
            for (idx, bar) in (host.layer?.sublayers ?? []).enumerated() {
                bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.restHeight)
                bar.position = CGPoint(x: Self.barWidth / 2 + CGFloat(idx) * (Self.barWidth + Self.gap), y: Self.height / 2)
                bar.opacity = isPlaying ? 1 : 0.45
            }
            if isPlaying { AudioSpectrum.shared.attach(host) } else { AudioSpectrum.shared.detach(host) }
            return
        }
        for (idx, bar) in (host.layer?.sublayers ?? []).enumerated() {
            let (lo, hi) = Self.ranges[idx % Self.ranges.count]
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.restHeight)
            bar.position = CGPoint(x: Self.barWidth / 2 + CGFloat(idx) * (Self.barWidth + Self.gap), y: Self.height / 2)
            bar.opacity = isPlaying ? 1 : 0.45
            bar.removeAnimation(forKey: "h")
            guard isPlaying else { continue }
            // Two incommensurate sines per bar (snapped to whole cycles per loop so it repeats without a seam)
            let i = Double(idx)
            func omega(_ f: Double) -> Double { 2 * .pi * (f * Self.loop / (2 * .pi)).rounded() / Self.loop }
            let w1 = omega(4.2 + i * 0.9), w2 = omega(7.1 + i * 0.6)
            let steps = 72
            let values: [CGFloat] = (0...steps).map { k in
                let t = Self.loop * Double(k) / Double(steps)
                let wave = 0.6 * sin(t * w1 + i * 1.7) + 0.4 * sin(t * w2 + i * 0.8)
                return lo + (hi - lo) * CGFloat(0.5 + 0.5 * wave)
            }
            let a = CAKeyframeAnimation(keyPath: "bounds.size.height")
            a.values = values
            a.calculationMode = .cubic
            a.duration = Self.loop
            a.repeatCount = .infinity
            bar.add(a, forKey: "h")
        }
    }
}

struct CAThreeDots: NSViewRepresentable {
    static let dot: CGFloat = 3.5
    static let gap: CGFloat = 3.5
    static let height: CGFloat = 12
    static var width: CGFloat { dot * 3 + gap * 2 }
    
    func makeNSView(context: Context) -> LayerHostView {
        let host = LayerHostView()
        for idx in 0..<3 {
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: Self.dot, height: Self.dot)
            layer.cornerRadius = Self.dot / 2
            layer.backgroundColor = NSColor.white.cgColor
            let baseY = Self.height / 2
            layer.position = CGPoint(x: Self.dot / 2 + CGFloat(idx) * (Self.dot + Self.gap), y: baseY)
            // Each dot trails the previous one by a fixed phase (travelling wave), period ~1.05 s
            let half = 2 * Double.pi / 6 / 2, delay = Double(idx) * 0.15
            layer.add(.pulse("opacity", from: 0.3, to: 1.0, halfPeriod: half, delay: delay), forKey: "o")
            layer.add(.pulse("transform.scale", from: 0.8, to: 1.25, halfPeriod: half, delay: delay), forKey: "s")
            layer.add(.pulse("position.y", from: baseY, to: baseY + 1.5, halfPeriod: half, delay: delay), forKey: "y")
            host.layer?.addSublayer(layer)
        }
        return host
    }
    
    func updateNSView(_ host: LayerHostView, context: Context) {}
}

struct CAGlowPulse: NSViewRepresentable {
    var color: NSColor
    
    func makeNSView(context: Context) -> LayerHostView {
        let host = LayerHostView()
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [color.cgColor, color.withAlphaComponent(0.85).cgColor, color.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.5, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        host.layer?.addSublayer(glow)
        host.glowLayer = glow
        // Slow pulse (period ~2.1 s): brightness 0.25...0.55, size 1.3...1.5 of the badge
        glow.add(.pulse("opacity", from: 0.25, to: 0.55, halfPeriod: 1.047), forKey: "o")
        glow.add(.pulse("transform.scale", from: 0.87, to: 1.0, halfPeriod: 1.047), forKey: "s")
        return host
    }
    
    func updateNSView(_ host: LayerHostView, context: Context) {
        guard let glow = host.glowLayer else { return }
        let b = host.bounds
        glow.bounds = CGRect(origin: .zero, size: b.size)
        glow.position = CGPoint(x: b.midX, y: b.midY)
    }
}

// MARK: - Live spectrum of the music player

import CoreAudio
import Accelerate

/// Listens to the music player itself (a Core Audio process tap on the player apps only, so notifications and other
/// system sounds never move the bars) and turns its low and mid frequencies into bar levels, ~30 times a second.
/// Runs only while some equalizer is on screen and playing.
final class AudioSpectrum {
    static let shared = AudioSpectrum()
    
    /// Apps whose sound counts as music: players, and browsers (YouTube, web players)
    private static let playerHints = ["aumusic", "com.apple.music", "spotify", "yandex", "vlc", "iina", "tidal", "deezer",
                                      "vox", "swinsian", "doppler", "soundcloud", "com.apple.safari", "com.apple.webkit.gpu", "chrome", "firefox",
                                      "thebrowser", "brave", "edge", "opera", "vivaldi", "zen", "quicktime"]
    /// Band edges in Hz: 5 bars from bass to the upper mids
    private static let edges: [Float] = [40, 90, 180, 400, 900, 2000]
    private static let n = 2048
    
    private var hosts = NSHashTable<LayerHostView>.weakObjects()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []
    private var sampleRate: Float = 48_000
    private let ioQueue = DispatchQueue(label: "com.local.notchy.spectrum", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var stopWork: DispatchWorkItem?
    
    // ring of the latest mono samples, written on the audio queue, read on the same queue
    private var ring = [Float](repeating: 0, count: n)
    private var ringPos = 0
    private var levels = [Float](repeating: 0, count: 5)
    private var peakDb = [Float](repeating: -40, count: 5)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    private let dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)
    private var tick = 0
    
    var isSupported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }
    
    func attach(_ host: LayerHostView) {
        hosts.add(host)
        stopWork?.cancel()
        if timer == nil { start() }
    }
    
    func detach(_ host: LayerHostView) {
        hosts.remove(host)
        guard hosts.allObjects.isEmpty else { return }
        // a pause between tracks, or the notch opening (wing bars -> card bars), must not rebuild the tap
        let work = DispatchWorkItem { [weak self] in if self?.hosts.allObjects.isEmpty == true { self?.stop() } }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    
    private func start() {
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.step() }
        timer = t
        t.resume()
    }
    
    private func stop() {
        timer?.cancel()
        timer = nil
        ioQueue.async { [weak self] in self?.teardownTap(); self?.tappedProcesses = [] }
    }
    
    // MARK: Tap
    
    private func step() {
        tick += 1
        // the player may start, stop or change: re-pick its processes every 2 s
        if tick % 60 == 1, #available(macOS 14.2, *) {
            let players = Self.playingPlayerProcesses()
            if players != tappedProcesses {
                teardownTap()
                tappedProcesses = players
                if !players.isEmpty { setupTap(players) }
            }
        }
        analyze()
    }
    
    @available(macOS 14.2, *)
    private static func playingPlayerProcesses() -> [AudioObjectID] {
        objectList(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID(kAudioObjectSystemObject)).filter { p in
            guard uint32(kAudioProcessPropertyIsRunningOutput, of: p) == 1,
                  let bundle = string(kAudioProcessPropertyBundleID, of: p)?.lowercased() else { return false }
            return playerHints.contains { bundle.contains($0) }
        }.sorted()
    }
    
    @available(macOS 14.2, *)
    private func setupTap(_ processes: [AudioObjectID]) {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { tapID = AudioObjectID(kAudioObjectUnknown); return }
        
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = Float(format.mSampleRate)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notchy Spectrum",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { teardownTap(); return }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.consume(input, interleaved: interleaved)
        }
        guard status == noErr, let proc = procID, AudioDeviceStart(aggregateID, proc) == noErr else { teardownTap(); return }
    }
    
    private func teardownTap() {
        if aggregateID != kAudioObjectUnknown {
            if let proc = procID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
    
    /// Audio queue: mix the player's channels to mono into the ring
    private func consume(_ input: UnsafePointer<AudioBufferList>, interleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = interleaved ? max(Int(first.mNumberChannels), 1) : 1
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = data.assumingMemoryBound(to: Float.self)
        let second = (!interleaved && buffers.count > 1) ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        for f in 0..<frames {
            var v = samples[f * channels]
            if channels > 1 { v = (v + samples[f * channels + 1]) * 0.5 } else if let s = second { v = (v + s[f]) * 0.5 }
            ring[ringPos] = v
            ringPos = (ringPos + 1) % Self.n
        }
    }
    
    // MARK: Analysis
    
    private func analyze() {
        let n = Self.n
        var ordered = [Float](repeating: 0, count: n)
        for i in 0..<n { ordered[i] = ring[(ringPos + i) % n] }
        // silence clears the ring view: no player playing, or the tap not running
        if tapID == kAudioObjectUnknown { ordered = [Float](repeating: 0, count: n) }
        vDSP.multiply(ordered, window, result: &ordered)
        
        var re = [Float](repeating: 0, count: n / 2), im = re, outRe = re, outIm = re
        for i in 0..<n / 2 { re[i] = ordered[2 * i]; im[i] = ordered[2 * i + 1] }
        if let dft = dft { vDSP_DFT_Execute(dft, re, im, &outRe, &outIm) }
        
        let binHz = sampleRate / Float(n)
        var targets = [Float](repeating: 0, count: 5)
        var loudest: Float = -120
        for b in 0..<5 {
            let lo = max(1, Int(Self.edges[b] / binHz)), hi = max(lo + 1, Int(Self.edges[b + 1] / binHz))
            var sum: Float = 0
            for k in lo..<min(hi, n / 2) { sum += outRe[k] * outRe[k] + outIm[k] * outIm[k] }
            let db = 10 * log10(sum / Float(hi - lo) + 1e-12)
            loudest = max(loudest, db)
            targets[b] = db
        }
        for b in 0..<5 {
            // Each band follows its own recent peak (bass carries far more energy than the mids): top = that peak,
            // floor 18 dB below, curved so beats stand out from the steady part of the sound
            peakDb[b] = max(targets[b], peakDb[b] - 0.12)
            let t = loudest < -90 ? 0 : pow(min(max((targets[b] - (peakDb[b] - 18)) / 18, 0), 1), 1.6)
            // rises at once with a beat, falls back gently
            levels[b] += (t - levels[b]) * (t > levels[b] ? 0.65 : 0.22)
        }
        let snapshot = levels
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for host in self.hosts.allObjects { CAEqualizer.setLevels(snapshot, in: host) }
        }
    }
    
    // MARK: Core Audio property helpers
    
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    
    private static func objectList(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }
    
    private static func uint32(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }
    
    private static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
