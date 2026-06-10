import 'package:freezed_annotation/freezed_annotation.dart';

part 'native_fault_data.freezed.dart';
part 'native_fault_data.g.dart';

/// Lightweight data structure received from Android native layer
/// Represents the minimal fault information sent via platform channel
/// action: 1 = add, 0 = remove
@freezed
class NativeFaultData with _$NativeFaultData {
  const factory NativeFaultData({
    @Default(1) int action,
    required int id,
    String? target,
    int? code,
    int? severity,
  }) = _NativeFaultData;

  factory NativeFaultData.fromJson(Map<String, dynamic> json) =>
      _$NativeFaultDataFromJson(json);
}
