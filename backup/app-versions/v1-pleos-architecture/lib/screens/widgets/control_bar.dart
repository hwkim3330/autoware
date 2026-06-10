import 'package:flutter/material.dart';

class ControlBar extends StatelessWidget {
  final bool showHotspot;
  final VoidCallback? onToggleHotspot;
  final VoidCallback? onToggleMaterial;
  final VoidCallback? onSwitchOrbit;
  final VoidCallback? onSimulateFault;

  const ControlBar({
    super.key,
    required this.showHotspot,
    this.onToggleHotspot,
    this.onToggleMaterial,
    this.onSwitchOrbit,
    this.onSimulateFault,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(width: 1.0, color: Color(0xffE0E0E0)),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.2),
            blurRadius: 8.0,
            spreadRadius: 2.0,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        spacing: 4.0,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 16),
          _buildHotspotToggle(),
          // _buildIconButton(Icons.bug_report, 62, onSimulateFault!), // flutter 내부 테스트용 더미 fault 버튼 -> adb로 테스트 하지 않을때 사용
          _buildIconButton(Icons.opacity, 64, onToggleMaterial!),
          _buildIconButton(Icons.threed_rotation, 50, onSwitchOrbit!),
        ],
      ),
    );
  }

  Widget _buildIconButton(
    IconData icon,
    double iconSize,
    VoidCallback onPressed,
  ) {
    return IconButton(
      onPressed: onPressed,
      iconSize: iconSize,
      color: const Color(0xff585858),
      icon: Icon(icon),
      style: IconButton.styleFrom(
        padding: const EdgeInsets.all(20.0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    );
  }

  Widget _buildHotspotToggle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Transform.scale(
          scale: 1.8,
          child: Switch(
            value: showHotspot,
            onChanged: (bool value) {
              onToggleHotspot?.call();
            },
            activeTrackColor: const Color(0xff585858),
            inactiveTrackColor: Colors.grey.shade300,
            thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
            trackOutlineColor: const WidgetStatePropertyAll<Color>(
              Colors.transparent,
            ),
          ),
        ),
        const SizedBox(width: 32),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Label",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Color(0xff585858),
              ),
            ),
            Text(
              showHotspot == false ? "Off" : "On",
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w500,
                color: Color(0xff585858),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
