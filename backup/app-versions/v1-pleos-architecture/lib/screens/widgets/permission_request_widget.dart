import 'package:flutter/material.dart';

class PermissionRequestWidget extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onPressed;
  const PermissionRequestWidget({
    super.key,
    required this.title,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.grey.withValues(alpha: 0.2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: Colors.grey),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 24, color: Colors.white70),
          ),
          const SizedBox(height: 20),
          Text(
            'Need Permission to See the Data',
            style: const TextStyle(fontSize: 18, color: Colors.white70),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: onPressed,
            child: const Text('Request Permission'),
          ),
        ],
      ),
    );
  }
}
