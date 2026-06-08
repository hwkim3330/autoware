import 'enums.dart';

class EventLog {
  final String timestamp; // display string e.g. "10:42:21"
  final EventLevel level;
  final String message;

  const EventLog({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  factory EventLog.fromJson(Map<String, dynamic> j) => EventLog(
        timestamp: (j['timestamp'] ?? '').toString(),
        level: eventLevelFrom(j['level']?.toString()),
        message: (j['message'] ?? '').toString(),
      );
}
