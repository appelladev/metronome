import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:metronome/metronome.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('play emits the first tick after the call returns', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    final metronome = await _initMetronome(timeSignature: 1);
    final events = <String>[];
    final firstTick = Completer<int>();

    late final StreamSubscription<int> sub;
    sub = metronome.tickStream.listen((tick) {
      events.add('tick:$tick');
      if (!firstTick.isCompleted) {
        firstTick.complete(tick);
      }
    });

    addTearDown(() async {
      await metronome.stop();
      await sub.cancel();
      await metronome.destroy();
    });

    events.add('before-play');
    unawaited(metronome.play());
    events.add('after-play-call');

    expect(events, ['before-play', 'after-play-call']);
    expect(await firstTick.future.timeout(const Duration(seconds: 3)), 0);
    expect(events.take(3), ['before-play', 'after-play-call', 'tick:0']);
  });

  testWidgets('play keeps the second tick within about one beat in 1/4', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    final metronome = await _initMetronome(timeSignature: 1);
    final tickTimes = <int>[];
    final stopwatch = Stopwatch();
    final secondTick = Completer<void>();

    late final StreamSubscription<int> sub;
    sub = metronome.tickStream.listen((_) {
      tickTimes.add(stopwatch.elapsedMilliseconds);
      if (tickTimes.length == 2 && !secondTick.isCompleted) {
        secondTick.complete();
      }
    });

    addTearDown(() async {
      await metronome.stop();
      await sub.cancel();
      await metronome.destroy();
    });

    stopwatch.start();
    unawaited(metronome.play());

    await secondTick.future.timeout(const Duration(seconds: 3));

    final playToSecondTickMs = tickTimes[1];
    final firstToSecondTickMs = tickTimes[1] - tickTimes[0];
    expect(playToSecondTickMs, lessThanOrEqualTo(650));
    expect(firstToSecondTickMs, greaterThanOrEqualTo(350));
    expect(firstToSecondTickMs, lessThanOrEqualTo(650));
  });

  testWidgets('steady 1/4 playback keeps consecutive tick intervals stable', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    final metronome = await _initMetronome(timeSignature: 1, bpm: 120);
    final tickTimes = <int>[];
    final stopwatch = Stopwatch();

    late final StreamSubscription<int> sub;
    sub = metronome.tickStream.listen((_) {
      tickTimes.add(stopwatch.elapsedMilliseconds);
    });

    addTearDown(() async {
      await metronome.stop();
      await sub.cancel();
      await metronome.destroy();
    });

    Future<void> waitForTicks(int count, Duration timeout) async {
      final deadline = DateTime.now().add(timeout);
      while (tickTimes.length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(tickTimes.length >= count, isTrue);
    }

    stopwatch.start();
    await metronome.play();
    await waitForTicks(4, const Duration(seconds: 3));

    for (var i = 1; i < tickTimes.length; i++) {
      final intervalMs = tickTimes[i] - tickTimes[i - 1];
      expect(intervalMs, greaterThanOrEqualTo(350));
      expect(intervalMs, lessThanOrEqualTo(650));
    }
  });

  testWidgets('bpm increase at a beat edge shortens the next interval in 1/4', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    final metronome = await _initMetronome(timeSignature: 1, bpm: 60);
    final tickTimes = <int>[];
    final stopwatch = Stopwatch();

    late final StreamSubscription<int> sub;
    sub = metronome.tickStream.listen((_) {
      tickTimes.add(stopwatch.elapsedMilliseconds);
    });

    addTearDown(() async {
      await metronome.stop();
      await sub.cancel();
      await metronome.destroy();
    });

    Future<void> waitForTicks(int count, Duration timeout) async {
      final deadline = DateTime.now().add(timeout);
      while (tickTimes.length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(tickTimes.length >= count, isTrue);
    }

    stopwatch.start();
    await metronome.play();
    await waitForTicks(2, const Duration(seconds: 4));

    await metronome.setBPM(120);
    await waitForTicks(4, const Duration(seconds: 4));

    final secondToThirdTickMs = tickTimes[2] - tickTimes[1];
    final thirdToFourthTickMs = tickTimes[3] - tickTimes[2];
    expect(secondToThirdTickMs, greaterThanOrEqualTo(350));
    expect(secondToThirdTickMs, lessThanOrEqualTo(650));
    expect(thirdToFourthTickMs, greaterThanOrEqualTo(350));
    expect(thirdToFourthTickMs, lessThanOrEqualTo(650));
  });

  testWidgets('time signature restart emits tick zero after the call returns', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    final metronome = await _initMetronome(timeSignature: 4);
    final allTicks = <int>[];
    final restartEvents = <String>[];
    final secondTick = Completer<void>();
    final restartTick = Completer<int>();
    var captureRestartEvents = false;

    late final StreamSubscription<int> sub;
    sub = metronome.tickStream.listen((tick) {
      allTicks.add(tick);

      if (allTicks.length == 2 && !secondTick.isCompleted) {
        secondTick.complete();
      }

      if (!captureRestartEvents) {
        return;
      }

      restartEvents.add('tick:$tick');
      if (!restartTick.isCompleted) {
        restartTick.complete(tick);
      }
    });

    addTearDown(() async {
      await metronome.stop();
      await sub.cancel();
      await metronome.destroy();
    });

    await metronome.play();
    await secondTick.future.timeout(const Duration(seconds: 3));

    captureRestartEvents = true;
    restartEvents.add('before-set-time-signature');
    unawaited(metronome.setTimeSignature(3));
    restartEvents.add('after-set-time-signature-call');

    expect(
      restartEvents,
      ['before-set-time-signature', 'after-set-time-signature-call'],
    );
    expect(await restartTick.future.timeout(const Duration(seconds: 3)), 0);
    expect(
      restartEvents.take(3),
      ['before-set-time-signature', 'after-set-time-signature-call', 'tick:0'],
    );
  });

  testWidgets('tick stream updates tempo within one beat after bpm change',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    final metronome = await _initMetronome();

    final tickTimes = <int>[];
    final stopwatch = Stopwatch();
    late final StreamSubscription<int> sub;
    sub = metronome.tickStream.listen((_) {
      tickTimes.add(stopwatch.elapsedMilliseconds);
    });

    addTearDown(() async {
      await metronome.stop();
      await sub.cancel();
      await metronome.destroy();
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

    expect(oldIntervalMs > 0, isTrue);
    expect(newIntervalMs > 0, isTrue);
    expect(newIntervalMs < oldIntervalMs, isTrue);
  });
}

Future<Metronome> _initMetronome({
  int timeSignature = 4,
  int bpm = 120,
}) async {
  final metronome = Metronome();
  await metronome.init(
    'assets/audio/snare44_wav.wav',
    accentedPath: 'assets/audio/claves44_wav.wav',
    bpm: bpm,
    volume: 50,
    enableTickCallback: true,
    timeSignature: timeSignature,
    sampleRate: 44100,
  );
  return metronome;
}
