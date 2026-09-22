/// Minimal Jinja2-style template engine for `assets/templates/report_template.html`.
///
/// Covers exactly the constructs the report template uses (autoescape ON, as in
/// the reference `jinja2.Environment(autoescape=True)`), so stored `report_html`
/// stays byte-compatible with the Python renderer:
///
/// - `{{ var }}`, `{{ var or "fallback" }}`
/// - attribute chains `{{ item.req }}` and indexing `{{ item.is_outs[loop.index0] }}`
/// - filters `|length` and tests `is odd` / `is even`
/// - comparators (`>`, `>=`, `<`, `<=`, `==`, `!=`) and `not`
/// - `{% if %}` / `{% else %}` / `{% endif %}`
/// - `{% for x in items %}` / `{% endfor %}` with `loop.index/.index0/.first/.last`
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

class _IfNode implements _Node {
  _IfNode(this.condition, this.thenBody, this.elseBody);
  final String condition;
  final List<_Node> thenBody;
  final List<_Node> elseBody;
  @override
  String render(_Scope scope) {
    final body =
        _truthy(_evalTinyExpr(condition, scope)) ? thenBody : elseBody;
    return _renderNodes(body, scope);
  }
}

class _ForNode implements _Node {
  _ForNode(this.itemVar, this.iterable, this.body);
  final String itemVar;
  final String iterable;
  final List<_Node> body;
  @override
  String render(_Scope scope) {
    final source = _evalTinyExpr(iterable, scope);
    if (source is! List) return '';
    final out = StringBuffer();
    final n = source.length;
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
      if (stmt.startsWith('if ')) {
        final node = _IfNode(stmt.substring(3).trim(), [], []);
        stack.last.add(node);
        stack.add(node.thenBody);
      } else if (stmt.startsWith('for ')) {
        final forBody = stmt.substring(4).trim();
        final k = forBody.indexOf(' in ');
        if (k < 0) {
          throw StateError('Invalid for statement: `$stmt`');
        }
        final node = _ForNode(forBody.substring(0, k).trim(),
            forBody.substring(k + 4).trim(), []);
        stack.last.add(node);
        stack.add(node.body);
      } else if (stmt == 'else') {
        stack.removeLast();
        final parentList = stack.last;
        final owner = parentList.last;
        if (owner is _IfNode) {
          // The popped list was owner.thenBody (built live via the stack);
          // switch the active body to the else branch.
          stack.add(owner.elseBody);
        } else {
          throw StateError('{% else %} outside {% if %}');
        }
      } else if (stmt == 'endif' || stmt == 'endfor') {
        stack.removeLast();
      } else {
        throw StateError('Unsupported template tag: `$stmt`');
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

/// Evaluate a single expression against the scope.
Object? _evalTinyExpr(String expression, _Scope scope) =>
    _ExprParser(_tokenizeExpr(expression)).parse().eval(scope);

// ── Expression tokens ────────────────────────────────────────────────────

enum _TokKind { number, string, ident, dot, lbrack, rbrack, lparen, rparen, pipe, cmp, eof }

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
      case '|':
        toks.add(_Tok(_TokKind.pipe, '|'));
        i++;
        break;
      case '>':
      case '<':
      case '=':
      case '!':
        if (c == '=' ) {
          if (i + 1 < src.length && src[i + 1] == '=') {
            toks.add(_Tok(_TokKind.cmp, '=='));
            i += 2;
          } else {
            throw StateError('Unexpected `=` in expression: `$src`');
          }
        } else {
          if (i + 1 < src.length && src[i + 1] == '=') {
            toks.add(_Tok(_TokKind.cmp, '$c='));
            i += 2;
          } else {
            toks.add(_Tok(_TokKind.cmp, c));
            i++;
          }
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
      cur = _resolveStep(cur, step, scope);
    }
    return cur;
  }
}

Object? _resolveStep(Object? cur, _Expr step, _Scope scope) {
  final key = step.eval(scope);
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
    if (name == 'length') {
      if (v is List) return v.length;
      if (v is Map) return v.length;
      if (v is String) return v.length;
      return 0;
    }
    if (name == 'default') {
      return _truthy(v) ? v : '';
    }
    throw StateError('Unsupported filter `$name`');
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
    final e = _parseOr();
    if (_cur.kind != _TokKind.eof) {
      throw StateError('Trailing tokens in expression');
    }
    return e;
  }

  _Expr _parseOr() {
    final parts = <_Expr>[_parseCmp()];
    while (_takeIdent('or')) {
      parts.add(_parseCmp());
    }
    return parts.length == 1 ? parts.first : _OrExpr(parts);
  }

  _Expr _parseCmp() {
    final left = _parseNot();
    if (_cur.kind == _TokKind.cmp) {
      final op = _take().text;
      final right = _parseNot();
      return _CmpExpr(left, op, right);
    }
    return left;
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
        steps.add(_Literal(_take().text));
      } else if (_cur.kind == _TokKind.lbrack) {
        _take();
        steps.add(_parseOr());
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
        if (tok.text == 'True') return const _Literal(true);
        if (tok.text == 'False') return const _Literal(false);
        if (tok.text == 'None') return const _Literal(null);
        return _NameExpr(tok.text);
      case _TokKind.lparen:
        _take();
        final e = _parseOr();
        _expect(_TokKind.rparen);
        return e;
      default:
        throw StateError('Unexpected token in expression: ${tok.text}');
    }
  }
}