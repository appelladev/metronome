int calculateTickCallbackDelayMs({
  required double scheduledTime,
  required double currentTime,
}) {
  final delayMs = ((scheduledTime - currentTime) * 1000).round();
  return delayMs < 0 ? 0 : delayMs;
}
