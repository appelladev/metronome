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
    private var scheduleTimer: DispatchSourceTimer?
    private let lookahead: TimeInterval = 0.1
    private let scheduleInterval: TimeInterval = 0.05
    private var nextBeatSampleTime: AVAudioFramePosition = 0
    private var currentTick: Int = 0
    private var pendingBpm: Int?
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
        if !audioPlayerNode.isPlaying {
            audioPlayerNode.play()
        }
        currentTick = 0
        prepareBeatBuffers()
        startScheduler()
    }

    /// Pause the metronome.
    func pause() {
        stop()
    }
    
    /// Stop the metronome.
    func stop() {
        audioPlayerNode.stop()
        stopScheduler()
        nextBeatSampleTime = 0
        currentTick = 0
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

    private func startScheduler() {
        if scheduleTimer != nil { return }
        if let currentSampleTime = currentPlayerSampleTime() {
            nextBeatSampleTime = currentSampleTime
        } else {
            nextBeatSampleTime = 0
        }
        scheduleTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        scheduleTimer?.schedule(deadline: .now(), repeating: scheduleInterval, leeway: .milliseconds(5))
        scheduleTimer?.setEventHandler { [weak self] in
            self?.scheduleBeats()
        }
        scheduleTimer?.resume()
    }

    private func stopScheduler() {
        if scheduleTimer != nil {
            scheduleTimer?.cancel()
            scheduleTimer = nil
        }
    }

    private func scheduleBeats() {
        guard audioPlayerNode.isPlaying else { return }
        guard let nodeTime = audioPlayerNode.lastRenderTime,
              let playerTime = audioPlayerNode.playerTime(forNodeTime: nodeTime) else { return }

        let currentSampleTime = playerTime.sampleTime
        let lookaheadSamples = AVAudioFramePosition(self.lookahead * playerTime.sampleRate)

        while nextBeatSampleTime < currentSampleTime + lookaheadSamples {
            if let pending = pendingBpm {
                audioBpm = pending
                pendingBpm = nil
                prepareBeatBuffers()
            }

            let tickToPlay = (audioTimeSignature < 2) ? 0 : currentTick
            let buffer = (audioTimeSignature >= 2 && tickToPlay == 0) ? beatBufferAccented : beatBufferMain
            guard let beatBuffer = buffer else { return }

            let beatTime = AVAudioTime(sampleTime: nextBeatSampleTime, atRate: playerTime.sampleRate)
            audioPlayerNode.scheduleBuffer(beatBuffer, at: beatTime, options: [], completionHandler: nil)

            if eventTick != nil {
                let secondsUntilBeat = max(0, Double(nextBeatSampleTime - currentSampleTime) / playerTime.sampleRate)
                DispatchQueue.main.asyncAfter(deadline: .now() + secondsUntilBeat) { [weak self] in
                    self?.eventTick?.send(res: tickToPlay)
                }
            }

            let framesPerBeat = AVAudioFramePosition(Double(self.sampleRate) * 60.0 / Double(self.audioBpm))
            nextBeatSampleTime += framesPerBeat
            if audioTimeSignature < 2 {
                currentTick = 0
            } else {
                currentTick = (currentTick + 1) % audioTimeSignature
            }
        }
    }

    private func currentPlayerSampleTime() -> AVAudioFramePosition? {
        guard let nodeTime = audioPlayerNode.lastRenderTime,
              let playerTime = audioPlayerNode.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    func destroy() {
        audioPlayerNode.reset()
        audioPlayerNode.stop()
        audioEngine.reset()
        audioEngine.stop()
        audioEngine.detach(audioPlayerNode)
        beatBufferMain = nil
        beatBufferAccented = nil
        stopScheduler()
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
