/// A time as the committee reads it on the water: HH:MM:SS, the phone's local
/// time. [millis] is milliseconds since the epoch, as every event carries it.
String clockText(int millis) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// [clockText] to the minute, HH:MM, where a line has no room for seconds:
/// the shore indicator in an app bar (#66).
String minuteText(int millis) => clockText(millis).substring(0, 5);

/// The phone's own clock, in milliseconds since the epoch. A screen that
/// judges a typed time against "now" takes a clock, so a test can fix it.
int systemClock() => DateTime.now().millisecondsSinceEpoch;
