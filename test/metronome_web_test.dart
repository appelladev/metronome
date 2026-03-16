import 'package:flutter_test/flutter_test.dart';
import 'package:metronome/src/tick_callback_delay.dart';

void main() {
  group('calculateTickCallbackDelayMs', () {
    test('returns the rounded positive delay for a future beat', () {
      expect(
        calculateTickCallbackDelayMs(
          scheduledTime: 1.25,
          currentTime: 1.0,
        ),
        250,
      );
    });

    test('clamps past scheduled beats to zero delay', () {
      expect(
        calculateTickCallbackDelayMs(
          scheduledTime: 0.95,
          currentTime: 1.0,
        ),
        0,
      );
    });

    test('rounds near-zero future delays', () {
      expect(
        calculateTickCallbackDelayMs(
          scheduledTime: 1.0046,
          currentTime: 1.0,
        ),
        5,
      );
    });
  });
}
