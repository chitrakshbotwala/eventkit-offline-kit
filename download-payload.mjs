#!/usr/bin/env node
/**
 * Downloads the kit's big files from this repo's GitHub Release into payload/, so the
 * folder can be copied to a USB drive. Needs Node 22+ and the GitHub CLI signed in to an
 * account that can see this (private) repo: `gh auth login`.
 *
 *   node download-payload.mjs                          # every platform (~13 GB)
 *   node download-payload.mjs --targets windows-x64,macos-arm64
 *
 * Files over GitHub's 2 GiB asset limit are stored as numbered parts and joined here.
 * Every file is checked against the SHA-256 in payload/assets.tsv; files already present
 * with the right hash are skipped, so the script can be re-run after an interruption.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rename, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const HERE = dirname(fileURLToPath(import.meta.url));
const PAYLOAD = join(HERE, 'payload');

const { values: opts } = parseArgs({ options: { targets: { type: 'string' } } });

const release = JSON.parse(await readFile(join(PAYLOAD, 'release.json'), 'utf8'));
const assets = (await readFile(join(PAYLOAD, 'assets.tsv'), 'utf8'))
  .split(/\r?\n/)
  .filter(Boolean)
  .map((line) => {
    const [path, sha256, parts] = line.split('\t');
    return { path, sha256, parts: parts.split(',') };
  });

/** Files the selected targets use (all files when no --targets). */
async function wantedPaths() {
  if (!opts.targets) return null;
  const set = new Set();
  for (const t of opts.targets.split(',').map((s) => s.trim())) {
    const tsv = await readFile(join(PAYLOAD, 'targets', `${t}.tsv`), 'utf8').catch(() => {
      throw new Error(`unknown target ${t}`);
    });
    for (const line of tsv.split(/\r?\n/)) {
      const [kind, file] = line.split('\t');
      if (kind && kind !== 'meta') set.add(file);
    }
  }
  return set;
}

async function sha256(path) {
  const h = createHash('sha256');
  await pipeline(createReadStream(path), h);
  return h.digest('hex');
}

function gh(args) {
  const r = spawnSync('gh', args, { stdio: 'inherit' });
  if (r.error) throw new Error(`could not run gh (${r.error.message}); install the GitHub CLI`);
  if (r.status !== 0) throw new Error(`gh ${args.join(' ')} failed`);
}

const wanted = await wantedPaths();
const todo = assets.filter((a) => !wanted || wanted.has(a.path));
const tmp = await mkdtemp(join(tmpdir(), 'eventkit-kit-'));
try {
  for (const [i, a] of todo.entries()) {
    const dest = join(PAYLOAD, a.path);
    const label = `[${i + 1}/${todo.length}] ${a.path}`;
    if (existsSync(dest) && (await sha256(dest)) === a.sha256) {
      console.log(`${label}: have`);
      continue;
    }
    console.log(`${label}: downloading`);
    for (const part of a.parts) {
      gh(['release', 'download', release.tag, '--repo', release.repo, '--pattern', part, '--dir', tmp, '--clobber']);
    }
    await mkdir(dirname(dest), { recursive: true });
    const partial = `${dest}.part`;
    const out = createWriteStream(partial);
    for (const part of a.parts) await pipeline(createReadStream(join(tmp, part)), out, { end: false });
    await new Promise((resolve, reject) => out.end((err) => (err ? reject(err) : resolve())));
    for (const part of a.parts) await rm(join(tmp, part), { force: true });
    if ((await sha256(partial)) !== a.sha256) {
      await rm(partial, { force: true });
      throw new Error(`${a.path}: SHA-256 mismatch after download`);
    }
    await rename(partial, dest);
  }
  console.log(`\nDone. Copy this whole folder (scripts + payload/) to the USB drive.`);
} finally {
  await rm(tmp, { recursive: true, force: true });
}
