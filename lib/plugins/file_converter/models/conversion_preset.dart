/// Conversion preset — mirrors C# `ConversionPreset`.
///
/// Holds output type, compatible input extensions, and conversion settings.
library;

import 'output_type.dart';
import 'conversion_settings.dart' as cs;

class ConversionPreset {
  final OutputType outputType;
  final List<String> inputExtensions;
  final Map<String, String> settings;

  const ConversionPreset({
    required this.outputType,
    this.inputExtensions = const [],
    this.settings = const {},
  });

  /// Create a preset with default settings for [outputType].
  /// Mirrors C# `ConversionPreset.InitializeDefaultSettings`.
  factory ConversionPreset.withDefaults(OutputType outputType) {
    return ConversionPreset(
      outputType: outputType,
      inputExtensions: cs.compatibleInputsFor(outputType),
      settings: cs.defaultSettingsFor(outputType),
    );
  }

  /// Get a typed settings value.
  T getSetting<T>(String key, T defaultValue) {
    final raw = settings[key];
    if (raw == null) return defaultValue;

    if (T == int) return int.tryParse(raw) as T? ?? defaultValue;
    if (T == double) return double.tryParse(raw) as T? ?? defaultValue;
    if (T == bool) return (raw == 'True' || raw == 'true') as T? ?? defaultValue;
    return raw as T;
  }

  bool hasSetting(String key) => settings.containsKey(key);

  ConversionPreset copyWith({
    OutputType? outputType,
    List<String>? inputExtensions,
    Map<String, String>? settings,
  }) {
    return ConversionPreset(
      outputType: outputType ?? this.outputType,
      inputExtensions: inputExtensions ?? List.from(this.inputExtensions),
      settings: settings ?? Map.from(this.settings),
    );
  }
}
