import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_model_test/screens/widgets/permission_request_widget.dart';

class SpeedWidget extends StatefulWidget {
  const SpeedWidget({super.key});

  @override
  State<SpeedWidget> createState() => _SpeedWidgetState();
}

class _SpeedWidgetState extends State<SpeedWidget> {
  static const MethodChannel _permissionChannel = MethodChannel(
    'com.example/permissions',
  );
  static const EventChannel _speedChannel = EventChannel(
    'com.example/car_speed_stream',
  );

  bool _hasCarSpeedPermission = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    setState(() => _isLoading = true);
    final bool hasPermission = await _permissionChannel.invokeMethod(
      'requestCarSpeedPermission',
    );
    setState(() {
      _hasCarSpeedPermission = hasPermission;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildText("0");
    }

    return _hasCarSpeedPermission
        ? StreamBuilder(
            stream: _speedChannel.receiveBroadcastStream(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _buildText("0");
              }

              if (!snapshot.hasData) {
                return _buildText("0");
              }

              final value = snapshot.data as double;
              return _buildText(value.toStringAsFixed(1));
            },
          )
        : PermissionRequestWidget(
            title: 'Car Speed',
            icon: Icons.speed,
            onPressed: _checkPermission,
          );
  }
}

Widget _buildText(String value) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(height: 20),
      Text(
        value,
        style: TextStyle(
          height: 0.8,
          fontSize: 80,
          fontWeight: FontWeight.w800,
          color: Colors.black,
        ),
      ),
      Text(
        'km/h',
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w500,
          color: const Color(0xff585858),
        ),
      ),
    ],
  );
}
