/// Pin service — creates native Pin windows from PNG image bytes.
///
/// Each Pin window is a real OS-level WS_POPUP window rendered via GDI+.
/// The window is topmost, draggable, resizable, and closes on double-click.
/// Multiple Pin windows can coexist; each stores the image it was created with.
library;

import 'package:flutter/services.dart';

class PinService {
  static const _channel = MethodChannel('com.xmate/pin');

  /// Create a native pin window displaying [pngBytes].
  ///
  /// If [sel] is provided, the native window is positioned and sized
  /// to match the selection rectangle (in Flutter logical pixels).
  /// Coordinates are relative to the screen origin.
  ///
  /// Returns normally on success; throws [PlatformException] on failure.
  Future<void> createPin(Uint8List pngBytes, Rect? sel) async {
    final args = <String, dynamic>{'png': pngBytes};
    if (sel != null) {
      args['x'] = sel.left;
      args['y'] = sel.top;
      args['width'] = sel.width;
      args['height'] = sel.height;
    }
    await _channel.invokeMethod('createPin', args);
  }
}
