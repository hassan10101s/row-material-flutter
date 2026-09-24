import 'dart:math' as math;

import '../../../core/constants/app_errors.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';

/// Port of core/services/lab.py — unit tables, constant resolution library
/// and the safe formula engine (no eval()): a recursive-descent parser that
/// supports + - * / % ^ **, comparisons, and/or/not, and safe math functions.

// ── Units ────────────────────────────────────────────────────────────────

const List<String> inventoryCategories = ['liquid', 'powder'];
const List<String> inventoryUnits = ['L', 'mL', 'kg', 'g', 'pc'];
const List<String> sourceTypes = ['raw_material', 'product'];

const Map<String, double> _unitFactors = {
  'l': 1000.0, // → base mL
  'ml': 1.0,
  'kg': 1000.0, // → base g
  'g': 1.0,
  'pc': 1.0,
};
const Map<String, String> _unitDims = {
  'l': 'volume',
  'ml': 'volume',
  'kg': 'mass',
  'g': 'mass',
  'pc': 'count',
};
const List<String> unitOptions = ['L', 'mL', 'kg', 'g', 'pc'];

double? parseNumber(String? token) {
  final t = (token ?? '').trim();
  if (t.isEmpty) return null;
  final parsed = safeFormulaFloat(t);
  return parsed ?? safeFormulaFloat(t.replaceAll(',', '.'));
}

Expr parseFormula(String expression) => FormulaParser.parse(expression);

String unitDimOf(Object? unit) {
  final u = '$unit'.trim().toLowerCase();
  if (u.isEmpty) return 'count';
  return _unitDims[u] ?? '';
}

double unitBaseValue(double value, String unit) {
  final u = unit.trim().toLowerCase();
  final factor = _unitFactors[u];
  if (factor == null) return value;
  return value * factor;
}

double unitBaseToUnit(double value, String unit) {
  final u = unit.trim().toLowerCase();
  final factor = _unitFactors[u];
  if (factor == null) return value;
  return value / factor;
}

/// convert_quantity: convert between compatible units; unknown/mismatched
/// dimensions return [qty] unchanged.
double convertQuantity(double qty, String fromUnit, String toUnit) {
  final f = fromUnit.trim().toLowerCase();
  final t = toUnit.trim().toLowerCase();
  if (f.isEmpty || t.isEmpty || f == t) return qty;
  final fFactor = _unitFactors[f];
  final tFactor = _unitFactors[t];
  if (fFactor == null || tFactor == null || _unitDims[f] != _unitDims[t]) {
    return qty;
  }
  return qty * fFactor / tFactor;
}

const List<String> _arabicMonths = [
  'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
  'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
];

String monthLabel(String key) {
  final m = int.tryParse(key.length >= 7 ? key.substring(5, 7) : '');
  if (m == null || m < 1 || m > 12) return key;
  return '${_arabicMonths[m - 1]} ${key.substring(0, 4)}';
}

// ── Constant presets ─────────────────────────────────────────────────────

const List<Map<String, dynamic>> constantPresetsList = [
  {'symbol': 'F_PROT', 'name': 'Kjeldahl protein factor', 'value': 6.25,
   'unit': '', 'unit_dim': '', 'description': 'General protein conversion factor (N x 6.25).'},
  {'symbol': 'F_WHEAT', 'name': 'Kjeldahl wheat protein factor', 'value': 5.70,
   'unit': '', 'unit_dim': '', 'description': 'Wheat protein conversion factor (N x 5.70).'},
  {'symbol': 'F_DAIRY', 'name': 'Kjeldahl dairy protein factor', 'value': 6.38,
   'unit': '', 'unit_dim': '', 'description': 'Dairy protein conversion factor (N x 6.38).'},
  {'symbol': 'K_LIPID', 'name': 'Total lipid factor', 'value': 1.4007,
   'unit': '', 'unit_dim': '', 'description': 'Factor used in some lipid/acidimetric methods.'},
  {'symbol': 'D_WATER', 'name': 'Density of water', 'value': 1.0,
   'unit': 'g', 'unit_dim': 'mass', 'description': 'Density of water in g/mL (1 g per mL).'},
  {'symbol': 'MV_DIL', 'name': 'Dilution factor (recipe)', 'value': 1.0,
   'unit': '', 'unit_dim': '', 'description': 'Recipe dilution factor to apply.'},
  {'symbol': 'C_NACL', 'name': 'Molar mass NaCl', 'value': 58.44,
   'unit': 'g', 'unit_dim': 'mass', 'description': 'Molar mass of sodium chloride (g/mol).'},
  {'symbol': 'C_NAOH', 'name': 'Molar mass NaOH', 'value': 40.0,
   'unit': 'g', 'unit_dim': 'mass', 'description': 'Molar mass of sodium hydroxide (g/mol).'},
  {'symbol': 'C_HCL', 'name': 'Molar mass HCl', 'value': 36.46,
   'unit': 'g', 'unit_dim': 'mass', 'description': 'Molar mass of hydrogen chloride (g/mol).'},
  {'symbol': 'M_N', 'name': 'Molar mass of nitrogen', 'value': 14.007,
   'unit': 'g', 'unit_dim': 'mass', 'description': 'Atomic mass of nitrogen (g/mol).'},
];

/// Default analyses seeded on first lab setup.
const List<Map<String, dynamic>> defaultAnalyses = [
  {
    'name': 'Protein', 'unit': '%',
    'description': 'Kjeldahl total protein',
    'dynamic_fields': ['Sample Name', 'Notes'],
    'items': [
      {'name': 'H2SO4 Concentrated', 'qty': 15, 'unit': 'mL'},
      {'name': 'HCl 0.1M', 'qty': 10, 'unit': 'mL'},
      {'name': 'Kjeldahl Catalyst Tablet', 'qty': 1, 'unit': 'pc'},
    ],
  },
  {
    'name': 'Fat', 'unit': '%', 'description': 'Soxhlet ether extract',
    'dynamic_fields': ['Sample Name', 'Notes'],
    'items': [
      {'name': 'Petroleum Ether', 'qty': 200, 'unit': 'mL'},
    ],
  },
  {
    'name': 'Moisture', 'unit': '%', 'description': 'Oven dry method',
    'dynamic_fields': ['Sample Name', 'Notes'], 'items': [],
  },
  {
    'name': 'Ash', 'unit': '%', 'description': 'Muffle furnace',
    'dynamic_fields': ['Sample Name', 'Notes'], 'items': [],
  },
];

// ── Constant resolution ──────────────────────────────────────────────────

Map<String, dynamic> normalizeConstantDesc(Object? value, {String? symbol}) {
  Map<String, dynamic> desc;
  if (value is Map) {
    desc = Map<String, dynamic>.from(value);
  } else {
    desc = {'value': value, 'unit': '', 'unit_dim': ''};
  }
  if (symbol != null && _strIsEmpty('${desc['symbol'] ?? ''}')) {
    desc['symbol'] = symbol;
  }
  desc['unit'] ??= '';
  desc['unit_dim'] ??= '';
  desc['is_expression'] ??= 0;
  desc['expression'] ??= '';
  desc.putIfAbsent('min_value', () => null);
  desc.putIfAbsent('max_value', () => null);
  desc.putIfAbsent('precision', () => null);
  return desc;
}

bool _strIsEmpty(String s) => s.trim().isEmpty;

double? _numericOf(Map<String, dynamic> desc) {
  final raw = desc['value'];
  if (raw == null || '$raw'.trim().isEmpty) return null;
  return safeFormulaFloat(raw);
}

double? safeFormulaFloat(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final s = '$value'.replaceAll(',', '.').trim();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

/// Resolve a {symbol: value|desc} map into {symbol: double}, supporting
/// derived/expression constants with dependency ordering, unit conversion,
/// range validation and precision.
Map<String, dynamic> resolveConstants(
  Map<String, dynamic>? constants, {
  List<String>? exprVars,
  String targetUnit = '',
}) {
  final targetDim = unitDimOf(targetUnit);
  final descs = <String, Map<String, dynamic>>{};
  (constants ?? {}).forEach((symbol, value) {
    final sym = symbol.trim();
    if (sym.isEmpty) return;
    descs[sym] = normalizeConstantDesc(value, symbol: sym);
  });

  double convertDim(Map<String, dynamic> desc, double baseValue) {
    final u = '${desc['unit'] ?? ''}'.trim().toLowerCase();
    final dim = unitDimOf(u);
    if (targetDim.isNotEmpty && dim.isNotEmpty && dim != 'count' && targetDim != dim) {
      throw ValidationError(AppErrors.formulaUnitDimMismatch(
          desc['symbol'] ?? '', u, targetDim));
    }
    if (targetDim.isNotEmpty && targetDim != 'count' && dim.isNotEmpty && dim != 'count') {
      return unitBaseValue(baseValue, u);
    }
    return baseValue;
  }

  final resolved = <String, double>{};
  final pending = descs.keys.toSet();
  final maxRounds = pending.length + 1;
  var rounds = 0;
  while (pending.isNotEmpty) {
    rounds++;
    if (rounds > maxRounds) {
      throw ValidationError(AppErrors.formulaCircularDependency);
    }
    var progressed = false;
    for (final symbol in pending.toList()) {
      final desc = descs[symbol]!;
      double value;
      if ((desc['is_expression'] as Object?) == 1 || desc['is_expression'] is bool && desc['is_expression'] == true) {
        final expr = '${desc['expression'] ?? ''}'.trim();
        if (expr.isEmpty) {
          throw ValidationError(AppErrors.formulaDerivedNoExpression(symbol));
        }
        final tree = FormulaParser.parse(expr);
        final used =
            formulaVariablesOfTree(tree).where(pending.contains).toSet();
        if (used.isNotEmpty) continue;
        final vals = <String, Object?>{};
        var allResolved = true;
        for (final u in formulaVariablesOfTree(tree)) {
          if (!resolved.containsKey(u) && u.toLowerCase() != 'true' && u.toLowerCase() != 'false') {
            allResolved = false;
            break;
          }
          if (resolved.containsKey(u)) vals[u] = resolved[u];
        }
        if (!allResolved) continue;
        Object? result;
        try {
          result = FormulaEvaluator.eval(tree, values: vals);
        } on ValidationError catch (exc) {
          throw ValidationError(AppErrors.formulaEvalError(symbol, exc.message));
        }
        value = convertDim(desc, _toNum(result));
      } else {
        final num = _numericOf(desc);
        if (num == null) {
          throw ValidationError(AppErrors.formulaMissingConstantValue(symbol));
        }
        value = convertDim(desc, num);
      }
      final lo = desc['min_value'];
      final hi = desc['max_value'];
      if (lo != null && value < safeFormulaFloat(lo)!) {
        throw ValidationError(AppErrors.formulaBelowMin(symbol, value, lo));
      }
      if (hi != null && value > safeFormulaFloat(hi)!) {
        throw ValidationError(AppErrors.formulaAboveMax(symbol, value, hi));
      }
      final prec = desc['precision'];
      if (prec != null) {
        final p = int.tryParse('$prec');
        if (p != null) value = _roundTo(value, p);
      }
      resolved[symbol] = value;
      pending.remove(symbol);
      progressed = true;
    }
    if (!progressed) {
      final unresolved = pending.toList()..sort();
      throw ValidationError(AppErrors.formulaResolveFailed(unresolved.join(', ')));
    }
  }

  if (exprVars != null) {
    final missing = [
      for (final v in exprVars)
        if (!resolved.containsKey(v) && v.toLowerCase() != 'true' && v.toLowerCase() != 'false') v
    ];
    if (missing.isNotEmpty) {
      throw ValidationError(AppErrors.formulaMissingValues(missing.join(', ')));
    }
  }
  return resolved;
}

double _toNum(Object? value) {
  final v = safeFormulaFloat(value);
  if (v == null) throw ValidationError(AppErrors.formulaResultNotNumeric);
  return v;
}

double _roundTo(double value, int digits) {
  final f = math.pow(10, digits).toDouble();
  return (value * f).roundToDouble() / f;
}

double evaluateFormula(String expression,
    {Map<String, dynamic>? values,
    Map<String, dynamic>? constants,
    String targetUnit = ''}) {
  final expr = expression.trim();
  if (expr.isEmpty) throw ValidationError(AppErrors.formulaEmpty);
  final resolved =
      resolveConstants(constants ?? const {}, targetUnit: targetUnit);
  final tree = FormulaParser.parse(expr);
  final safeValues = <String, Object?>{};
  (values ?? {}).forEach((k, v) {
    if (resolved.containsKey(k)) return;
    safeValues[k] = v;
  });
  final r = FormulaEvaluator.eval(tree, values: safeValues, constants: resolved);
  return _toNum(r);
}

Map<String, dynamic> constantPreviewValue(
    Map<String, dynamic> desc, Map<String, dynamic>? allConstants) {
  final symbol = '${desc['symbol'] ?? ''}'.trim();
  try {
    final merged = Map<String, dynamic>.from(allConstants ?? const {});
    if (symbol.isNotEmpty && !merged.containsKey(symbol)) merged[symbol] = desc;
    final resolved = resolveConstants(merged);
    if (symbol.isNotEmpty && resolved.containsKey(symbol)) {
      return {'ok': true, 'value': resolved[symbol], 'error': null};
    }
    return {'ok': true, 'value': null, 'error': 'Not resolvable.'};
  } on ValidationError catch (exc) {
    return {'ok': false, 'value': null, 'error': exc.message};
  }
}

// ── Formula engine ───────────────────────────────────────────────────────

/// Formula AST node.
sealed class Expr {
  const Expr();
}

class NumExpr extends Expr {
  final double value;
  const NumExpr(this.value);
}

class NameExpr extends Expr {
  final String name;
  const NameExpr(this.name);
}

class BinExpr extends Expr {
  final String op;
  final Expr left;
  final Expr right;
  const BinExpr(this.op, this.left, this.right);
}

class UnaryExpr extends Expr {
  final String op;
  final Expr operand;
  const UnaryExpr(this.op, this.operand);
}

class CompareExpr extends Expr {
  final Expr left;
  final List<String> ops;
  final List<Expr> comparators;
  const CompareExpr(this.left, this.ops, this.comparators);
}

class BoolExpr extends Expr {
  final String op; // 'and' | 'or'
  final List<Expr> operands;
  const BoolExpr(this.op, this.operands);
}

class NotExpr extends Expr {
  final Expr operand;
  const NotExpr(this.operand);
}

class CallExpr extends Expr {
  final String name;
  final List<Expr> args;
  const CallExpr(this.name, this.args);
}

class FormulaParser {
  static Expr parse(String expression) {
    // Normalize decimal comma -> dot (only between digits) and '^' -> '**'.
    var expr = expression.replaceAll(RegExp(r'(?<=\d),(?=\d)'), '.');
    expr = expr.replaceAll('^', '**');
    final p = FormulaParser(expr);
    if (expr.trim().isEmpty) throw ValidationError(AppErrors.formulaEmpty);
    final tree = p._parseOr();
    if (!p._atEnd) {
      throw ValidationError(AppErrors.formulaInvalidSyntax);
    }
    _validate(tree);
    return tree;
  }

  final String _src;
  int _pos = 0;
  FormulaParser(this._src);

  bool get _atEnd => _pos >= _src.length;

  void _ws() {
    while (!_atEnd && RegExp(r'\s').hasMatch(_src[_pos])) {
      _pos++;
    }
  }

  bool _tryPeek(String word) {
    _ws();
    if (_pos + word.length <= _src.length &&
        _src.substring(_pos, _pos + word.length) == word) {
      final next = _pos + word.length;
      if (next < _src.length && RegExp(r'[A-Za-z0-9_]').hasMatch(_src[next])) {
        return false;
      }
      return true;
    }
    return false;
  }

  bool _matchWord(String word) {
    if (!_tryPeek(word)) return false;
    _pos += word.length;
    _ws();
    return true;
  }

  bool _matchOp(String op) {
    _ws();
    if (_pos + op.length <= _src.length &&
        _src.substring(_pos, _pos + op.length) == op) {
      _pos += op.length;
      _ws();
      return true;
    }
    return false;
  }

  Expr _parseOr() {
    var left = _parseAnd();
    while (_matchWord('or')) {
      final operands = [left, _parseAnd()];
      while (_matchWord('or')) {
        operands.add(_parseAnd());
      }
      left = BoolExpr('or', operands);
    }
    return left;
  }

  Expr _parseAnd() {
    var left = _parseNot();
    while (_matchWord('and')) {
      final operands = [left, _parseNot()];
      while (_matchWord('and')) {
        operands.add(_parseNot());
      }
      left = BoolExpr('and', operands);
    }
    return left;
  }

  Expr _parseNot() {
    if (_matchWord('not')) return NotExpr(_parseNot());
    return _parseComparison();
  }

  Expr _parseComparison() {
    var left = _parseAdditive();
    final ops = <String>[];
    final comps = <Expr>[];
    while (true) {
      String? op;
      if (_matchOp('==')) {
        op = '==';
      } else if (_matchOp('!=')) {
        op = '!=';
      } else if (_matchOp('<=')) {
        op = '<=';
      } else if (_matchOp('>=')) {
        op = '>=';
      } else if (_matchOp('<')) {
        op = '<';
      } else if (_matchOp('>')) {
        op = '>';
      }
      if (op == null) break;
      final right = _parseAdditive();
      ops.add(op);
      comps.add(right);
      left = left;
    }
    if (ops.isEmpty) return left;
    return CompareExpr(left, ops, comps);
  }

  Expr _parseAdditive() {
    var left = _parseMultiplicative();
    while (true) {
      if (_matchOp('+')) {
        left = BinExpr('+', left, _parseMultiplicative());
      } else if (_matchOp('-')) {
        left = BinExpr('-', left, _parseMultiplicative());
      } else {
        break;
      }
    }
    return left;
  }

  Expr _parseMultiplicative() {
    var left = _parseUnary();
    while (true) {
      if (_matchOp('*')) {
        left = BinExpr('*', left, _parseUnary());
      } else if (_matchOp('/')) {
        left = BinExpr('/', left, _parseUnary());
      } else if (_matchOp('%')) {
        left = BinExpr('%', left, _parseUnary());
      } else {
        break;
      }
    }
    return left;
  }

  Expr _parseUnary() {
    _ws();
    if (_matchOp('+')) return UnaryExpr('+', _parseUnary());
    if (_matchOp('-')) return UnaryExpr('-', _parseUnary());
    return _parsePower();
  }

  Expr _parsePower() {
    final base = _parseAtom();
    if (_matchOp('**')) {
      return BinExpr('**', base, _parseUnary());
    }
    return base;
  }

  Expr _parseAtom() {
    _ws();
    if (_atEnd) throw ValidationError(AppErrors.formulaInvalidSyntax);
    final ch = _src[_pos];
    if (ch == '(') {
      _pos++;
      final inner = _parseOr();
      _ws();
      if (_atEnd || _src[_pos] != ')') {
        throw ValidationError(AppErrors.formulaInvalidSyntax);
      }
      _pos++;
      _ws();
      return inner;
    }
    if (RegExp(r'\d').hasMatch(ch) || (ch == '.' && _pos + 1 < _src.length && RegExp(r'\d').hasMatch(_src[_pos + 1]))) {
      return NumExpr(_parseNumber());
    }
    if (RegExp(r'[A-Za-z_]').hasMatch(ch)) {
      return _parseNameOrCall();
    }
    throw ValidationError(AppErrors.formulaInvalidSyntax);
  }

  double _parseNumber() {
    final start = _pos;
    while (!_atEnd && RegExp(r'[0-9.]').hasMatch(_src[_pos])) {
      _pos++;
    }
    final text = _src.substring(start, _pos);
    final value = double.tryParse(text);
    if (value == null) throw ValidationError(AppErrors.formulaInvalidNumber);
    _ws();
    return value;
  }

  Expr _parseNameOrCall() {
    final start = _pos;
    while (!_atEnd && RegExp(r'[A-Za-z0-9_]').hasMatch(_src[_pos])) {
      _pos++;
    }
    final name = _src.substring(start, _pos);
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ValidationError(AppErrors.formulaInvalidName(name));
    }
    _ws();
    if (!_atEnd && _src[_pos] == '(') {
      _pos++;
      final args = <Expr>[];
      _ws();
      if (!_atEnd && _src[_pos] == ')') {
        _pos++;
      } else {
        while (true) {
          args.add(_parseOr());
          _ws();
          if (_atEnd) throw ValidationError(AppErrors.formulaInvalidSyntax);
          if (_src[_pos] == ',') {
            _pos++;
            continue;
          }
          if (_src[_pos] == ')') {
            _pos++;
            break;
          }
          throw ValidationError(AppErrors.formulaInvalidSyntax);
        }
      }
      _ws();
      if (!_funcMap.containsKey(name)) {
        throw ValidationError(AppErrors.formulaUnsupportedFunction(name));
      }
      return CallExpr(name, args);
    }
    return NameExpr(name);
  }

  static final Map<String, String> _funcMap = {
    'abs': 'abs', 'round': 'round', 'min': 'min', 'max': 'max',
    'sqrt': 'sqrt', 'pow': 'pow', 'log': 'log', 'log10': 'log10', 'exp': 'exp',
  };

  static void _validate(Expr node) {
    switch (node) {
      case NameExpr n:
        if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n.name)) {
          throw ValidationError(AppErrors.formulaInvalidName(n.name));
        }
      case CallExpr c:
        if (!_funcMap.containsKey(c.name)) {
          throw ValidationError(AppErrors.formulaUnsupportedFunction(c.name));
        }
        for (final a in c.args) {
          _validate(a);
        }
      case BinExpr b:
        _validate(b.left);
        _validate(b.right);
      case UnaryExpr u:
        _validate(u.operand);
      case CompareExpr c:
        _validate(c.left);
        for (final x in c.comparators) {
          _validate(x);
        }
      case BoolExpr bo:
        for (final x in bo.operands) {
          _validate(x);
        }
      case NotExpr n:
        _validate(n.operand);
      default:
        break;
    }
  }
}

class FormulaEvaluator {
  static Object eval(Expr node,
      {Map<String, Object?>? values,
      Map<String, Object?>? constants}) {
    switch (node) {
      case NumExpr n:
        return n.value;
      case NameExpr name:
        if (name.name == 'true') return 1.0;
        if (name.name == 'false') return 0.0;
        final v = values?[name.name];
        if (v != null) {
          final d = safeFormulaFloat(v);
          if (d != null) return d;
          throw ValidationError(AppErrors.formulaMissingFieldValue(name.name));
        }
        if (constants != null && constants.containsKey(name.name)) {
          return constants[name.name]!;
        }
        throw ValidationError(AppErrors.formulaMissingFieldValue(name.name));
      case BinExpr b:
        final l = eval(b.left, values: values, constants: constants);
        final r = eval(b.right, values: values, constants: constants);
        final ld = _toNum(l);
        final rd = _toNum(r);
        switch (b.op) {
          case '+':
            return ld + rd;
          case '-':
            return ld - rd;
          case '*':
            return ld * rd;
          case '/':
            if (rd == 0) throw ValidationError(AppErrors.formulaDivisionByZero);
            return ld / rd;
          case '%':
            return ld % rd;
          case '**':
            final result = math.pow(ld, rd);
            if (result.isInfinite || result.isNaN) {
              throw ValidationError(AppErrors.formulaInvalidPower(ld, rd));
            }
            return result.toDouble();
        }
        throw ValidationError(AppErrors.formulaUnsupportedOperator);
      case UnaryExpr u:
        final v = _toNum(eval(u.operand, values: values, constants: constants));
        return u.op == '-' ? -v : v;
      case CompareExpr c:
        final valuesList = <double>[_toNum(eval(c.left, values: values, constants: constants))];
        for (final comp in c.comparators) {
          valuesList.add(_toNum(eval(comp, values: values, constants: constants)));
        }
        var outcome = true;
        for (var i = 0; i < c.ops.length; i++) {
          final a = valuesList[i];
          final b = valuesList[i + 1];
          final ok = switch (c.ops[i]) {
            '==' => a == b,
            '!=' => a != b,
            '<' => a < b,
            '<=' => a <= b,
            '>' => a > b,
            '>=' => a >= b,
            _ => false,
          };
          if (!ok) {
            outcome = false;
            break;
          }
        }
        return outcome ? 1.0 : 0.0;
      case BoolExpr bo:
        if (bo.op == 'and') {
          var result = true;
          for (final operand in bo.operands) {
            result = result && _toNum(eval(operand, values: values, constants: constants)) != 0;
          }
          return result ? 1.0 : 0.0;
        }
        var result = false;
        for (final operand in bo.operands) {
          result = result || _toNum(eval(operand, values: values, constants: constants)) != 0;
        }
        return result ? 1.0 : 0.0;
      case NotExpr n:
        final v = _toNum(eval(n.operand, values: values, constants: constants));
        return v == 0 ? 1.0 : 0.0;
      case CallExpr c:
        final args = [for (final a in c.args) _toNum(eval(a, values: values, constants: constants))];
        final result = _callFunction(c.name, args);
        if (result.isInfinite || result.isNaN) {
          throw ValidationError(AppErrors.formulaInvalidArguments(c.name));
        }
        return result;
    }
  }

  static double _callFunction(String name, List<double> args) {
    switch (name) {
      case 'abs':
        return args.first.abs();
      case 'round':
        if (args.length == 1) return args.first.roundToDouble();
        return _roundTo(args.first, args[1].toInt());
      case 'min':
        return args.reduce(math.min);
      case 'max':
        return args.reduce(math.max);
      case 'sqrt':
        return math.sqrt(args.first);
      case 'pow':
        return math.pow(args[0], args[1]).toDouble();
      case 'log':
        return args.length == 1 ? math.log(args.first) : math.log(args.first) / math.log(args[1]);
      case 'log10':
        return math.log(args.first) / math.ln10;
      case 'exp':
        return math.exp(args.first);
    }
    throw ValidationError(AppErrors.formulaUnsupportedFunction(name));
  }
}

/// Ordered unique variable names referenced in a formula.
List<String> formulaVariables(String expression) {
  if (expression.trim().isEmpty) return const [];
  final tree = FormulaParser.parse(expression);
  return formulaVariablesOfTree(tree);
}

List<String> formulaVariablesOfTree(Expr tree) {
  final names = <String>[];
  final seen = <String>{};

  void walk(Expr node) {
    switch (node) {
      case NameExpr n:
        if (!seen.contains(n.name)) {
          seen.add(n.name);
          names.add(n.name);
        }
      case CallExpr c:
        for (final a in c.args) {
          walk(a);
        }
      case BinExpr b:
        walk(b.left);
        walk(b.right);
      case UnaryExpr u:
        walk(u.operand);
      case CompareExpr c:
        walk(c.left);
        for (final x in c.comparators) {
          walk(x);
        }
      case BoolExpr bo:
        for (final x in bo.operands) {
          walk(x);
        }
      case NotExpr n:
        walk(n.operand);
      default:
        break;
    }
  }

  walk(tree);
  return names;
}

/// Validate a formula; return required variable names in order.
List<String> validateFormula(String expression) {
  if (expression.trim().isEmpty) return const [];
  FormulaParser.parse(expression);
  return formulaVariables(expression);
}

/// Normalize a stored formula value to {expression, constants}.
Map<String, dynamic> normalizeFormulaValue(Object? formula) {
  if (formula == null) return const {};
  String expression;
  Object? constants;
  if (formula is Map) {
    expression = '${formula['expression'] ?? ''}'.trim();
    constants = formula['constants'];
  } else {
    expression = '$formula'.trim();
    constants = null;
  }
  final out = <String, dynamic>{};
  if (expression.isNotEmpty) out['expression'] = expression;
  final cleaned = <String, dynamic>{};
  if (constants is Map) {
    constants.forEach((key, value) {
      final symbol = '$key'.trim();
      if (symbol.isEmpty) return;
      if (value is Map) {
        final desc = Map<String, dynamic>.from(value);
        desc['symbol'] ??= symbol;
        final rawValue = desc['value'];
        if (rawValue != null) {
          final d = double.tryParse('$rawValue'.replaceAll(',', '.'));
          desc['value'] = d ?? '';
        }
        for (final f in ['unit', 'unit_dim', 'expression', 'description']) {
          final v = desc[f];
          if (v != null) desc[f] = '$v';
        }
        cleaned[symbol] = desc;
      } else {
        final d = safeFormulaFloat(value);
        if (d == null) return;
        cleaned[symbol] = d;
      }
    });
  }
  if (cleaned.isNotEmpty) out['constants'] = cleaned;
  return out;
}

/// is_out_of_range port from core/utils.py.
bool isOutOfRange(String? actualValue, num? minimum, num? maximum) {
  if (actualValue == null || actualValue.trim().isEmpty) return false;
  final numeric = double.tryParse(actualValue.trim());
  if (numeric == null) return false;
  if (minimum != null && numeric < minimum) return true;
  if (maximum != null && numeric > maximum) return true;
  return false;
}

/// parse_numeric_range port from core/utils.py.
Map<String, dynamic> parseNumericRange(Object? value) {
  final raw = referenceValueText(value);
  final direct =
      RegExp(r'^\s*(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*$').firstMatch(raw);
  if (direct != null) {
    final minText = direct.group(1)!;
    final maxText = direct.group(2)!;
    return {
      'raw': raw,
      'min_text': minText,
      'max_text': maxText,
      'min_value': double.parse(minText),
      'max_value': double.parse(maxText),
    };
  }
  final matches = RegExp(r'\d+(?:\.\d+)?').allMatches(raw).toList();
  if (matches.length >= 2) {
    return {
      'raw': raw,
      'min_text': matches[0].group(0)!,
      'max_text': matches[1].group(0)!,
      'min_value': double.parse(matches[0].group(0)!),
      'max_value': double.parse(matches[1].group(0)!),
    };
  }
  if (matches.length == 1) {
    return {
      'raw': raw,
      'min_text': matches[0].group(0)!,
      'max_text': '-',
      'min_value': double.parse(matches[0].group(0)!),
      'max_value': null,
    };
  }
  return {
    'raw': raw,
    'min_text': '-',
    'max_text': '-',
    'min_value': null,
    'max_value': null,
  };
}

/// format_value_with_unit port.
String formatValueWithUnit(String? value, String unit) {
  final text = (value ?? '').trim();
  if (text.isEmpty || text == '-') return '-';
  final lowered = text.toLowerCase();
  if (lowered.contains('ppm') ||
      lowered.contains('ppb') ||
      lowered.contains('%')) {
    return text;
  }
  return unit.isNotEmpty ? '$text $unit' : text;
}

/// infer_chemical_unit port from core/utils.py.
String inferChemicalUnit(Object? parameterData, [String? parameterName]) {
  final directUnit = referenceUnitText(parameterData);
  if (directUnit.isNotEmpty) return directUnit;
  var name = parameterName;
  if (name == null || name.trim().isEmpty) {
    name = referenceValueText(parameterData);
  }
  final normalized = name.trim().toLowerCase();
  const ppmTokens = [
    'afla', 'aflat', 'aflatoxin', 'okra', 'ochra', 'ochratoxin', 'افلا', 'اكرا',
  ];
  for (final token in ppmTokens) {
    if (normalized.contains(token)) return 'ppm';
  }
  return '%';
}

/// is_physical_out_of_range port from core/utils.py.
bool isPhysicalOutOfRange(String? actualValue, Object? requirement) {
  if (actualValue == null || actualValue.trim().isEmpty) return false;
  final valStr = actualValue.trim().toLowerCase();
  final reqStr = referenceValueText(requirement).toLowerCase();

  if (reqStr == 'negative') return valStr != 'negative';

  final rangeSep = reqStr.replaceAll(RegExp(r'\s*:\s*'), '-');
  final rangeMatch =
      RegExp(r'^\s*(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*$').firstMatch(rangeSep);
  if (rangeMatch != null) {
    final minLimit = double.tryParse(rangeMatch.group(1)!);
    final maxLimit = double.tryParse(rangeMatch.group(2)!);
    final current = double.tryParse(valStr);
    if (minLimit != null &&
        maxLimit != null &&
        current != null) {
      return current < minLimit || current > maxLimit;
    }
  }

  final isAbnormal = valStr.contains('abnormal') ||
      valStr.contains('غير طبيعي') ||
      valStr.contains('غير مطابق') ||
      RegExp(r'\bno\b').hasMatch(valStr) ||
      valStr.contains('not good') ||
      valStr.contains('not-good') ||
      valStr.contains('notgood') ||
      valStr.contains('pale') ||
      valStr.contains('سيء');
  if (isAbnormal) return true;

  final isNormal = valStr.contains('normal') ||
      valStr.contains('طبيعي') ||
      valStr.contains('مطابق') ||
      valStr.contains('ok') ||
      valStr.contains('good') ||
      valStr.contains('جيد') ||
      valStr.contains('positive') ||
      valStr.contains('acceptable');
  if (isNormal) return false;

  final maxMatch = RegExp(r'max\.?\s*(\d+(?:\.\d+)?)').firstMatch(reqStr);
  if (maxMatch != null) {
    final maxLimit = double.tryParse(maxMatch.group(1)!);
    final current = double.tryParse(valStr);
    if (maxLimit != null && current != null && current > maxLimit) return true;
  }

  final minMatch = RegExp(r'min\.?\s*(\d+(?:\.\d+)?)').firstMatch(reqStr);
  if (minMatch != null) {
    final minLimit = double.tryParse(minMatch.group(1)!);
    final current = double.tryParse(valStr);
    if (minLimit != null && current != null && current < minLimit) return true;
  }

  return false;
}