/// File name template utility.
///
/// Replaces placeholders in a template string with timestamp values:
///   %yyyy%   four-digit year
///   %MM%     two-digit month (01-12)
///   %dd%     two-digit day of month (01-31)
///   %HH%     two-digit hour (00-23)
///   %mm%     two-digit minute (00-59)
///   %ss%     two-digit second (00-59)
///
/// Example:
///   template: "recording_%yyyy%-%MM%-%dd%_%HH%%mm%%ss%"
///   result:   "recording_2026-07-03_143025"
library;

import 'dart:convert';
import 'dart:io';

String formatFilename(String template, DateTime ts) {
  return template
      .replaceAll('%yyyy%', ts.year.toString().padLeft(4, '0'))
      .replaceAll('%MM%', ts.month.toString().padLeft(2, '0'))
      .replaceAll('%dd%', ts.day.toString().padLeft(2, '0'))
      .replaceAll('%HH%', ts.hour.toString().padLeft(2, '0'))
      .replaceAll('%mm%', ts.minute.toString().padLeft(2, '0'))
      .replaceAll('%ss%', ts.second.toString().padLeft(2, '0'));
}

/// Default file name templates.
const kDefaultScreenshotTemplate = 'Screenshot_%yyyy%-%MM%-%dd%_%HH%%mm%%ss%';
const kDefaultRecordingTemplate = 'Recording_%yyyy%-%MM%-%dd%_%HH%%mm%%ss%';

/// Decode bytes from a Windows console process (e.g. FFmpeg).
///
/// FFmpeg emits device names in the console code page — CP936 on
/// Chinese Windows, CP932 on Japanese, etc.  Dart's [systemEncoding]
/// maps to the ANSI code page which is NOT the console code page.
/// This function tries the console code page first via
/// [Encoding.getByName('gbk')] (the most common CJK target), then
/// UTF-8, then falls back to the system encoding.
String decodeWinConsole(List<int> bytes) {
  final gbk = Encoding.getByName('gbk');
  if (gbk != null) {
    try { return gbk.decode(bytes); } catch (_) {}
  }
  try { return utf8.decode(bytes, allowMalformed: true); } catch (_) {}
  return systemEncoding.decode(bytes);
}
