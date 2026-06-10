import 'package:flutter/material.dart';

class LegendCard extends StatelessWidget {
  const LegendCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 232,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Color(0xffE0E0E0), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          _buildUnitLabel(Color(0xffffa423), 'Lidar'),
          _buildUnitLabel(Color(0xffd179ff), 'Radar'),
          _buildUnitLabel(Color(0xff00e578), 'Camera'),
          SizedBox(
            width: double.infinity,
            child: Divider(color: Color(0xffE0E0E0), thickness: 1.0),
          ),
          _buildConnectionLabel(Color(0xff4040d5), 'ETH'),
          _buildConnectionLabel(Color(0xff76afdf), '10Base-T1'),
        ],
      ),
    );
  }

  Widget _buildUnitLabel(Color color, String label) {
    return Row(
      spacing: 8,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _buildConnectionLabel(Color color, String label) {
    return Row(
      spacing: 8,
      children: [
        Container(width: 32, height: 8, color: color),
        Text(
          label,
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
