class MetronomeTickEvent {
  const MetronomeTickEvent({
    required this.tick,
    required this.beatDuration,
    required this.elapsedSinceBeatStart,
  });

  final int tick;
  final Duration beatDuration;
  final Duration elapsedSinceBeatStart;

  factory MetronomeTickEvent.fromPlatformEvent(Object? event) {
    if (event is int) {
      return MetronomeTickEvent(
        tick: event,
        beatDuration: Duration.zero,
        elapsedSinceBeatStart: Duration.zero,
      );
    }

    if (event is Map<Object?, Object?>) {
      final beatDurationMicros =
          ((event['beatDurationMicros'] as num?)?.toInt() ?? 0).clamp(
        0,
        1 << 62,
      );
      final elapsedSinceBeatStartMicros =
          ((event['elapsedSinceBeatStartMicros'] as num?)?.toInt() ?? 0).clamp(
        0,
        1 << 62,
      );
      return MetronomeTickEvent(
        tick: (event['tick'] as num?)?.toInt() ?? 0,
        beatDuration: Duration(microseconds: beatDurationMicros),
        elapsedSinceBeatStart: Duration(
          microseconds: elapsedSinceBeatStartMicros,
        ),
      );
    }

    throw ArgumentError.value(event, 'event', 'Unsupported tick event payload');
  }
}
