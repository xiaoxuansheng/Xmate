library;

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../settings/settings_service.dart';

class ExchangeRateData {
  final DateTime timestamp;
  final Map<String, double> rates; // all relative to USD

  ExchangeRateData({required this.timestamp, required this.rates});
}

/// Service for fetching, caching, and converting currency exchange rates.
///
/// Rates are fetched from the free fawazahmed0/exchange-api via jsDelivr CDN
/// (no API key required, 200+ currencies, daily updates).
/// Cached in [SettingsService] under `app.exchange_rate.data` with a 12-hour
/// max age.  Cross-rate conversion is done via USD as the common base.
class ExchangeRateService {
  static const _kDataKey = 'app.exchange_rate.data';
  static const _kSourceCurrencyKey = 'app.exchange_rate.source_currency';
  static const _cacheMaxAge = Duration(hours: 12);

  static const _apiUrl =
      'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json';

  final _settings = SettingsService();

  // ── Currency definitions ──

  /// Currencies the user can select as the input (source) currency.
  static const sourceCurrencies = [
    'USD', 'CNY', 'EUR', 'GBP', 'HKD',
    'JPY', 'KRW', 'SGD', 'CHF', 'AUD', 'CAD', 'RUB',
  ];

  /// Currencies displayed in the result list (includes CNY / CNH split).
  static const targetCurrencies = [
    'CNY', 'CNH', 'USD', 'EUR', 'GBP', 'HKD',
    'JPY', 'KRW', 'SGD', 'CHF', 'AUD', 'CAD', 'RUB',
  ];

  static const _currencyNames = {
    'CNY': 'Chinese Yuan (onshore)',
    'CNH': 'Chinese Yuan (offshore)',
    'USD': 'US Dollar',
    'EUR': 'Euro',
    'GBP': 'British Pound',
    'HKD': 'Hong Kong Dollar',
    'JPY': 'Japanese Yen',
    'KRW': 'South Korean Won',
    'SGD': 'Singapore Dollar',
    'CHF': 'Swiss Franc',
    'AUD': 'Australian Dollar',
    'CAD': 'Canadian Dollar',
    'RUB': 'Russian Ruble',
  };

  // ignore: prefer_single_quotes — use double quotes to avoid \$ escaping
  static const _currencySymbols = <String, String>{
    'CNY': '¥',
    'CNH': '¥',
    'USD': r'$',
    'EUR': '€',
    'GBP': '£',
    'HKD': r'HK$',
    'JPY': '¥',
    'KRW': '₩',
    'SGD': r'S$',
    'CHF': 'Fr',
    'AUD': r'A$',
    'CAD': r'C$',
    'RUB': '₽',
  };

  static String currencyName(String code) => _currencyNames[code] ?? code;
  static String currencySymbol(String code) => _currencySymbols[code] ?? code;

  // ── Source currency persistence ──

  /// Get or set the user's last-used source currency (defaults to USD).
  String get sourceCurrency {
    return _settings.get(_kSourceCurrencyKey) as String? ?? 'USD';
  }

  set sourceCurrency(String value) {
    _settings.set(_kSourceCurrencyKey, value);
  }

  // ── Rate loading & caching ──

  /// Load exchange rates — returns cached data if fresh (<12 h),
  /// otherwise fetches from the API.
  Future<ExchangeRateData?> loadRates() async {
    // Check cache first
    final cached = _settings.get(_kDataKey);
    if (cached is Map) {
      final ts = cached['timestamp'] as String?;
      final ratesRaw = cached['rates'] as Map?;
      if (ts != null && ratesRaw != null) {
        final timestamp = DateTime.tryParse(ts);
        if (timestamp != null &&
            DateTime.now().difference(timestamp) < _cacheMaxAge) {
          final rates = <String, double>{};
          for (final e in ratesRaw.entries) {
            rates[e.key as String] = (e.value as num).toDouble();
          }
          return ExchangeRateData(timestamp: timestamp, rates: rates);
        }
      }
    }

    // Cache miss or expired — fetch from network
    return refreshRates();
  }

  /// Force-refresh rates from the API, bypassing the cache.
  Future<ExchangeRateData?> refreshRates() async {
    try {
      final response = await http
          .get(Uri.parse(_apiUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final date = json['date'] as String?;
      final usd = json['usd'] as Map<String, dynamic>?;
      if (usd == null) return null;

      final timestamp =
          date != null ? DateTime.tryParse(date) ?? DateTime.now() : DateTime.now();

      final rates = <String, double>{};
      for (final e in usd.entries) {
        rates[e.key.toLowerCase()] = (e.value as num).toDouble();
      }

      // Persist to settings
      _settings.set(_kDataKey, {
        'timestamp': timestamp.toIso8601String(),
        'rates': rates.map((k, v) => MapEntry(k, v)),
      });

      return ExchangeRateData(timestamp: timestamp, rates: rates);
    } catch (_) {
      // Network error — return stale cache as fallback
      final cached = _settings.get(_kDataKey);
      if (cached is Map) {
        final ts = cached['timestamp'] as String?;
        final ratesRaw = cached['rates'] as Map?;
        if (ts != null && ratesRaw != null) {
          final timestamp = DateTime.tryParse(ts);
          if (timestamp != null) {
            final rates = <String, double>{};
            for (final e in ratesRaw.entries) {
              rates[e.key as String] = (e.value as num).toDouble();
            }
            return ExchangeRateData(timestamp: timestamp, rates: rates);
          }
        }
      }
      return null;
    }
  }

  // ── Conversion ──

  /// Convert [amount] of [from] currency to all [targetCurrencies].
  ///
  /// All rates in [usdRates] are relative to USD, so cross-rate math is:
  ///   usdAmount = amount / usdRates[from]
  ///   targetAmount = usdAmount * usdRates[target]
  Map<String, double> convert(
      double amount, String from, Map<String, double> usdRates) {
    final fromLower = from.toLowerCase();

    // Direct conversion when source IS USD
    if (fromLower == 'usd') {
      final result = <String, double>{};
      for (final target in targetCurrencies) {
        final targetLower = target.toLowerCase();
        final rate = usdRates[targetLower];
        if (rate != null) result[target] = amount * rate;
      }
      return result;
    }

    // Cross-rate via USD for all other source currencies
    final fromRate = usdRates[fromLower];
    if (fromRate == null || fromRate == 0) return {};

    final usdAmount = amount / fromRate;
    final result = <String, double>{};
    for (final target in targetCurrencies) {
      final targetLower = target.toLowerCase();
      if (targetLower == 'usd') {
        result[target] = usdAmount;
        continue;
      }
      final rate = usdRates[targetLower];
      if (rate != null) result[target] = usdAmount * rate;
    }
    return result;
  }
}
