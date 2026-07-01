import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/viewer_service.dart';

final viewerServiceProvider = Provider<ViewerService>((ref) {
  return ViewerService();
});
