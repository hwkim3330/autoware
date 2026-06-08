import 'package:flutter/material.dart';

/// All enum-like state values are kept as parsed-from-string with a canonical
/// fallback, because the upstream contract (CARLA/ROS2/Autoware gateway) may
/// add values over time. We never crash on an unknown string.

T _parse<T>(Map<String, T> table, String? raw, T fallback) {
  if (raw == null) return fallback;
  return table[raw.trim().toUpperCase()] ?? fallback;
}

enum SensorStatus { normal, degraded, fault, disabled, standby, unknown }

SensorStatus sensorStatusFrom(String? s) => _parse({
      'NORMAL': SensorStatus.normal,
      'DEGRADED': SensorStatus.degraded,
      'FAULT': SensorStatus.fault,
      'DISABLED': SensorStatus.disabled,
      'STANDBY': SensorStatus.standby,
    }, s, SensorStatus.unknown);

enum PipelineType { single, dual, triple, unavailable, unknown }

PipelineType pipelineTypeFrom(String? s) => _parse({
      'SINGLE': PipelineType.single,
      'DUAL': PipelineType.dual,
      'TRIPLE': PipelineType.triple,
      'UNAVAILABLE': PipelineType.unavailable,
    }, s, PipelineType.unknown);

enum LocalizationMode {
  lidarOnly,
  gnssOnly,
  cameraOnly,
  lidarGnss,
  lidarCamera,
  gnssCamera,
  lidarGnssCamera,
  unavailable,
  unknown
}

LocalizationMode localizationModeFrom(String? s) => _parse({
      'LIDAR_ONLY': LocalizationMode.lidarOnly,
      'GNSS_ONLY': LocalizationMode.gnssOnly,
      'CAMERA_ONLY': LocalizationMode.cameraOnly,
      'LIDAR_GNSS': LocalizationMode.lidarGnss,
      'LIDAR_CAMERA': LocalizationMode.lidarCamera,
      'GNSS_CAMERA': LocalizationMode.gnssCamera,
      'LIDAR_GNSS_CAMERA': LocalizationMode.lidarGnssCamera,
      'UNAVAILABLE': LocalizationMode.unavailable,
    }, s, LocalizationMode.unknown);

enum ModuleStatus { running, limited, stopped, error, disabled, unknown }

ModuleStatus moduleStatusFrom(String? s) => _parse({
      'RUNNING': ModuleStatus.running,
      'LIMITED': ModuleStatus.limited,
      'STOPPED': ModuleStatus.stopped,
      'ERROR': ModuleStatus.error,
      'DISABLED': ModuleStatus.disabled,
    }, s, ModuleStatus.unknown);

enum ArchitectureStatus {
  normal,
  degraded,
  fault,
  recovering,
  completed,
  standby,
  unknown
}

ArchitectureStatus architectureStatusFrom(String? s) => _parse({
      'NORMAL': ArchitectureStatus.normal,
      'DEGRADED': ArchitectureStatus.degraded,
      'FAULT': ArchitectureStatus.fault,
      'RECOVERING': ArchitectureStatus.recovering,
      'COMPLETED': ArchitectureStatus.completed,
      'STANDBY': ArchitectureStatus.standby,
    }, s, ArchitectureStatus.unknown);

enum SafetyState {
  safe,
  limitedDrive,
  failSafe,
  localizationUncertain,
  safeStopRequired,
  unknown
}

SafetyState safetyStateFrom(String? s) => _parse({
      'SAFE': SafetyState.safe,
      'LIMITED_DRIVE': SafetyState.limitedDrive,
      'FAIL_SAFE': SafetyState.failSafe,
      'LOCALIZATION_UNCERTAIN': SafetyState.localizationUncertain,
      'SAFE_STOP_REQUIRED': SafetyState.safeStopRequired,
    }, s, SafetyState.unknown);

enum ConnectionMode { demo, wifi, usbAdb, customNetwork }

String connectionModeLabel(ConnectionMode m) {
  switch (m) {
    case ConnectionMode.demo:
      return 'DEMO';
    case ConnectionMode.wifi:
      return 'WIFI';
    case ConnectionMode.usbAdb:
      return 'USB_ADB';
    case ConnectionMode.customNetwork:
      return 'CUSTOM_NETWORK';
  }
}

enum EventLevel { info, warning, success, error, unknown }

EventLevel eventLevelFrom(String? s) => _parse({
      'INFO': EventLevel.info,
      'WARNING': EventLevel.warning,
      'SUCCESS': EventLevel.success,
      'ERROR': EventLevel.error,
    }, s, EventLevel.unknown);

enum ConnectionStatus { disconnected, connecting, connected, stale }

/// Sensor role within the current localization configuration.
enum SensorRole {
  absoluteLocalization,
  relativeLocalization,
  perception,
  support,
  unused,
  unknown
}

SensorRole sensorRoleFrom(String? s) => _parse({
      'ABSOLUTE_LOCALIZATION': SensorRole.absoluteLocalization,
      'RELATIVE_LOCALIZATION': SensorRole.relativeLocalization,
      'PERCEPTION': SensorRole.perception,
      'SUPPORT': SensorRole.support,
      'UNUSED': SensorRole.unused,
    }, s, SensorRole.unknown);

String roleLabel(SensorRole r) => r.name
    .replaceAllMapped(RegExp('([A-Z])'), (m) => '_${m[1]}')
    .toUpperCase()
    .replaceFirst('_', '');

/// ---- Color semantics (single source of truth, used by all widgets) ----
class StatusColors {
  static const green = Color(0xFF3FB950);
  static const amber = Color(0xFFD29922);
  static const red = Color(0xFFF85149);
  static const gray = Color(0xFF6E7681);
  static const blue = Color(0xFF58A6FF);

  static Color sensor(SensorStatus s) {
    switch (s) {
      case SensorStatus.normal:
        return green;
      case SensorStatus.degraded:
        return amber;
      case SensorStatus.fault:
        return red;
      case SensorStatus.disabled:
      case SensorStatus.standby:
        return gray;
      case SensorStatus.unknown:
        return gray;
    }
  }

  static Color module(ModuleStatus s) {
    switch (s) {
      case ModuleStatus.running:
        return green;
      case ModuleStatus.limited:
        return amber;
      case ModuleStatus.error:
        return red;
      case ModuleStatus.stopped:
      case ModuleStatus.disabled:
        return gray;
      case ModuleStatus.unknown:
        return gray;
    }
  }

  static Color safety(SafetyState s) {
    switch (s) {
      case SafetyState.safe:
        return green;
      case SafetyState.limitedDrive:
      case SafetyState.localizationUncertain:
        return amber;
      case SafetyState.failSafe:
      case SafetyState.safeStopRequired:
        return red;
      case SafetyState.unknown:
        return gray;
    }
  }

  static Color architecture(ArchitectureStatus s) {
    switch (s) {
      case ArchitectureStatus.normal:
      case ArchitectureStatus.completed:
        return green;
      case ArchitectureStatus.degraded:
        return amber;
      case ArchitectureStatus.fault:
        return red;
      case ArchitectureStatus.recovering:
        return blue;
      case ArchitectureStatus.standby:
        return gray;
      case ArchitectureStatus.unknown:
        return gray;
    }
  }

  static Color event(EventLevel l) {
    switch (l) {
      case EventLevel.info:
        return blue;
      case EventLevel.warning:
        return amber;
      case EventLevel.success:
        return green;
      case EventLevel.error:
        return red;
      case EventLevel.unknown:
        return gray;
    }
  }

  static Color pipeline(PipelineType p) {
    switch (p) {
      case PipelineType.single:
        return amber;
      case PipelineType.dual:
        return blue;
      case PipelineType.triple:
        return green;
      case PipelineType.unavailable:
        return red;
      case PipelineType.unknown:
        return gray;
    }
  }
}
