import 'dart:convert';

/// Label Hotspot 설정 (텍스트 버튼)
class LabelHotspotConfig {
  final String slotName;
  final String label;
  final String position;
  final String dataTarget;
  final String dataOrbit;

  const LabelHotspotConfig({
    required this.slotName,
    required this.label,
    required this.position,
    required this.dataTarget,
    required this.dataOrbit,
  });

  Map<String, dynamic> toJson() => {
    'slotName': slotName,
    'label': label.replaceAll('\n', '<br>'), // 줄바꿈을 HTML <br>로 변환
    'position': position,
    'dataTarget': dataTarget,
    'dataOrbit': dataOrbit,
  };
}

/// Label Hotspot 목록
const List<LabelHotspotConfig> labelHotspots = [
  LabelHotspotConfig(
    slotName: 'frontZC',
    label: 'Front zone\nTSN Switch',
    position: '0m 4m 14m', // 3d model에서 material의 중심 좌표
    dataTarget:
        '0m 4m 14m', // dataTarget은 position과 동일하게 하되, 필요 시 y값 조절해 수직 위치 조절 (음수 = 위로)
    dataOrbit: '135deg 45deg 2.5m', // dataOrbit은 그대로 유지 -> 왼쪽 45% 위에서 바라본 위치
  ),
  LabelHotspotConfig(
    slotName: 'rearZC',
    label: 'Rear zone\nTSN Switch',
    position: '0m 4m -4m',
    dataTarget: '0m 4m -4m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  LabelHotspotConfig(
    slotName: 'acu_it',
    label: 'ACU_IT',
    position: '0m 4m -12m',
    dataTarget: '0m 4m -12m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  LabelHotspotConfig(
    slotName: 'tcu',
    label: 'TCU',
    position: '-6m 7m -4m',
    dataTarget: '-6m 7m -4m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  LabelHotspotConfig(
    slotName: 'sub_vcu',
    label: 'Sub_VC',
    position: '-6m 4m 11m',
    dataTarget: '-6m 4m 11m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  LabelHotspotConfig(
    slotName: 'cmu',
    label: 'CMU',
    position: '-11m 4m -8m',
    dataTarget: '-11m 4m -8m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  LabelHotspotConfig(
    slotName: 'acu_no',
    label: 'ACU_NO',
    position: '-11m 4m -12m',
    dataTarget: '-11m 4m -12m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  LabelHotspotConfig(
    slotName: 'vcu',
    label: 'VCU',
    position: '-6m 10m 3m',
    dataTarget: '-6m 10m 3m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  LabelHotspotConfig(
    slotName: 'edr',
    label: 'EDR/DSSA',
    position: '-6m 10m 7m',
    dataTarget: '-6m 10m 7m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
];

/// Label Hotspot JSON 변환
String labelHotspotsToJson() {
  return jsonEncode(labelHotspots.map((h) => h.toJson()).toList());
}

/// Error Hotspot 설정 (원형 아이콘)
/// Key = Material name (3D 모델의 material 이름이자 fault target)
class ErrorHotspotConfig {
  final String position; // 3D 좌표
  final String dataTarget; // 카메라 타겟
  final String dataOrbit; // 카메라 orbit

  const ErrorHotspotConfig({
    required this.position,
    required this.dataTarget,
    required this.dataOrbit,
  });
}

/// Material name -> Error Hotspot 설정 매핑
/// fault.target = material name으로 직접 사용
const Map<String, ErrorHotspotConfig> errorHotspotConfigs = {
  // 장치
  'FrontZC': ErrorHotspotConfig(
    position: '0m 6m 14m',
    dataTarget: '0m -7m 14m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'RearZC': ErrorHotspotConfig(
    position: '0m 6m -4m',
    dataTarget: '0m -7m -4m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'ACU_IT': ErrorHotspotConfig(
    position: '0m 4m -12m',
    dataTarget: '0m -9m -12m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'TCU': ErrorHotspotConfig(
    position: '-6m 7m -4m',
    dataTarget: '-6m -6m -4m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'Sub_VC': ErrorHotspotConfig(
    position: '-6m 4m 11m',
    dataTarget: '-6m -9m 11m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'CMU': ErrorHotspotConfig(
    position: '-11m 4m -8m',
    dataTarget: '-11m -9m -8m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'ACU_NO': ErrorHotspotConfig(
    position: '-11m 4m -12m',
    dataTarget: '-11m -9m -12m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'VCU': ErrorHotspotConfig(
    position: '-6m 10m 3m',
    dataTarget: '-6m -3m 3m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'EDR/DSSA': ErrorHotspotConfig(
    position: '-6m 10m 7m',
    dataTarget: '-6m -3m 7m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  // path
  'Path1': ErrorHotspotConfig(
    position: '2m 4m 5m',
    dataTarget: '2m -9m 5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'Path2': ErrorHotspotConfig(
    position: '-2m 4m 5m',
    dataTarget: '-2m -9m 5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  // lidar
  'FrontLeftLidar': ErrorHotspotConfig(
    position: '-8.5m 10m 16.2m',
    dataTarget: '-8.5m -3m 16.2m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'FrontRightLidar': ErrorHotspotConfig(
    position: '8.3m 10m 16.2m',
    dataTarget: '8.3m -3m 16.2m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'FrontCenterLidar': ErrorHotspotConfig(
    position: '0m 5.5m 18.5m',
    dataTarget: '0m -7.5m 18.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'RearCenterLidar': ErrorHotspotConfig(
    position: '0m 5.5m -18.5m',
    dataTarget: '0m -7.5m -18.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  // camera
  'FrontCenterCamera': ErrorHotspotConfig(
    position: '0m 10.5m 18.5m',
    dataTarget: '0m -2.5m 18.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'FrontLeftCamera': ErrorHotspotConfig(
    position: '0.6m 10.5m 18.5m',
    dataTarget: '0.6m -2.5m 18.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'FrontRightCamera': ErrorHotspotConfig(
    position: '-0.6m 10.5m 18.5m',
    dataTarget: '-0.6m -2.5m 18.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'SideLeft1Camera': ErrorHotspotConfig(
    position: '-8.5m 11m 16.5m',
    dataTarget: '-8.5m -2m 16.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'SideRight1Camera': ErrorHotspotConfig(
    position: '8.3m 11m 16.5m',
    dataTarget: '8.3m -2m 16.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'SideLeft2Camera': ErrorHotspotConfig(
    position: '-8.5m 11m 15.9m',
    dataTarget: '-8.5m -2m 15.9m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'SideRight2Camera': ErrorHotspotConfig(
    position: '8.3m 11m 15.9m',
    dataTarget: '8.3m -2m 15.9m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'RearCenterCamera': ErrorHotspotConfig(
    position: '0m 9m -18.5m',
    dataTarget: '0m -4m -18.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  // radar
  'FrontCenterRadar': ErrorHotspotConfig(
    position: '0m 7m 18.5m',
    dataTarget: '0m -6m 18.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'FrontLeftRadar': ErrorHotspotConfig(
    position: '-7m 6.5m 17.5m',
    dataTarget: '-7m -6.5m 17.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'FrontRightRadar': ErrorHotspotConfig(
    position: '7m 6.5m 17.5m',
    dataTarget: '7m -6.5m 17.5m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'RearLeftRadar': ErrorHotspotConfig(
    position: '-7m 6.5m -18m',
    dataTarget: '-7m -6.5m -18m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'RearRightRadar': ErrorHotspotConfig(
    position: '7m 6.5m -18m',
    dataTarget: '7m -6.5m -18m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
  'connection-FrontCenterLidar-FrontZC': ErrorHotspotConfig(
    position: '0m 7m 16m',
    dataTarget: '0m -6m 16m',
    dataOrbit: '135deg 45deg 2.5m',
  ),
};
