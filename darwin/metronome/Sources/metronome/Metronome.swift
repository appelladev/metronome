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
    private var beatTimer: DispatchSourceTimer?
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
        if isScheduling { return }
        currentTick = 0
        prepareBeatBuffers()
        isScheduling = true
        if !audioPlayerNode.isPlaying {
            audioPlayerNode.play()
        }
        startBeatTimer()
    }

    /// Pause the metronome.
    func pause() {
        stop()
    }
    
    /// Stop the metronome.
    func stop() {
        isScheduling = false
        audioPlayerNode.stop()
        stopScheduler()
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
        if isScheduling { return }
        isScheduling = true
        startBeatTimer()
    }

    private func stopScheduler() {
        beatTimer?.cancel()
        beatTimer = nil
        isScheduling = false
    }

    private func startBeatTimer() {
        beatTimer?.cancel()
        let beatDuration = 60.0 / Double(audioBpm)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: beatDuration, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.scheduleBeatTick()
        }
        beatTimer = timer
        timer.resume()
    }

    private func scheduleBeatTick() {
        guard isScheduling else { return }

        if let pending = pendingBpm {
            audioBpm = pending
            pendingBpm = nil
            prepareBeatBuffers()
            startBeatTimer()
        }

        let tickToPlay = (audioTimeSignature < 2) ? 0 : currentTick
        let buffer = (audioTimeSignature >= 2 && tickToPlay == 0) ? beatBufferAccented : beatBufferMain
        guard let beatBuffer = buffer else { return }

        audioPlayerNode.scheduleBuffer(beatBuffer, at: nil, options: [], completionHandler: nil)

        if eventTick != nil {
            DispatchQueue.main.async { [weak self] in
                self?.eventTick?.send(res: tickToPlay)
            }
        }

        if audioTimeSignature < 2 {
            currentTick = 0
        } else {
            currentTick = (currentTick + 1) % audioTimeSignature
        }
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
