/// 截图捕获服务抽象
library;

import 'dart:typed_data';

/// Holds captured screen image together with the monitor metadata needed
/// for multi-monitor coordinate and DPI handling.
class ScreenCapture {
  final Uint8List png;
  final double dpr;
  final int monX, monY, monW, monH;
  const ScreenCapture({
    required this.png,
    required this.dpr,
    required this.monX,
    required this.monY,
    required this.monW,
    required this.monH,
  });
}

/// 屏幕捕获服务接口
///
/// 不同平台有不同实现：
/// - Windows: 通过 Win32 GDI+ 捕获
/// - macOS/iOS: 系统截图 API
abstract class CaptureService {
  /// 捕获鼠标所在的屏幕，返回 PNG 字节数据及显示器元数据
  Future<ScreenCapture> captureFullScreen();
}
