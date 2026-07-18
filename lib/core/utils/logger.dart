/// XMate 日志工具
///
/// 统一的日志输出接口，支持不同级别。
class Logger {
  static final Logger _instance = Logger._();
  factory Logger() => _instance;
  Logger._();

  bool _verbose = false;

  void enableVerbose() => _verbose = true;

  void info(String message) => _log('INFO', message);
  void warn(String message) => _log('WARN', message);
  void error(String message, [Object? error]) {
    _log('ERROR', message);
    if (error != null) _log('ERROR', error.toString());
  }
  void debug(String message) {
    if (_verbose) _log('DEBUG', message);
  }

  void _log(String level, String message) {
    final time = DateTime.now().toIso8601String().substring(11, 23);
    // ignore: avoid_print
    print('[$time] [$level] $message');
  }
}

final logger = Logger();
