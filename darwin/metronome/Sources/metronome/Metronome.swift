import AVFoundation

class Metronome {
    private var eventTick: EventTickHandler?
    private var audioPlayerNode: AVAudioPlayerNode = AVAudioPlayerNode()
    private var audioEngine: AVAudioEngine = AVAudioEngine()
    private var mixerNode: AVAudioMixerNode
    //
    private var audioFileMain: AVAudioFile
    private var audioFileAccented: AVAudioFile
    public var audioBpm: Int = 120
    public var audioVolume: Float = 0.5
    public var audioTimeSignature: Int = 0

    private var sampleRate: Int = 44100
    private var beatBufferMain: AVAudioPCMBuffer?
    private var beatBufferAccented: AVAudioPCMBuffer?
    private var isScheduling: Bool = false
    private var schedulerTimer: DispatchSourceTimer?
    private var tickPollTimer: DispatchSourceTimer?
    private let beatQueueLock = DispatchQueue(label: "metronome.beatqueue")
    private var beatQueue: [BeatEvent] = []
    private var nextBeatSampleTime: AVAudioFramePosition = 0
    private var hasSampleTimeAnchor: Bool = false
    private var sampleTimeOffset: AVAudioFramePosition = 0
    private var currentTick: Int = 0
    private var pendingBpm: Int?
    
    private struct BeatEvent {
        let sampleTime: AVAudioFramePosition
        let tick: Int
    }
    /// Initialize the metronome with the main and accented audio files.
    init(mainFileBytes: Data, accentedFileBytes: Data, bpm: Int, timeSignature: Int = 0, volume: Float, sampleRate: Int) {
        self.sampleRate = sampleRate
        audioTimeSignature = timeSignature
        audioBpm = bpm
        audioVolume = volume
        // Initialize audio files
        audioFileMain = try! AVAudioFile(fromData: mainFileBytes)
        if accentedFileBytes.isEmpty {
            audioFileAccented = audioFileMain
        }else{
            audioFileAccented = try! AVAudioFile(fromData: accentedFileBytes)
        }
#if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            )
            
            try audioSession.setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
#endif
        // Initialize audio engine and player node
        audioEngine.attach(audioPlayerNode)
        // Set up mixer node
        mixerNode = audioEngine.mainMixerNode
        mixerNode.outputVolume = audioVolume
        // Connect nodes
        audioEngine.connect(audioPlayerNode, to: mixerNode, format: audioFileMain.processingFormat)
        audioEngine.prepare()
        // Start the audio engine
        if !self.audioEngine.isRunning {
            do {
                try self.audioEngine.start()
                print("Start the audio engine")
            } catch {
                print("Failed to start audio engine: \(error.localizedDescription)")
            }
        }
        // Set volume
        setVolume(volume:volume)
#if os(iOS)
        setupNotifications()
#endif
    }
    /// Start the metronome.
    func play() {
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("Audio engine failed to start in play(): \(error)")
                return
            }
        }
        if isScheduling { return }
        currentTick = 0
        prepareBeatBuffers()
        isScheduling = true
        beatQueueLock.sync {
            beatQueue.removeAll(keepingCapacity: true)
        }
        nextBeatSampleTime = 0
        hasSampleTimeAnchor = false
        sampleTimeOffset = 0
        if !audioPlayerNode.isPlaying {
            audioPlayerNode.play()
        }
        startTickPoller()
        startSchedulerPoller()
    }

    /// Pause the metronome.
    func pause() {
        stop()
    }
    
    /// Stop the metronome.
    func stop() {
        isScheduling = false
        audioPlayerNode.stop()
        stopSchedulerPoller()
        stopTickPoller()
        currentTick = 0
        beatQueueLock.sync {
            beatQueue.removeAll(keepingCapacity: true)
        }
        nextBeatSampleTime = 0
        hasSampleTimeAnchor = false
        sampleTimeOffset = 0
    }
    
    /// Set the BPM of the metronome.
    func setBPM(bpm: Int) {
        if audioBpm != bpm {
            if isPlaying {
                pendingBpm = bpm
            } else {
                audioBpm = bpm
                prepareBeatBuffers()
            }
        }
    }
    ///Set the TimeSignature of the metronome.
    func setTimeSignature(timeSignature: Int) {
        if audioTimeSignature != timeSignature {
            audioTimeSignature = timeSignature
            if isPlaying {
                pause()
                play()
            }
        }
    }
    
    func setAudioFile(mainFileBytes: Data, accentedFileBytes: Data) {
        if !mainFileBytes.isEmpty {
            audioFileMain = try! AVAudioFile(fromData: mainFileBytes)
        }
        if !accentedFileBytes.isEmpty {
            audioFileAccented = try! AVAudioFile(fromData: accentedFileBytes)
        }
        if !mainFileBytes.isEmpty || !accentedFileBytes.isEmpty {
            if isPlaying {
                pause()
                play()
            }
        }
    }
    
    var getTimeSignature: Int {
        return audioTimeSignature
    }
    
    var getVolume: Int {
        return Int(audioVolume * 100)
    }
    
    func setVolume(volume: Float) {
        audioVolume = volume
        mixerNode.outputVolume = volume
    }
    
    var isPlaying: Bool {
        return audioPlayerNode.isPlaying
    }
    
    /// Enable the tick callback.
    public func enableTickCallback(_eventTickSink: EventTickHandler) {
        self.eventTick = _eventTickSink
    }
#if os(iOS)
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main,
            using: handleInterruption
        )
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main,
            using: handleRouteChange
        )
    }

    private func handleInterruption(_ notification: Notification) {
        if isPlaying {
            pause()
        }
    }
    private func handleRouteChange(_ notification: Notification) {
        // let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        // let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue ?? 0)
        // print("Audio route changed. Reason: \(String(describing: reason))")
        let wasPlaying = isPlaying
        if wasPlaying {
            pause()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                // let session = AVAudioSession.sharedInstance()
                // let outputs = session.currentRoute.outputs
                // print("Current audio outputs: \(outputs.map { $0.portType.rawValue })")
                self.audioPlayerNode.stop()
                self.audioEngine.stop()
                self.audioEngine.reset()

                do {
                    try self.audioEngine.start()
                } catch {
                    print("Audio engine failed to restart: \(error.localizedDescription)")
                }

                if wasPlaying {
                    self.play()
                }
            } catch {
                print("Failed to handle audio route change: \(error.localizedDescription)")
            }
        }
    }
#endif
    private func prepareBeatBuffers() {
        audioFileMain.framePosition = 0
        audioFileAccented.framePosition = 0

        let beatLength = AVAudioFrameCount(Double(self.sampleRate) * 60 / Double(self.audioBpm))
        let bufferMainClick = AVAudioPCMBuffer(pcmFormat: audioFileMain.processingFormat, frameCapacity: beatLength)!
        try! audioFileMain.read(into: bufferMainClick)
        bufferMainClick.frameLength = beatLength

        let bufferAccentedClick = AVAudioPCMBuffer(pcmFormat: audioFileAccented.processingFormat, frameCapacity: beatLength)!
        try! audioFileAccented.read(into: bufferAccentedClick)
        bufferAccentedClick.frameLength = beatLength

        beatBufferMain = bufferMainClick
        beatBufferAccented = bufferAccentedClick
    }

    private func stopSchedulerPoller() {
        schedulerTimer?.cancel()
        schedulerTimer = nil
        isScheduling = false
    }

    private func startSchedulerPoller() {
        schedulerTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.scheduleBeatsIfNeeded()
        }
        schedulerTimer = timer
        timer.resume()
    }

    private func scheduleBeatsIfNeeded() {
        guard isScheduling, audioEngine.isRunning else { return }
        guard let nodeTime = audioPlayerNode.lastRenderTime,
              let playerTime = audioPlayerNode.playerTime(forNodeTime: nodeTime) else { return }

        if !hasSampleTimeAnchor {
            sampleTimeOffset = playerTime.sampleTime
            hasSampleTimeAnchor = true
        }

        let virtualCurrentSample = playerTime.sampleTime - sampleTimeOffset
        if virtualCurrentSample < 0 {
            return
        }

        while true {
            if nextBeatSampleTime - virtualCurrentSample >= schedulerLeadTimeFramesCount() {
                break
            }
            if !scheduleNextBeat() {
                break
            }
        }
    }

    private func scheduleNextBeat() -> Bool {
        if let pending = pendingBpm {
            audioBpm = pending
            pendingBpm = nil
            prepareBeatBuffers()
        }

        let tickToPlay = (audioTimeSignature < 2) ? 0 : currentTick
        let buffer = (audioTimeSignature >= 2 && tickToPlay == 0) ? beatBufferAccented : beatBufferMain
        guard let beatBuffer = buffer else { return false }

        let scheduleSampleTime = sampleTimeOffset + nextBeatSampleTime
        let scheduleTime = AVAudioTime(sampleTime: scheduleSampleTime, atRate: Double(sampleRate))
        audioPlayerNode.scheduleBuffer(beatBuffer, at: scheduleTime, options: [], completionHandler: nil)

        beatQueueLock.sync {
            beatQueue.append(BeatEvent(sampleTime: nextBeatSampleTime, tick: tickToPlay))
        }
        nextBeatSampleTime += framesPerBeatCount()

        if audioTimeSignature < 2 {
            currentTick = 0
        } else {
            currentTick = (currentTick + 1) % audioTimeSignature
        }
        return true
    }

    private func startTickPoller() {
        tickPollTimer?.cancel()
        hasSampleTimeAnchor = false
        sampleTimeOffset = 0
        beatQueueLock.sync {
            beatQueue.removeAll(keepingCapacity: true)
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.pollTick()
        }
        tickPollTimer = timer
        timer.resume()
    }

    private func stopTickPoller() {
        tickPollTimer?.cancel()
        tickPollTimer = nil
        hasSampleTimeAnchor = false
        sampleTimeOffset = 0
    }

    private func pollTick() {
        guard isScheduling, audioEngine.isRunning else { return }
        guard let nodeTime = audioPlayerNode.lastRenderTime,
              let playerTime = audioPlayerNode.playerTime(forNodeTime: nodeTime) else { return }

        if !hasSampleTimeAnchor {
            return
        }

        let virtualCurrentSample = playerTime.sampleTime - sampleTimeOffset
        if virtualCurrentSample < 0 {
            return
        }
        var toEmit: [BeatEvent] = []
        beatQueueLock.sync {
            while let first = beatQueue.first, first.sampleTime <= virtualCurrentSample {
                toEmit.append(first)
                beatQueue.removeFirst()
            }
        }
        if !toEmit.isEmpty, eventTick != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                for event in toEmit {
                    self.eventTick?.send(res: event.tick)
                }
            }
        }
    }

    private func framesPerBeatCount() -> AVAudioFramePosition {
        let frames = Double(sampleRate) * 60.0 / Double(audioBpm)
        return AVAudioFramePosition(max(1.0, frames))
    }

    private func schedulerLeadTimeFramesCount() -> AVAudioFramePosition {
        let leadTimeFrames = Double(sampleRate) * schedulerLeadTimeSeconds()
        return AVAudioFramePosition(max(1.0, leadTimeFrames))
    }

    private func schedulerLeadTimeSeconds() -> Double {
#if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        let outputLatency = max(0.0, audioSession.outputLatency)
        let ioBufferDuration = max(0.0, audioSession.ioBufferDuration)
        let latencyBasedLead = outputLatency + (ioBufferDuration * 2.0)
        return min(0.12, max(0.06, latencyBasedLead))
#else
        return 0.06
#endif
    }

    func destroy() {
        // Stop scheduling and timers FIRST so background callbacks
        // don't access the engine while it's being torn down.
        isScheduling = false
        stopSchedulerPoller()
        stopTickPoller()

        audioPlayerNode.stop()
        audioEngine.stop()
        audioEngine.detach(audioPlayerNode)
        beatBufferMain = nil
        beatBufferAccented = nil
    }
}
extension AVAudioFile {
    convenience init(fromData data: Data) throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try data.write(to: tempURL)
            //print("Temporary file created at: \(tempURL)")
        } catch {
            //print("Failed to write data to temporary file: \(error.localizedDescription)")
            throw error
        }
        do {
            try self.init(forReading: tempURL)
        } catch {
            //print("Failed to initialize AVAudioFile: \(error.localizedDescription)")
            throw error
        }
    }
}
