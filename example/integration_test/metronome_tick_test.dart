import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:metronome/metronome.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tick stream updates tempo within one beat after bpm change',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    final metronome = Metronome();
    await metronome.init(
      'assets/audio/snare44_wav.wav',
      accentedPath: 'assets/audio/claves44_wav.wav',
      bpm: 120,
      volume: 50,
      enableTickCallback: true,
      timeSignature: 4,
      sampleRate: 44100,
    );

    final tickTimes = <int>[];
    final stopwatch = Stopwatch();
    final sub = metronome.tickStream.listen((_) {
      tickTimes.add(stopwatch.elapsedMilliseconds);
    });

    Future<void> waitForTicks(int count, Duration timeout) async {
      final deadline = DateTime.now().add(timeout);
      while (tickTimes.length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(tickTimes.length >= count, isTrue);
    }

    await metronome.play();
    stopwatch.start();
    await waitForTicks(3, const Duration(seconds: 3));

    final oldIntervalMs = tickTimes[2] - tickTimes[1];

    await metronome.setBPM(240);
    await waitForTicks(5, const Duration(seconds: 3));

    final newIntervalMs = tickTimes[4] - tickTimes[3];

    await metronome.stop();
    await sub.cancel();

    expect(oldIntervalMs > 0, isTrue);
    expect(newIntervalMs > 0, isTrue);
    expect(newIntervalMs < oldIntervalMs, isTrue);
  });
}
