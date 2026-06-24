import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/niro_command_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ProviderScope(child: NiroCommandApp()));
}

class NiroCommandApp extends StatelessWidget {
  const NiroCommandApp({super.key});

  @override
  Widget build(BuildContext context) {
    // APP_MODE is passed at build time (--dart-define=APP_MODE=hmi for the
    // read-only flavor); purely cosmetic for the window title.
    const mode = String.fromEnvironment('APP_MODE', defaultValue: 'command');
    return MaterialApp(
      title: mode == 'hmi' ? 'Niro HMI' : 'Niro Command',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFEFF2F6),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
      ),
      home: const NiroCommandScreen(),
    );
  }
}
