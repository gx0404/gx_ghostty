/** Rebuild the pinned offline dependency, or compare every output without writes. */
import {createHash} from 'node:crypto';
import {readFile, writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {dirname, join, resolve, relative} from 'node:path';
import {fileURLToPath} from 'node:url';

const buildRoot = dirname(fileURLToPath(import.meta.url));
const root = resolve(buildRoot, '../../../..');
const output = dirname(buildRoot);
const check = process.argv.includes('--check');
if (process.argv.slice(2).some(arg => arg !== '--check')) {
  throw new Error('Usage: node scripts/graphify_viewer_assets/vendor/build/build_vendor.mjs [--check]');
}
const require = createRequire(join(buildRoot, 'package.json'));
const esbuild = require('esbuild');
const hash = value => createHash('sha256').update(value).digest('hex');
const threeRoot = dirname(dirname(require.resolve('three')));
const three = JSON.parse(await readFile(join(threeRoot, 'package.json'), 'utf8'));
if (three.version !== '0.186.1' || esbuild.version !== '0.28.2') {
  throw new Error('Pinned dependencies differ. Run npm ci --prefix scripts/graphify_viewer_assets/vendor/build.');
}
const license = (await readFile(join(threeRoot, 'LICENSE'), 'utf8')).replace(/\r\n/g, '\n').trim() + '\n';
const result = await esbuild.build({
  entryPoints: [join(buildRoot, 'vendor-entry.mjs')],
  absWorkingDir: buildRoot,
  bundle: true,
  format: 'iife',
  globalName: 'AtlasVendor',
  platform: 'browser',
  target: ['es2020'],
  // Keep shader text intact while avoiding whitespace-bearing template lines.
  supported: {'template-literal': false},
  minify: true,
  charset: 'utf8',
  legalComments: 'inline',
  write: false,
  logLevel: 'silent',
  banner: {js: `/*! Three.js ${three.version}; MIT license\n${license.replaceAll('*/', '* /')}*/`},
});
const bundle = Buffer.from(result.outputFiles[0].contents);
if (/<\/script/i.test(bundle.toString('utf8'))) {
  throw new Error('The dependency bundle contains an unsafe HTML raw-text end marker.');
}
const inputs = {};
for (const name of ['package.json', 'package-lock.json', 'vendor-entry.mjs', 'build_vendor.mjs']) {
  const path = join(buildRoot, name);
  const normalized = (await readFile(path, 'utf8')).replace(/\r\n/g, '\n');
  inputs[relative(root, path).split('\\').join('/')] = hash(Buffer.from(normalized));
}
const manifest = JSON.stringify({
  schema: 1,
  library: {name: 'three', version: three.version, license: 'MIT', source: 'https://registry.npmjs.org/three/0.186.1'},
  builder: {name: 'esbuild', version: esbuild.version},
  inputs,
  outputs: {'three.bundle.js': hash(bundle), 'LICENSE.txt': hash(Buffer.from(license))},
}, null, 2) + '\n';
const generated = new Map([['three.bundle.js', bundle], ['LICENSE.txt', Buffer.from(license)], ['manifest.json', Buffer.from(manifest)]]);
for (const [name, content] of generated) {
  const path = join(output, name);
  if (check) {
    if (!(await readFile(path)).equals(content)) throw new Error(`${name} differs from the pinned build. Rebuild explicitly.`);
  } else {
    await writeFile(path, content);
  }
}
console.log(JSON.stringify({status: 'PASS', mode: check ? 'check' : 'build', bytes: bundle.length, sha256: hash(bundle)}));
