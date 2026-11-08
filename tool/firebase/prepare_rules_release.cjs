'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '../..');
process.chdir(root);
const check = spawnSync(process.execPath, ['tool/central_migration/generate_rules.js', '--check'], {cwd:root, encoding:'utf8'});
if (check.status !== 0) throw Error('Generated rules drift: ' + check.stderr);
const source = fs.readFileSync('firestore.rules', 'utf8');
const hash = value => crypto.createHash('sha256').update(value.replace(/\r\n/g, '\n')).digest('hex');
const expectedIndex = process.argv.indexOf('--expected-sha');
const expected = expectedIndex >= 0 ? process.argv[expectedIndex + 1] : hash(source);
if (hash(source) !== expected) throw Error('Reviewed rules changed');
function compact(input) {
  let out = '', quote = null, space = false;
  for (let i = 0; i < input.length; i++) {
    const ch = input[i], next = input[i + 1];
    if (quote) {
      out += ch;
      if (ch === '\\') { out += input[++i]; continue; }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '/' && next === '/') {
      i += 2; while (i < input.length && input[i] !== '\n') i++;
      space = true; continue;
    }
    if (ch === '/' && next === '*') {
      i += 2; while (i < input.length && !(input[i] === '*' && input[i + 1] === '/')) i++;
      if (i >= input.length) throw Error('Unterminated comment');
      i++; space = true; continue;
    }
    if (/\s/.test(ch)) { space = true; continue; }
    if (space && out.length) out += ' ';
    space = false; out += ch;
    if (ch === "'" || ch === '"') quote = ch;
  }
  if (quote) throw Error('Unterminated string');
  return out.trim();
}
function tokens(input) {
  const re = /\s+|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|\{[A-Za-z_$][A-Za-z0-9_$]*=\*\*\}|[A-Za-z_$][A-Za-z0-9_$]*|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|==|!=|<=|>=|&&|\|\||\*\*|[^\s]/g;
  return [...input.matchAll(re)].map(m => m[0]).filter(t => !/^\s+$/.test(t));
}
let sourceTokens = tokens(compact(source));
const removedFunctions = [];
// A function with no identifier occurrence except its declaration is unreachable:
// rules have no dynamic function dispatch. Remove only such complete bodies.
for (;;) {
  const counts = new Map();
  for (const token of sourceTokens) counts.set(token, (counts.get(token) || 0) + 1);
  let removed = false;
  for (let i = 0; i < sourceTokens.length; i++) {
    if (sourceTokens[i] !== 'function' || counts.get(sourceTokens[i + 1]) !== 1) continue;
    const name = sourceTokens[i + 1];
    let open = i + 2;
    while (open < sourceTokens.length && sourceTokens[open] !== '{') open++;
    let depth = 1, end = open + 1;
    while (end < sourceTokens.length && depth) {
      if (sourceTokens[end] === '{') depth++;
      if (sourceTokens[end] === '}') depth--;
      end++;
    }
    if (depth || open === sourceTokens.length) throw Error('Unbalanced function');
    sourceTokens.splice(i, end - i);
    removedFunctions.push(name);
    removed = true; break;
  }
  if (!removed) break;
}
// Alpha-rename only declared functions. Every occurrence must be a declaration
// or an unqualified call; no field names, literals, variables or builtins change.
const aliases = new Map();
const identifiers = new Set(sourceTokens);
for (let i = 0; i < sourceTokens.length; i++) {
  if (sourceTokens[i] !== 'function' || sourceTokens[i + 1].length < 4) continue;
  const name = sourceTokens[i + 1];
  if (aliases.has(name)) continue;
  const alias = `z${aliases.size.toString(36)}`;
  if (identifiers.has(alias)) throw Error('Alias collision');
  aliases.set(name, alias);
}
for (let i = 0; i < sourceTokens.length; i++) {
  if (aliases.has(sourceTokens[i]) && !(sourceTokens[i - 1] === 'function'
    || sourceTokens[i + 1] === '(' && sourceTokens[i - 1] !== '.')) {
    throw Error('Function name used as data or variable');
  }
}
const outputTokens = sourceTokens.map(t => aliases.get(t) || t);
let result = '';
for (let i = 0; i < outputTokens.length; i++) {
  const token = outputTokens[i], prev = outputTokens[i - 1];
  if (prev) {
    const joined = tokens(prev + token);
    if (joined.length !== 2 || joined[0] !== prev || joined[1] !== token
      || token === '/' && /^\d/.test(sourceTokens[i + 1] || '')
      || prev === '/' && /^\d/.test(token)
      || /[\/+\-*<>=!&|]$/.test(prev) && /^[\/+\-*<>=!&|]/.test(token)) result += ' ';
  }
  result += token;
}
const inverse = new Map([...aliases].map(([a,b])=>[b,a]));
if (JSON.stringify(tokens(result).map(t=>inverse.get(t)||t)) !== JSON.stringify(sourceTokens)) throw Error('Rules token sequence changed');
if (compact(result) !== result) throw Error('Compaction is not idempotent');
// Preserve every quoted literal verbatim: regexes, paths, field names and
// role/permission strings retain their exact contents and escape sequences.
const literals = text => [...text.matchAll(/'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"/gs)].map(m => m[0]);
// Comment text may contain quotes, so compare against the comment-free source
// emitted by the lexical pass rather than interpreting comments as code.
const lexical = sourceTokens.join(' ');
if (JSON.stringify(literals(lexical)) !== JSON.stringify(literals(result))) throw Error('Literal mismatch');
fs.writeFileSync('build/firestore.release.rules', result + '\n');
fs.writeFileSync('build/firebase.release.json', JSON.stringify({firestore: {rules: 'firestore.release.rules'}, emulators: JSON.parse(fs.readFileSync('firebase.json','utf8')).emulators}, null, 2));
const evidence = {sourceHash: expected, compactHash: hash(result + '\n'), originalBytes: Buffer.byteLength(source), compactBytes: Buffer.byteLength(result + '\n'), tokenSequenceIdentical: false, alphaEquivalentTokenSequence:true, unreferencedFunctionsRemoved:removedFunctions, functionAliases:Object.fromEntries(aliases)};
fs.writeFileSync('build/firestore.release.evidence.json', JSON.stringify(evidence, null, 2));
console.log(JSON.stringify({...evidence, functionAliases: undefined, noDeployment: true}));
