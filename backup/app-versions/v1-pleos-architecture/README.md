# pleos_auto_manager

Pleos Connect-based Automotive Ethernet Manager

### Technology Stack

- **Framework**: Flutter 3.9.2+
- **State Management**: Riverpod 2.5.1
- **3D Rendering**: model_viewer_plus 1.9.3
- **Code Generation**: Freezed & JSON Serializable
- **Platform**: Android Automotive OS (API 30+)

### Project Structure

```
lib/
├── core/                # Core utilities and constants
├── models/              # Data models with Freezed annotations
├── providers/           # Riverpod state providers
├── repositories/        # Data mapping and transformation
├── screens/             # UI screens and widgets
├── services/            # Business logic and external communication
└── assets/              # 3D models and static resources
```

## Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/KETI-Mobility/pleos_auto_manager.git
   cd pleos_auto_manager
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Generate code files**
   ```bash
   flutter packages pub run build_runner build
   ```

## How to Run

### For Development

**For Android Emulator:**
```bash
# Run specific android device(preferably Pleos emulator)
flutter emulators --launch <device-id>

# Run in debug mode with hot reload
flutter run
```

**For Web (Development Testing):**
```bash
# Run on web browser (for UI testing only)
flutter run -d chrome --web-port 8080
```

### For Production

**Android APK Build:**
```bash
# Build release APK
flutter build apk --release

# Build app bundle (recommended for Play Store)
flutter build appbundle --release

# Install release APK to connected device/emulator
flutter install --release
```

**Android Automotive OS Deployment:**
```bash
# Build for AAOS with specific configurations
flutter build apk --release --target-platform android-arm64

# For sideloading to AAOS systems
adb install build/app/outputs/flutter-apk/app-release.apk
```

## Reference

Please refer to [Pleos Connect 기반 Zonal 아키텍처 응용 및 관제 SW 발표 및 데모](presentation.pdf) for detailed information on the project, and [cbor_testing.md](cbor_testing.md) for explanation on how to test the project's features using ADB commands.