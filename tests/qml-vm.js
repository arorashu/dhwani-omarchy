const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

// Shared test plumbing: run real QML JavaScript functions in a VM sandbox with
// mocked surroundings. This is not a live QML runtime; callers state the layer.
function qmlFunctions(file, names, context) {
  const source = fs.readFileSync(file, 'utf8');
  const sandbox = vm.createContext(context);
  for (const name of names) {
    const match = source.match(new RegExp(`  function ${name}\\([^]*?\\n  \\}`));
    assert.ok(match, `${file} must define ${name}`);
    sandbox[name] = vm.runInContext(`(${match[0].trim()})`, sandbox);
  }
  return sandbox;
}

// Return the one-line expression of `prop:` under the element with `id: id`.
function qmlBinding(file, id, prop) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const start = lines.findIndex((line) => line.trim() === `id: ${id}`);
  assert.ok(start >= 0, `${file} must define id: ${id}`);
  for (const line of lines.slice(start)) {
    const trimmed = line.trim();
    if (trimmed.startsWith(`${prop}:`)) {
      return trimmed.slice(prop.length + 1).split('//')[0].trim();
    }
  }
  throw new Error(`${file}: ${id} has no ${prop} binding`);
}

module.exports = { qmlFunctions, qmlBinding };
