const assert = require('node:assert');
const fs = require('node:fs');
const vm = require('node:vm');

// Extract JavaScript and bindings from QML source and run them in a Node VM with
// a mocked context. This is not a QML runtime: it never loads a scene, resolves
// imports, or renders anything, so callers must state the layer they exercise.
function qmlFunctions(file, names, context) {
  const source = fs.readFileSync(file, 'utf8');
  const sandbox = vm.createContext(context);
  for (const name of names) {
    const matches = [...source.matchAll(new RegExp(`  function ${name}\\([^]*?\\n  \\}`, 'g'))];
    assert.strictEqual(matches.length, 1, `${file} must define ${name} exactly once`);
    sandbox[name] = vm.runInContext(`(${matches[0][0].trim()})`, sandbox);
  }
  return sandbox;
}

// Return a one-line binding from the object that owns `id`, never a sibling.
function qmlBinding(file, id, prop) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const start = lines.findIndex((line) => line.trim() === `id: ${id}`);
  assert.ok(start >= 0, `${file} must define id: ${id}`);
  const indent = lines[start].search(/\S/);
  const end = lines.findIndex(
    (line, index) => index > start && line.trim() && line.search(/\S/) < indent
  );
  const matches = lines.slice(start + 1, end < 0 ? lines.length : end).filter(
    (line) => line.search(/\S/) === indent && line.trim().startsWith(`${prop}:`)
  );
  assert.strictEqual(matches.length, 1, `${file}: ${id} must define ${prop} exactly once`);
  return matches[0].trim().slice(prop.length + 1).split('//')[0].trim();
}

module.exports = { qmlFunctions, qmlBinding };
