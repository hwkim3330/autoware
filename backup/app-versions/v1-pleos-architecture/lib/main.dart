import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/car_viewer_screen.dart';

void main() => runApp(const ProviderScope(child: MyApp()));

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zonal Architecture Viewer',
      theme: ThemeData(scaffoldBackgroundColor: Colors.white),
      home: const CarViewerScreen(),
    );
  }
}
