/// Simple recursive-descent math expression evaluator.
///
/// Supported: + - * / % ^ ( ) unary-minus, integers and decimals.
/// Returns null for invalid / incomplete / divide-by-zero expressions.
class CalculatorService {
  String _s = '';
  int _i = 0;

  /// Evaluate [expression] and return the result, or null on error.
  double? evaluate(String expression) {
    _s = expression.trim();
    if (_s.isEmpty) return null;
    _i = 0;
    final v = _parseExpression();
    if (v == null) return null;
    // Trailing junk → invalid (e.g. "1+2abc")
    _skipWS();
    if (_i < _s.length) return null;
    return v;
  }

  // ── expression = term (('+'|'-') term)* ──
  double? _parseExpression() {
    final t = _parseTerm();
    if (t == null) return null;
    double left = t;
    _skipWS();
    while (_i < _s.length) {
      final ch = _s[_i];
      if (ch != '+' && ch != '-') break;
      _i++;
      final r = _parseTerm();
      if (r == null) return null;
      left = ch == '+' ? left + r : left - r;
      _skipWS();
    }
    return left;
  }

  // ── term = power (('*'|'/'|'%') power)* ──
  double? _parseTerm() {
    final p = _parsePower();
    if (p == null) return null;
    double left = p;
    _skipWS();
    while (_i < _s.length) {
      final ch = _s[_i];
      if (ch != '*' && ch != '/' && ch != '%') break;
      _i++;
      final r = _parsePower();
      if (r == null) return null;
      if (ch == '*') {
        left = left * r;
      } else if (ch == '%') {
        left = left % r;
      } else {
        if (r == 0) return null; // divide by zero
        left = left / r;
      }
      _skipWS();
    }
    return left;
  }

  // ── power = unary ('^' unary)*   (right-associative) ──
  double? _parsePower() {
    final base = _parseUnary();
    if (base == null) return null;
    _skipWS();
    if (_i < _s.length && _s[_i] == '^') {
      _i++;
      final exp = _parsePower(); // right-recursive
      if (exp == null) return null;
      // pow returns double, clamp large results to avoid overflow
      final r = _tryPow(base, exp);
      if (r == null) return null;
      return r;
    }
    return base;
  }

  // ── unary = '-' unary | atom ──
  double? _parseUnary() {
    _skipWS();
    if (_i < _s.length && _s[_i] == '-') {
      _i++;
      final v = _parseUnary();
      if (v == null) return null;
      return -v;
    }
    // Also handle unary plus (e.g. "+5")
    if (_i < _s.length && _s[_i] == '+') {
      _i++;
      return _parseUnary();
    }
    return _parseAtom();
  }

  // ── atom = number | '(' expression ')' ──
  double? _parseAtom() {
    _skipWS();
    if (_i >= _s.length) return null;

    if (_s[_i] == '(') {
      _i++;
      final v = _parseExpression();
      if (v == null) return null;
      _skipWS();
      if (_i >= _s.length || _s[_i] != ')') return null; // missing )
      _i++;
      return v;
    }

    return _parseNumber();
  }

  // ── number = [0-9]+ ('.' [0-9]+)? ──
  double? _parseNumber() {
    final start = _i;
    while (_i < _s.length && (_s.codeUnitAt(_i) >= 48 && _s.codeUnitAt(_i) <= 57)) {
      _i++;
    }
    if (_i < _s.length && _s[_i] == '.') {
      _i++;
      while (_i < _s.length && (_s.codeUnitAt(_i) >= 48 && _s.codeUnitAt(_i) <= 57)) {
        _i++;
      }
    }
    if (_i == start) return null; // no digits
    // If only a decimal point was consumed (e.g. ".5" without leading digit)
    if (_i == start + 1 && _s[start] == '.') return null;
    return double.parse(_s.substring(start, _i));
  }

  void _skipWS() {
    while (_i < _s.length && (_s[_i] == ' ' || _s[_i] == '\t')) {
      _i++;
    }
  }

  /// Safe power with overflow / domain protection.
  static double? _tryPow(double base, double exp) {
    if (base == 0 && exp <= 0) return null; // 0^0 or 0^-n
    if (base < 0 && exp != exp.truncateToDouble()) return null; // negative ^ fractional
    final r = _pow(base, exp);
    if (r.isNaN || r.isInfinite) return null;
    return r;
  }

  static double _pow(double base, double exp) {
    // Integer exponent — fast path
    if (exp == exp.truncateToDouble() && exp.abs() <= 1e9) {
      final n = exp.toInt();
      if (n == 0) return 1.0;
      if (n < 0) return 1.0 / _pow(base, -n.toDouble());
      // Exponentiation by squaring
      var result = 1.0;
      var b = base;
      var e = n;
      while (e > 0) {
        if (e & 1 == 1) result *= b;
        b *= b;
        e >>= 1;
      }
      return result;
    }
    // Fractional exponent via x^y = exp(y * ln(x))
    if (base <= 0) return double.nan;
    return _exp(exp * _ln(base));
  }

  /// Taylor series approximation of exp(x).
  static double _exp(double x) {
    if (x > 709) return double.infinity;
    if (x < -709) return 0.0;
    var sum = 1.0;
    var term = 1.0;
    for (var n = 1; n <= 50; n++) {
      term *= x / n;
      sum += term;
      if (term.abs() < 1e-15) break;
    }
    return sum;
  }

  /// Newton's method for ln(x).
  static double _ln(double x) {
    if (x <= 0) return double.nan;
    // Reduce to [0.5, 2] range for faster convergence
    var expAdj = 0;
    var v = x;
    while (v > 2.0) { v /= 2.0; expAdj++; }
    while (v < 0.5) { v *= 2.0; expAdj--; }
    // Initial guess
    var y = (v - 1) / (v + 1);
    var y2 = y * y;
    var sum = y;
    // ln((1+y)/(1-y)) = 2 * (y + y^3/3 + y^5/5 + ...)
    var term = y;
    for (var n = 1; n <= 30; n++) {
      term *= y2;
      sum += term / (2 * n + 1);
      if (term.abs() < 1e-16) break;
    }
    return 2.0 * sum + expAdj * 0.6931471805599453; // + k*ln(2)
  }
}
