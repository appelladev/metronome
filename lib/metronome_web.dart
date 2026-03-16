import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'metronome_platform_interface.dart';
import 'src/tick_callback_delay.dart';

class MetronomeWeb extends MetronomePlatform {
  static void registerWith(Registrar registrar) {
    MetronomePlatform.instance = MetronomeWeb();
  }

  static const int sampleSize = 16;
  static const int channels = 1;

  // Audio context and elements
  web.AudioContext? _audioContext;
  web.AudioBuffer? _mainSoundOriginal;
  web.AudioBuffer? _mainSoundBuffer;
  web.AudioBuffer? _accentedSoundOriginal;
  web.AudioBuffer? _accentedSoundBuffer;
  web.AudioBuffer? _mainSoundOriginalTemp;
  web.AudioBuffer? _accentedSoundOriginalTemp;
  bool _isPlaying = false;
  int _currentTick = 0;
  int _bpm = 120;
  int? _pendingBpm;
  int _timeSignature = 4;
  double _volume = 1.0;
  bool _enableTickCallback = false;
  int _sampleRate = 44100;

  double _nextBeatTime = 0;
  int _scheduleTimer = 0;
  final Set<int> _tickCallbackTimerIds = <int>{};
  final double _lookahead = 0.1;
  final double _scheduleInterval = 0.05;

  @override
  Future<void> init(
    String mainPath, {
    String accentedPath = '',
    int bpm = 120,
    int volume = 50,
    bool enableTickCallback = false,
    int timeSignature = 4,
    int sampleRate = 44100,
  }) async {
    if (mainPath == '') {
      throw 'mainPath is empty';
    }

    _sampleRate = sampleRate;
    _bpm = bpm;
    _timeSignature = timeSignature;
    _volume = volume / 100;
    _enableTickCallback = enableTickCallback;

    _audioContext = web.AudioContext(
      web.AudioContextOptions(
        latencyHint: 'interactive'.toJS,
        sampleRate: _sampleRate.toDouble(),
      ),
    );

    _mainSoundOriginal = await _decodeAudioBuffer(mainPath);
    _mainSoundBuffer = _convertAudioFormat(_mainSoundOriginal!);

    if (accentedPath == '') {
      _accentedSoundOriginal = _mainSoundOriginal;
      _accentedSoundBuffer = _mainSoundBuffer;
    } else {
      _accentedSoundOriginal = await _decodeAudioBuffer(accentedPath);
      _accentedSoundBuffer = _convertAudioFormat(_accentedSoundOriginal!);
    }
  }

  @override
  Future<void> play() async {
    if (_isPlaying) return;
    _isPlaying = true;
    _currentTick = 0;
    startScheduler();
  }

  @override
  Future<void> pause() async {
    stopScheduler();
    _isPlaying = false;
  }

  @override
  Future<void> stop() async {
    await pause();
    _currentTick = 0;
  }

  @override
  Future<void> setVolume(int volume) async {
    if (_volume != volume) {
      _volume = volume / 100;
    }
  }

  @override
  Future<int?> getVolume() async {
    return (_volume * 100).round();
  }

  @override
  Future<int?> getTimeSignature() async {
    return _timeSignature;
  }

  @override
  Future<int?> getBPM() async {
    return _bpm;
  }

  @override
  Future<bool?> isPlaying() async {
    return _isPlaying;
  }

  @override
  Future<void> setBPM(int bpm) async {
    if (bpm != _bpm) {
      if (_isPlaying) {
        _pendingBpm = bpm;
      } else {
        _bpm = bpm;
        _rebuildBeatBuffers();
      }
    }
  }

  @override
  Future<void> setTimeSignature(int timeSignature) async {
    if (timeSignature != _timeSignature) {
      _timeSignature = timeSignature;
      if (_isPlaying) {
        await pause();
        await play();
      }
    }
  }

  @override
  Future<void> setAudioFile({
    String mainPath = '',
    String accentedPath = '',
  }) async {
    if (mainPath != '') {
      _mainSoundOriginalTemp = await _decodeAudioBuffer(mainPath);
    }
    if (accentedPath != '') {
      _accentedSoundOriginalTemp = await _decodeAudioBuffer(accentedPath);
    }
  }

  @override
  Future<void> destroy() async {
    await stop();
    _mainSoundOriginal = null;
    _mainSoundBuffer = null;
    _accentedSoundOriginal = null;
    _accentedSoundBuffer = null;
  }

  void startScheduler() {
    _nextBeatTime = _audioContext!.currentTime;
    _clearTickCallbackTimers();
    _schedule();
  }

  void _schedule() {
    web.window.clearTimeout(_scheduleTimer);
    while (_nextBeatTime < _audioContext!.currentTime + _lookahead) {
      if (_pendingBpm != null) {
        _bpm = _pendingBpm!;
        _pendingBpm = null;
        _rebuildBeatBuffers();
      }
      _scheduleBeat(_nextBeatTime);
      _nextBeatTime += 60.0 / _bpm;
    }
    _scheduleTimer = web.window.setTimeout(
      _schedule.toJS,
      (_scheduleInterval * 1000).round() as JSAny?,
    );
  }

  void _scheduleBeat(double time) {
    final tickToPlay = _timeSignature > 1 ? _currentTick : 0;
    final isAccented = (_timeSignature > 1) && (tickToPlay == 0);
    final buffer = isAccented ? _accentedSoundBuffer : _mainSoundBuffer;
    final source = _audioContext!.createBufferSource();
    source.buffer = buffer;
    final gainNode = _audioContext!.createGain();
    gainNode.gain.value = _volume;
    source.connect(gainNode);
    gainNode.connect(_audioContext!.destination);
    source.start(time);
    _scheduleTickCallback(tickToPlay: tickToPlay, scheduledTime: time);
    source.onEnded.listen((_) {
      if (_mainSoundOriginalTemp != null) {
        _mainSoundOriginal = _mainSoundOriginalTemp;
        _mainSoundOriginalTemp = null;
        _mainSoundBuffer = _convertAudioFormat(_mainSoundOriginal!);
      }
      if (_accentedSoundOriginalTemp != null) {
        _accentedSoundOriginal = _accentedSoundOriginalTemp;
        _accentedSoundOriginalTemp = null;
        _accentedSoundBuffer = _convertAudioFormat(_accentedSoundOriginal!);
      }
    });
    _currentTick =
        (_timeSignature > 1) ? (_currentTick + 1) % _timeSignature : 0;
  }

  void _scheduleTickCallback({
    required int tickToPlay,
    required double scheduledTime,
  }) {
    if (!_enableTickCallback) {
      return;
    }

    final delayMs = calculateTickCallbackDelayMs(
      scheduledTime: scheduledTime,
      currentTime: _audioContext!.currentTime,
    );

    late final int timerId;
    timerId = web.window.setTimeout(
      (() {
        _tickCallbackTimerIds.remove(timerId);
        if (!_isPlaying || !_enableTickCallback) {
          return;
        }
        tickController.add(tickToPlay);
      }).toJS,
      delayMs as JSAny?,
    );
    _tickCallbackTimerIds.add(timerId);
  }

  void stopScheduler() {
    web.window.clearTimeout(_scheduleTimer);
    _nextBeatTime = 0;
    _clearTickCallbackTimers();
  }

  void _clearTickCallbackTimers() {
    for (final timerId in _tickCallbackTimerIds) {
      web.window.clearTimeout(timerId);
    }
    _tickCallbackTimerIds.clear();
  }

  Future<web.AudioBuffer> _decodeAudioBuffer(String filePath) async {
    final byteData = await loadFileBytes(filePath);
    if (byteData.isEmpty) {
      throw Exception('File does not exist: $filePath');
    }
    final jsArrayBuffer = byteData.buffer;
    final web.AudioBuffer audioBuffer =
        await _audioContext!.decodeAudioData(jsArrayBuffer as dynamic).toDart;
    return audioBuffer;
  }

  web.AudioBuffer _convertAudioFormat(web.AudioBuffer original) {
    final framesPerBeat = (_sampleRate * 60 / _bpm).round();
    final newBuffer = _audioContext!
        .createBuffer(channels, framesPerBeat, _sampleRate.toDouble());
    final newChannel = newBuffer.getChannelData(0).toDart;
    const scaleFactor = 32767.0;
    const inverseScale = 1.0 / scaleFactor;

    for (var ch = 0; ch < original.numberOfChannels; ch++) {
      final channelData = original.getChannelData(ch).toDart;
      final maxCopyLength = framesPerBeat.clamp(0, channelData.length);

      for (var j = 0; j < maxCopyLength; j++) {
        final srcPos = (j * original.sampleRate / _sampleRate).round();

        if (srcPos < channelData.length) {
          double sample = channelData[srcPos];
          if (sampleSize == 16) {
            sample = (sample * scaleFactor).roundToDouble() * inverseScale;
          }

          if (original.numberOfChannels > 1) {
            newChannel[j] += sample / original.numberOfChannels;
          } else {
            newChannel[j] = sample;
          }
        }
      }
    }
    return newBuffer;
  }

  void _rebuildBeatBuffers() {
    if (_mainSoundOriginal != null) {
      _mainSoundBuffer = _convertAudioFormat(_mainSoundOriginal!);
    }
    if (_accentedSoundOriginal != null) {
      _accentedSoundBuffer = _convertAudioFormat(_accentedSoundOriginal!);
    }
  }

  Future<Uint8List> loadFileBytes(String filePath) async {
    if (!filePath.startsWith('/')) {
      final ByteData data = await rootBundle.load(filePath);
      return data.buffer.asUint8List();
    }
    throw Exception('Absolute file paths are not supported on web: $filePath');
  }
}
