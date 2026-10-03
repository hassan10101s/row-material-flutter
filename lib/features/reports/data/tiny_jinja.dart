/// Minimal Jinja2-style template engine for the HTML report templates under
/// `assets/templates/`.
///
/// Covers exactly the constructs the shipped templates use (autoescape ON, as
/// in the reference `jinja2.Environment(autoescape=True)`), so stored
/// `report_html` stays byte-compatible with the Python renderer:
///
/// - `{{ var }}`, `{{ var or "fallback" }}`
/// - attribute chains `{{ item.req }}` and indexing `{{ item.is_outs[loop.index0] }}`
/// - filters `|length`, `|trim`, `|lower` and tests `is odd` / `is even`
/// - comparators (`>`, `>=`, `<`, `<=`, `==`, `!=`), `not`, `and`, `or`
/// - arithmetic `+` (used e.g. `page_start + i`)
/// - inline ternary `'high' if x >= 90 else ('medium' if ... else 'low')`
/// - `{% set name = expr %}` and namespace member assignment
///   `{% set ns.flag = true %}` with `{% set ns = namespace(a=false, ...) %}`
/// - `{% if %}` / `{% elif %}` / `{% else %}` / `{% endif %}`
/// - `{% for x in items %}` / `{% else %}` / `{% endfor %}` with
///   `loop.index/.index0/.first/.last`, `range(...)` iterables
/// - bare calls `range(...)`, `namespace(...)` and method `.lower()`
///
/// Text surrounding tags is preserved verbatim (no trim/lstrip blocks), matching
/// the reference environment's default whitespace handling.
library;

String tinyJinjaRender(String template, Map<String, dynamic> context) {
  final nodes = _parse(template);
  final scope = _Scope()..vars.addAll(context);
  return _renderNodes(nodes, scope);
}

// ── Helpers ──────────────────────────────────────────────────────────────

bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

String _str(Object? v) {
  if (v == null) return '';
  if (v is bool) return v ? 'True' : 'False';
  if (v is double) {
    return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  }
  return '$v';
}

String _htmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

// ── Scope / loop state ───────────────────────────────────────────────────

class _Scope {
  final Map<String, dynamic> vars = {};
  _Loop? loop;
  _Scope? parent;

  dynamic lookup(String name) {
    if (name == 'loop' && loop != null) return loop;
    if (vars.containsKey(name)) return vars[name];
    return parent?.lookup(name);
  }
}

class _Loop {
  final int index;
  final int index0;
  final int count;
  final bool last;
  final bool first;
  _Loop(this.index, this.index0, this.count)
      : last = index0 == count - 1,
        first = index0 == 0;
}

/// Mutable object backing `namespace(...)` + `{% set ns.attr = value %}`.
class _Namespace {
  final Map<String, dynamic> values = {};
}

// ── AST nodes ────────────────────────────────────────────────────────────

abstract class _Node {
  String render(_Scope scope);
}

class _TextNode implements _Node {
  _TextNode(this.value);
  final String value;
  @override
  String render(_Scope scope) => value;
}

class _OutputNode implements _Node {
  _OutputNode(this.expression);
  final String expression;
  @override
  String render(_Scope scope) => _htmlEscape(_str(_evalTinyExpr(expression, scope)));
}

class _IfBranch {
  _IfBranch(this.condition, this.body);
  final String condition;
  final List<_Node> body;
}

class _IfNode implements _Node {
  _IfNode(this.branches, this.elseBody);
  final List<_IfBranch> branches;
  final List<_Node> elseBody;
  @override
  String render(_Scope scope) {
    for (final branch in branches) {
      if (_truthy(_evalTinyExpr(branch.condition, scope))) {
        return _renderNodes(branch.body, scope);
      }
    }
    return _renderNodes(elseBody, scope);
  }
}

class _SetNode implements _Node {
  _SetNode(this.root, this.attrs, this.value);
  final String root;
  final List<String> attrs;
  final _Expr value;
  @override
  String render(_Scope scope) {
    final result = value.eval(scope);
    if (attrs.isEmpty) {
      scope.vars[root] = result;
    } else {
      var cur = scope.lookup(root);
      for (var i = 0; i < attrs.length - 1; i++) {
        cur = _resolveKey(cur, _Literal(attrs[i]), scope);
      }
      _assignAttr(cur, attrs.last, result);
    }
    return '';
  }
}

void _assignAttr(Object? target, String key, Object? value) {
  if (target is _Namespace) {
    target.values[key] = value;
    return;
  }
  if (target is Map) {
    // Above the templates' usage; kept for namespace-like maps.
    (target as Map<String, dynamic>)[key] = value;
    return;
  }
  throw StateError('Cannot assign attribute `$key` on $_runtimeTypeName(target)');
}

String _runtimeTypeName(Object? v) => v == null ? 'None' : '${v.runtimeType}';

class _ForNode implements _Node {
  _ForNode(this.itemVar, this.iterable, this.body, this.elseBody);
  final String itemVar;
  final String iterable;
  final List<_Node> body;
  final List<_Node> elseBody;
  @override
  String render(_Scope scope) {
    final source = _evalTinyExpr(iterable, scope);
    if (source is! List) return _renderNodes(elseBody, scope);
    final out = StringBuffer();
    final n = source.length;
    if (n == 0) return _renderNodes(elseBody, scope);
    for (var i = 0; i < n; i++) {
      final child = _Scope()
        ..parent = scope
        ..vars[itemVar] = source[i]
        ..loop = _Loop(i + 1, i, n);
      out.write(_renderNodes(body, child));
    }
    return out.toString();
  }
}

String _renderNodes(List<_Node> nodes, _Scope scope) {
  final out = StringBuffer();
  for (final n in nodes) {
    out.write(n.render(scope));
  }
  return out.toString();
}

// ── Template parser → AST ────────────────────────────────────────────────

final RegExp _tagRe = RegExp(
  r'\{\{\s*([\s\S]*?)\s*\}\}|\{%\s*([\s\S]*?)\s*%\}',
);

final RegExp _ifRe = RegExp(r'^if\s+([\s\S]+)$');
final RegExp _forRe = RegExp(r'^for\s+([\s\S]+?)\s+in\s+([\s\S]+)$');

List<_Node> _parse(String template) {
  final root = <_Node>[];
  final stack = <List<_Node>>[root];
  var cursor = 0;
  for (final m in _tagRe.allMatches(template)) {
    if (m.start > cursor) {
      stack.last.add(_TextNode(template.substring(cursor, m.start)));
    }
    final output = m.group(1);
    final statement = m.group(2);
    if (output != null) {
      stack.last.add(_OutputNode(output.trim()));
    } else {
      final stmt = statement!.trim();
      final ifMatch = _ifRe.firstMatch(stmt);
      if (ifMatch != null) {
        final node = _IfNode([_IfBranch(ifMatch.group(1)!.trim(), [])], []);
        stack.last.add(node);
        stack.add(node.branches.last.body);
      } else if (stmt.startsWith('elif ')) {
        if (stack.length < 2) {
          throw StateError('{% elif %} outside {% if %}');
        }
        stack.removeLast();
        final ownerList = stack.last;
        final owner = ownerList.last;
        if (owner is! _IfNode) {
          throw StateError('{% elif %} outside {% if %}');
        }
        final branch = _IfBranch(stmt.substring(5).trim(), []);
        owner.branches.add(branch);
        stack.add(branch.body);
      } else if (stmt.startsWith('set ')) {
        stack.last.add(_parseSet(stmt.substring(4).trim()));
      } else if (stmt == 'else') {
        if (stack.length < 2) {
          throw StateError('{% else %} outside {% if %}/{% for %}');
        }
        stack.removeLast();
        final ownerList = stack.last;
        final owner = ownerList.last;
        if (owner is _IfNode) {
          stack.add(owner.elseBody);
        } else if (owner is _ForNode) {
          stack.add(owner.elseBody);
        } else {
          throw StateError('{% else %} outside {% if %}/{% for %}');
        }
      } else if (stmt == 'endif' || stmt == 'endfor') {
        stack.removeLast();
      } else {
        final forMatch = _forRe.firstMatch(stmt);
        if (forMatch == null) {
          throw StateError('Unsupported template tag: `$stmt`');
        }
        final node = _ForNode(
          forMatch.group(1)!.trim(),
          forMatch.group(2)!.trim(),
          [],
          [],
        );
        stack.last.add(node);
        stack.add(node.body);
      }
    }
    cursor = m.end;
  }
  if (cursor < template.length) {
    root.add(_TextNode(template.substring(cursor)));
  }
  if (stack.length != 1) {
    throw StateError('Unclosed template tag in report template.');
  }
  return root;
}

/// `{% set target = expr %}` and `{% set ns.attr = expr %}`.
_SetNode _parseSet(String body) {
  final toks = _tokenizeExpr(body);
  if (toks.length < 3 || toks[0].kind != _TokKind.ident) {
    throw StateError('Invalid set statement: `set $body`');
  }
  final root = toks[0].text;
  final attrs = <String>[];
  var i = 1;
  while (i < toks.length && toks[i].kind == _TokKind.dot) {
    i++;
    if (i >= toks.length || toks[i].kind != _TokKind.ident) {
      throw StateError('Invalid set statement: `set $body`');
    }
    attrs.add(toks[i].text);
    i++;
  }
  if (i >= toks.length || toks[i].kind != _TokKind.assign) {
    throw StateError('Expected `=` in set statement: `set $body`');
  }
  i++;
  final value = _ExprParser(toks.sublist(i)).parse();
  return _SetNode(root, attrs, value);
}

/// Evaluate a single expression against the scope.
Object? _evalTinyExpr(String expression, _Scope scope) {
  final parser = _ExprParser(_tokenizeExpr(expression));
  final result = parser.parse().eval(scope);
  if (parser._cur.kind != _TokKind.eof) {
    throw StateError('Trailing tokens in expression: `$expression`');
  }
  return result;
}

// ── Expression tokens ────────────────────────────────────────────────────

enum _TokKind {
  number,
  string,
  ident,
  dot,
  lbrack,
  rbrack,
  lparen,
  rparen,
  comma,
  assign,
  plus,
  pipe,
  cmp,
  eof,
}

class _Tok {
  _Tok(this.kind, this.text);
  final _TokKind kind;
  final String text;
}

List<_Tok> _tokenizeExpr(String src) {
  final toks = <_Tok>[];
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
      continue;
    }
    if (_isDigit(c)) {
      var j = i;
      while (j < src.length && _isDigit(src[j])) {
        j++;
      }
      if (j < src.length && src[j] == '.' && j + 1 < src.length && _isDigit(src[j + 1])) {
        j++;
        while (j < src.length && _isDigit(src[j])) {
          j++;
        }
      }
      toks.add(_Tok(_TokKind.number, src.substring(i, j)));
      i = j;
      continue;
    }
    if (c == '"' || c == "'") {
      var j = i + 1;
      final quote = c;
      final buf = StringBuffer();
      while (j < src.length) {
        final ch = src[j];
        if (ch == '\\' && j + 1 < src.length) {
          buf.write(src[j + 1]);
          j += 2;
          continue;
        }
        if (ch == quote) {
          j++;
          break;
        }
        buf.write(ch);
        j++;
      }
      toks.add(_Tok(_TokKind.string, buf.toString()));
      i = j;
      continue;
    }
    if (_isIdentChar(c)) {
      var j = i;
      while (j < src.length && _isIdentChar(src[j])) {
        j++;
      }
      toks.add(_Tok(_TokKind.ident, src.substring(i, j)));
      i = j;
      continue;
    }
    switch (c) {
      case '.':
        toks.add(_Tok(_TokKind.dot, '.'));
        i++;
        break;
      case '[':
        toks.add(_Tok(_TokKind.lbrack, '['));
        i++;
        break;
      case ']':
        toks.add(_Tok(_TokKind.rbrack, ']'));
        i++;
        break;
      case '(':
        toks.add(_Tok(_TokKind.lparen, '('));
        i++;
        break;
      case ')':
        toks.add(_Tok(_TokKind.rparen, ')'));
        i++;
        break;
      case ',':
        toks.add(_Tok(_TokKind.comma, ','));
        i++;
        break;
      case '+':
        toks.add(_Tok(_TokKind.plus, '+'));
        i++;
        break;
      case '|':
        toks.add(_Tok(_TokKind.pipe, '|'));
        i++;
        break;
      case '>':
      case '<':
        if (i + 1 < src.length && src[i + 1] == '=') {
          toks.add(_Tok(_TokKind.cmp, '$c='));
          i += 2;
        } else {
          toks.add(_Tok(_TokKind.cmp, c));
          i++;
        }
        break;
      case '=':
        if (i + 1 < src.length && src[i + 1] == '=') {
          toks.add(_Tok(_TokKind.cmp, '=='));
          i += 2;
        } else {
          toks.add(_Tok(_TokKind.assign, '='));
          i++;
        }
        break;
      case '!':
        if (i + 1 < src.length && src[i + 1] == '=') {
          toks.add(_Tok(_TokKind.cmp, '!='));
          i += 2;
        } else {
          throw StateError('Unexpected `!` in expression: `$src`');
        }
        break;
      default:
        throw StateError('Unexpected character `$c` in expression: `$src`');
    }
  }
  toks.add(_Tok(_TokKind.eof, ''));
  return toks;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
bool _isIdentChar(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 48 && u <= 57) ||
      (u >= 65 && u <= 90) ||
      (u >= 97 && u <= 122) ||
      u == 95;
}

// ── Expression AST ───────────────────────────────────────────────────────

abstract class _Expr {
  Object? eval(_Scope scope);
}

class _Literal implements _Expr {
  const _Literal(this.value);
  final Object? value;
  @override
  Object? eval(_Scope scope) => value;
}

class _NameExpr implements _Expr {
  _NameExpr(this.root);
  final String root;
  @override
  Object? eval(_Scope scope) => scope.lookup(root);
}

class _PathExpr implements _Expr {
  _PathExpr(this.head, this.steps);
  final _Expr head;
  final List<_Expr> steps; // _Literal(String) for attrs, _Expr for [index]
  @override
  Object? eval(_Scope scope) {
    var cur = head.eval(scope);
    for (final step in steps) {
      cur = _resolveKey(cur, step, scope);
    }
    return cur;
  }
}

Object? _resolveKey(Object? cur, _Expr step, _Scope scope) {
  final key = step.eval(scope);
  if (cur is _Namespace && key is String) return cur.values[key];
  if (cur is _Loop && key is String) {
    switch (key) {
      case 'index':
        return cur.index;
      case 'index0':
        return cur.index0;
      case 'count':
        return cur.count;
      case 'last':
        return cur.last;
      case 'first':
        return cur.first;
      default:
        return null;
    }
  }
  if (cur is Map) return cur[key];
  if (cur is List && key is int) {
    if (key < 0 || key >= cur.length) return null;
    return cur[key];
  }
  return null;
}

class _NotExpr implements _Expr {
  _NotExpr(this.inner);
  final _Expr inner;
  @override
  Object? eval(_Scope scope) => !_truthy(inner.eval(scope));
}

class _OrExpr implements _Expr {
  _OrExpr(this.parts);
  final List<_Expr> parts;
  @override
  Object? eval(_Scope scope) {
    for (final p in parts) {
      final v = p.eval(scope);
      if (_truthy(v)) return v;
    }
    return parts.isNotEmpty ? parts.last.eval(scope) : null;
  }
}

class _AndExpr implements _Expr {
  _AndExpr(this.left, this.right);
  final _Expr left;
  final _Expr right;
  @override
  Object? eval(_Scope scope) {
    final l = left.eval(scope);
    if (!_truthy(l)) return l;
    return right.eval(scope);
  }
}

class _TernaryExpr implements _Expr {
  _TernaryExpr(this.condition, this.whenTrue, this.whenFalse);
  final _Expr condition;
  final _Expr whenTrue;
  final _Expr whenFalse;
  @override
  Object? eval(_Scope scope) =>
      _truthy(condition.eval(scope)) ? whenTrue.eval(scope) : whenFalse.eval(scope);
}

class _AddExpr implements _Expr {
  _AddExpr(this.left, this.right);
  final _Expr left;
  final _Expr right;
  @override
  Object? eval(_Scope scope) {
    final a = left.eval(scope);
    final b = right.eval(scope);
    if (a is num && b is num) return a + b;
    if (a is String || b is String) return '${_str(a)}${_str(b)}';
    throw StateError('Cannot add ${_runtimeTypeName(a)} + ${_runtimeTypeName(b)}');
  }
}

class _CmpExpr implements _Expr {
  _CmpExpr(this.left, this.op, this.right);
  final _Expr left;
  final String op;
  final _Expr right;
  @override
  Object? eval(_Scope scope) {
    final a = left.eval(scope);
    final b = right.eval(scope);
    final na = a is num ? a : double.tryParse('$a');
    final nb = b is num ? b : double.tryParse('$b');
    if (na == null || nb == null) {
      final sa = _str(a);
      final sb = _str(b);
      switch (op) {
        case '==':
          return sa == sb;
        case '!=':
          return sa != sb;
        default:
          return false;
      }
    }
    switch (op) {
      case '>':
        return na > nb;
      case '>=':
        return na >= nb;
      case '<':
        return na < nb;
      case '<=':
        return na <= nb;
      case '==':
        return na == nb;
      case '!=':
        return na != nb;
      default:
        return false;
    }
  }
}

class _FilterExpr implements _Expr {
  _FilterExpr(this.inner, this.name);
  final _Expr inner;
  final String name;
  @override
  Object? eval(_Scope scope) {
    final v = inner.eval(scope);
    switch (name) {
      case 'length':
        if (v is List) return v.length;
        if (v is Map) return v.length;
        if (v is String) return v.length;
        return 0;
      case 'default':
        return _truthy(v) ? v : '';
      case 'trim':
        if (v is String) return v.trim();
        return _str(v).trim();
      case 'lower':
        return _str(v).toLowerCase();
      default:
        throw StateError('Unsupported filter `$name`');
    }
  }
}

class _IsTestExpr implements _Expr {
  _IsTestExpr(this.inner, this.test, this.negated);
  final _Expr inner;
  final String test;
  final bool negated;
  @override
  Object? eval(_Scope scope) {
    var result = false;
    final v = inner.eval(scope);
    if (v is num) {
      final par = v.toInt().abs() % 2;
      if (test == 'odd') result = par == 1;
      if (test == 'even') result = par == 0;
    }
    return negated ? !result : result;
  }
}

class _BuiltinCallExpr implements _Expr {
  _BuiltinCallExpr(this.name, this.args, this.kwargs);
  final String name;
  final List<_Expr> args;
  final Map<String, _Expr> kwargs;
  @override
  Object? eval(_Scope scope) {
    if (name == 'range') {
      final nums = <int>[
        for (final a in args)
          (() {
            final v = a.eval(scope);
            if (v is num) return v.toInt();
            return int.tryParse('$v') ?? 0;
          })()
      ];
      if (nums.length == 1) return List<int>.generate(nums[0], (i) => i);
      if (nums.length == 2) return [for (var i = nums[0]; i < nums[1]; i++) i];
      if (nums.length >= 3) {
        final step = nums[2] == 0 ? 1 : nums[2];
        final out = <int>[];
        if (step > 0) {
          for (var i = nums[0]; i < nums[1]; i += step) {
            out.add(i);
          }
        } else {
          for (var i = nums[0]; i > nums[1]; i += step) {
            out.add(i);
          }
        }
        return out;
      }
      return <int>[];
    }
    if (name == 'namespace') {
      final ns = _Namespace();
      kwargs.forEach((k, e) => ns.values[k] = e.eval(scope));
      return ns;
    }
    throw StateError('Unsupported function `$name`');
  }
}

class _MethodCallExpr implements _Expr {
  _MethodCallExpr(this.receiver, this.method, this.args);
  final _Expr receiver;
  final String method;
  final List<_Expr> args;
  @override
  Object? eval(_Scope scope) {
    final v = receiver.eval(scope);
    if (method == 'lower') {
      if (args.isNotEmpty) {
        throw StateError('lower() takes no arguments');
      }
      return _str(v).toLowerCase();
    }
    throw StateError('Unsupported method `$method`()');
  }
}

// ── Recursive-descent expression parser ──────────────────────────────────

class _ExprParser {
  _ExprParser(this.toks);
  final List<_Tok> toks;
  int _i = 0;

  _Tok get _cur => toks[_i < toks.length ? _i : toks.length - 1];
  bool _peekIdent(String name) =>
      _cur.kind == _TokKind.ident && _cur.text == name;

  _Tok _take() {
    final t = _cur;
    if (_i < toks.length - 1) _i++;
    return t;
  }

  bool _takeIdent(String name) {
    if (_peekIdent(name)) {
      _take();
      return true;
    }
    return false;
  }

  void _expect(_TokKind kind) {
    if (_cur.kind != kind) {
      throw StateError('Expected $kind but got ${_cur.kind}:${_cur.text}');
    }
    _take();
  }

  _Expr parse() {
    final e = _parseIfExpr();
    if (_cur.kind != _TokKind.eof) {
      throw StateError('Trailing tokens in expression');
    }
    return e;
  }

  _Expr _parseIfExpr() {
    final whenTrue = _parseOr();
    if (_takeIdent('if')) {
      final condition = _parseOr();
      if (!_takeIdent('else')) {
        throw StateError('Expected `else` in ternary expression');
      }
      return _TernaryExpr(condition, whenTrue, _parseIfExpr());
    }
    return whenTrue;
  }

  _Expr _parseOr() {
    final parts = <_Expr>[_parseAnd()];
    while (_takeIdent('or')) {
      parts.add(_parseAnd());
    }
    return parts.length == 1 ? parts.first : _OrExpr(parts);
  }

  _Expr _parseAnd() {
    var expr = _parseCmp();
    while (_takeIdent('and')) {
      expr = _AndExpr(expr, _parseCmp());
    }
    return expr;
  }

  _Expr _parseCmp() {
    final left = _parseAdd();
    if (_cur.kind == _TokKind.cmp) {
      final op = _take().text;
      final right = _parseAdd();
      return _CmpExpr(left, op, right);
    }
    return left;
  }

  _Expr _parseAdd() {
    var expr = _parseNot();
    while (_cur.kind == _TokKind.plus) {
      _take();
      expr = _AddExpr(expr, _parseNot());
    }
    return expr;
  }

  _Expr _parseNot() {
    if (_takeIdent('not')) {
      return _NotExpr(_parseNot());
    }
    return _parseTest();
  }

  _Expr _parseTest() {
    var expr = _parsePostfix();
    if (_takeIdent('is')) {
      var negated = _takeIdent('not');
      final test = _take().text;
      expr = _IsTestExpr(expr, test, negated);
    }
    return expr;
  }

  _Expr _parsePostfix() {
    var expr = _parseAtom();
    var steps = <_Expr>[];
    while (true) {
      if (_cur.kind == _TokKind.dot) {
        _take();
        final name = _take().text;
        if (_cur.kind == _TokKind.lparen) {
          final base = steps.isEmpty ? expr : _PathExpr(expr, steps);
          steps = <_Expr>[];
          final (args, _) = _parseArgs();
          expr = _MethodCallExpr(base, name, args);
          continue;
        }
        steps.add(_Literal(name));
      } else if (_cur.kind == _TokKind.lbrack) {
        _take();
        steps.add(_parseIfExpr());
        _expect(_TokKind.rbrack);
      } else {
        break;
      }
    }
    if (steps.isNotEmpty) {
      expr = _PathExpr(expr, steps);
    }
    if (_cur.kind == _TokKind.pipe) {
      _take();
      final name = _take().text;
      return _FilterExpr(expr, name);
    }
    return expr;
  }

  (List<_Expr>, Map<String, _Expr>) _parseArgs() {
    _expect(_TokKind.lparen);
    final positional = <_Expr>[];
    final kwargs = <String, _Expr>{};
    if (_cur.kind == _TokKind.rparen) {
      _take();
      return (positional, kwargs);
    }
    while (true) {
      if (_cur.kind == _TokKind.ident &&
          _i + 1 < toks.length &&
          toks[_i + 1].kind == _TokKind.assign) {
        final name = _take().text;
        _take(); // '='
        kwargs[name] = _parseIfExpr();
      } else {
        positional.add(_parseIfExpr());
      }
      if (_cur.kind == _TokKind.comma) {
        _take();
        continue;
      }
      break;
    }
    _expect(_TokKind.rparen);
    return (positional, kwargs);
  }

  _Expr _parseAtom() {
    final tok = _cur;
    switch (tok.kind) {
      case _TokKind.number:
        _take();
        final isInt = !tok.text.contains('.');
        final n = isInt ? int.tryParse(tok.text) : double.tryParse(tok.text);
        return _Literal(n);
      case _TokKind.string:
        _take();
        return _Literal(tok.text);
      case _TokKind.ident:
        _take();
        if (tok.text == 'True' || tok.text == 'true') {
          return const _Literal(true);
        }
        if (tok.text == 'False' || tok.text == 'false') {
          return const _Literal(false);
        }
        if (tok.text == 'None' || tok.text == 'none' || tok.text == 'null') {
          return const _Literal(null);
        }
        if (_cur.kind == _TokKind.lparen) {
          final (args, kwargs) = _parseArgs();
          return _BuiltinCallExpr(tok.text, args, kwargs);
        }
        return _NameExpr(tok.text);
      case _TokKind.lparen:
        _take();
        final e = _parseIfExpr();
        _expect(_TokKind.rparen);
        return e;
      default:
        throw StateError('Unexpected token in expression: ${tok.text}');
    }
  }
}