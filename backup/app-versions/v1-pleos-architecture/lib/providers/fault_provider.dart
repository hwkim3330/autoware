import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/fault_data.dart';
import '../core/constants.dart';
import '../services/fault_stream_service.dart';
import 'viewer_service_provider.dart';

class FaultNotifier extends StateNotifier<Map<int, FaultData>> {
  FaultNotifier(this.ref) : super({}) {
    _initializeFaultStream();
  }

  final Ref ref;
  final FaultStreamService _faultStreamService = FaultStreamService();

  void _initializeFaultStream() {
    _faultStreamService.startListening((event) {
      if (event.type == FaultEventType.add && event.faultData != null) {
        addFault(event.faultData!);
      } else if (event.type == FaultEventType.remove) {
        removeFault(event.id);
      }
    });
  }

  void addFault(FaultData fault) {
    state = {...state, fault.id: fault};

    // Update viewer for this target
    _updateViewerForTarget(fault.target);
  }

  void removeFault(int id) {
    final fault = state[id];
    if (fault == null) return;

    final target = fault.target;
    final newState = Map<int, FaultData>.from(state);
    newState.remove(id);
    state = newState;

    // Update viewer for this target
    _updateViewerForTarget(target);
  }

  void clearAll() {
    state = {};
    ref.read(viewerServiceProvider).stopAlert();
  }

  @override
  void dispose() {
    _faultStreamService.dispose();
    super.dispose();
  }

  /// Update 3D viewer alert for a specific target
  /// Shows the highest severity if multiple faults exist for the same target
  void _updateViewerForTarget(String target) {
    final service = ref.read(viewerServiceProvider);

    // Find all faults for this target
    final targetFaults = state.values.where((f) => f.target == target).toList();

    if (targetFaults.isEmpty) {
      // No more faults for this target - hide alert
      service.hideFaultAlert(target);
      if (state.isEmpty) {
        service.stopAlert();
      }
    } else {
      // Show alert with highest severity
      final maxSeverity = targetFaults
          .map((f) => f.severity)
          .reduce((a, b) => a > b ? a : b);

      final config = errorHotspotConfigs[target];
      if (config != null) {
        service.showFaultAlert(target, maxSeverity, config);
      }
    }
  }

  /// Get all faults for a specific target
  List<FaultData> getFaultsByTarget(String target) {
    return state.values.where((f) => f.target == target).toList();
  }

  /// Get a specific fault by id
  FaultData? getFault(int id) => state[id];

  /// Get the first fault for a target
  /// TODO: 여러 개의 fault 가져오는 로직 추가
  FaultData? getFaultByTarget(String target) {
    return state.values.firstWhere(
      (f) => f.target == target,
      orElse: () => FaultData(
        id: 0,
        target: '',
        severity: 0,
        faultType: '',
        cause: '',
        countermeasures: [],
      ),
    );
  }

  void simulateFault() {
    final testFault1 = FaultData(
      id: 1,
      target: 'RearZC', // Material name이 곧 target
      severity: 2,
      faultType: '시간 동기 상실 (Loss of Time Sync)',
      cause: 'GM  고장 또는 PTP 메시지 전파 경로 상 링크 단절',
      countermeasures: [
        'GM Failover: Secondary GM이 BMCA에 따라 새로운 GM 역할 수행',
        'PTP용 FRER 설정',
      ],
    );
    addFault(testFault1);

    final testFault2 = FaultData(
      id: 2,
      target: 'connection-FrontCenterLidar-FrontZC',
      severity: 1,
      faultType: '간헐적 링크 불안정이 지속적으로 발생해 센서 확보 불가',
      cause: 'FC-Lidar와 ZC 사이 링크의 간헐적 불안정',
      countermeasures: [
        '단일 경로 운용(Fail-Operation): 안정적인 단일 경로로만 트래픽 발생',
        '무중단(Hitless) 이중화 중지',
        '하지만, 자율주행 기능은 정상 수행',
      ],
    );
    addFault(testFault2);
  }
}

final faultProvider = StateNotifierProvider<FaultNotifier, Map<int, FaultData>>(
  (ref) {
    return FaultNotifier(ref);
  },
);
