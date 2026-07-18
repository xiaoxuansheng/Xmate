/// Screenshot-specific data models.
///
/// Annotation models have been moved to [package:xmate/core/annotate/annotate_models.dart].
/// This file re-exports them for backward compatibility.
library;

// Re-export shared annotation models (backward-compatible).
export 'package:xmate/core/annotate/annotate_models.dart';

/// Screenshot action type.
enum ScreenshotAction { copy, save, pin, cancel }

/// Screenshot processing result.
class ScreenshotResult {
  final List<int> imageBytes;
  final ScreenshotAction action;

  ScreenshotResult({required this.imageBytes, required this.action});
}
