library;

import 'package:flutter/services.dart';

/// Native file/folder picker service using COM IFileOpenDialog.
class PickerService {
  static final PickerService _instance = PickerService._();
  factory PickerService() => _instance;
  PickerService._();

  static const _ch = MethodChannel('com.xmate/picker');

  /// Open a native folder selection dialog.
  Future<String?> pickFolder() async {
    try {
      final result = await _ch.invokeMethod<String>('pickFolder');
      return (result == null || result.isEmpty) ? null : result;
    } catch (_) {
      return null;
    }
  }

  /// Open a native file selection dialog.
  /// [title] is the dialog title. Returns the selected file path or null.
  Future<String?> pickFile({String title = 'Select file'}) async {
    try {
      final result = await _ch.invokeMethod<String>(
        'pickFile',
        {'title': title},
      );
      return (result == null || result.isEmpty) ? null : result;
    } catch (_) {
      return null;
    }
  }
}
