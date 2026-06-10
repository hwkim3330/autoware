import 'package:freezed_annotation/freezed_annotation.dart';

part 'fault_data.freezed.dart';
part 'fault_data.g.dart';

@freezed
class FaultData with _$FaultData {
  const factory FaultData({
    required int id,
    required String target,
    required int severity,
    required String faultType,
    required String cause,
    required List<String> countermeasures,
  }) = _FaultData;

  factory FaultData.fromJson(Map<String, dynamic> json) =>
      _$FaultDataFromJson(json);
}
