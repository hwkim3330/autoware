import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../models/fault_data.dart';
import '../models/native_fault_data.dart';
import '../repositories/fault_code_mapper.dart';

/// Fault event types
enum FaultEventType { add, remove }

/// Fault event with action type
class FaultEvent {
  final FaultEventType type;
  final int id;
  final String? target;
  final FaultData? faultData; // null for remove events

  FaultEvent({
    required this.type,
    required this.id,
    this.target,
    this.faultData,
  });
}

/// Service for handling the fault data stream from Android native layer
class FaultStreamService {
  static const EventChannel _faultChannel = EventChannel(
    'com.example/fault_data_stream',
  );

  Stream<FaultEvent>? _faultStream;
  StreamSubscription<FaultEvent>? _subscription;

  /// Get the fault event stream
  /// This stream listens to the native EventChannel, parses the data,
  /// and handles both add and remove actions
  Stream<FaultEvent> getFaultStream() {
    _faultStream ??= _faultChannel
        .receiveBroadcastStream()
        .map((dynamic event) => _parseFaultEvent(event))
        .where((event) => event != null)
        .cast<FaultEvent>()
        .handleError((error) {
          debugPrint('FaultStreamService error: $error');
        });

    return _faultStream!;
  }

  /// native로부터 오는 raw data를 NativeFaultData로 파싱 -> FaultCodeMapper를 통해 FaultEvent로 변환
  FaultEvent? _parseFaultEvent(dynamic event) {
    try {
      if (event is! Map) {
        debugPrint(
          'FaultStreamService: Expected Map, got ${event.runtimeType}',
        );
        return null;
      }

      // Convert to Map<String, dynamic>
      final data = Map<String, dynamic>.from(event);

      // Parse to NativeFaultData
      final nativeFault = NativeFaultData.fromJson(data);

      // Handle different actions
      if (nativeFault.action == 0) {
        // 삭제
        debugPrint('FaultStreamService: Remove fault - id: ${nativeFault.id}');
        return FaultEvent(
          type: FaultEventType.remove,
          id: nativeFault.id,
          target: nativeFault.target,
        );
      } else {
        // 추가 (기본: action == 1)
        debugPrint(
          'FaultStreamService: Add fault - id: ${nativeFault.id}, '
          'code: ${nativeFault.code}, target: ${nativeFault.target}, severity: ${nativeFault.severity}',
        );

        // Map to full FaultData (모든 정보 포함)
        final faultData = FaultCodeMapper.mapCodeToFaultData(nativeFault);

        return FaultEvent(
          type: FaultEventType.add,
          id: nativeFault.id,
          target: nativeFault.target,
          faultData: faultData,
        );
      }
    } catch (e, stackTrace) {
      debugPrint('FaultStreamService: Error parsing fault event: $e');
      debugPrint('Stack trace: $stackTrace');
      return null;
    }
  }

  /// Start listening to the fault stream with a callback
  void startListening(void Function(FaultEvent) onFaultEvent) {
    _subscription?.cancel();
    _subscription = getFaultStream().listen(
      onFaultEvent,
      onError: (error) {
        debugPrint('FaultStreamService subscription error: $error');
      },
      cancelOnError: false,
    );
  }

  /// Stop listening to the fault stream
  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Dispose the service and clean up resources
  void dispose() {
    stopListening();
    _faultStream = null;
  }
}
