// Surgical single-key YAML updater — a fast deterministic contract model for
// the fleet's configured `yaml-update` target.
//
// This is not Kargo code and cannot prove a Kargo promotion's serialization
// behavior. It rewrites only the selected scalar line so fleet tests can check
// the fixed pin.tag path while asserting that untouched raw blocks remain
// byte-identical. It deliberately does not promise preservation of an inline
// comment on the updated scalar itself.
//
// usage: bun fleet-yaml-update.ts <file> <dotted.key> <new-value>
//   edits <file> in place; exits non-zero when the key path cannot be found.

const [file, dottedKey, newValue] = process.argv.slice(2);
if (!file || !dottedKey || newValue === undefined) {
  console.error('usage: bun fleet-yaml-update.ts <file> <dotted.key> <new-value>');
  process.exit(2);
}

const segments = dottedKey.split('.');
const original = await Bun.file(file).text();
const lines = original.split('\n');

// Indentation-scoped descent: find each successive segment as a mapping key at
// the expected (2-space-per-level) depth, then rewrite the final scalar in
// place. The target scalar's complete value token is replaced; all non-target
// lines remain untouched.
let searchFrom = 0;
let searchTo = lines.length;
let targetLine = -1;

for (let depth = 0; depth < segments.length; depth += 1) {
  const key = segments[depth];
  const indent = '  '.repeat(depth);
  const keyRe = new RegExp(`^${indent}${key}:(\\s|$)`);
  let found = -1;
  for (let i = searchFrom; i < searchTo; i += 1) {
    if (keyRe.test(lines[i])) {
      found = i;
      break;
    }
  }
  if (found === -1) {
    console.error(`❌ key path '${dottedKey}' not found at segment '${key}'`);
    process.exit(1);
  }
  if (depth === segments.length - 1) {
    targetLine = found;
  } else {
    // Descend into this mapping: its block runs until the next line at the same
    // or shallower indentation.
    searchFrom = found + 1;
    let end = searchTo;
    for (let i = found + 1; i < searchTo; i += 1) {
      const line = lines[i];
      if (line.trim() === '' || line.trim().startsWith('#')) continue;
      const lead = line.length - line.trimStart().length;
      if (lead <= indent.length) {
        end = i;
        break;
      }
    }
    searchTo = end;
  }
}

const line = lines[targetLine];
const match = line.match(/^(\s*[^:]+:\s*)(.*)$/);
if (!match) {
  console.error(`❌ target line is not a scalar mapping: ${line}`);
  process.exit(1);
}
lines[targetLine] = `${match[1]}${newValue}`;

await Bun.write(file, lines.join('\n'));
