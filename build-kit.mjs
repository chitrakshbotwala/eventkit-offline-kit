#!/usr/bin/env node
/**
 * Builds the offline (pendrive) kit: every file the desktop app would download during
 * setup, for every supported OS, plus the EventKit installers themselves.
 *
 * Run it once on a machine with internet (Node 22+, no other dependencies):
 *
 *   node offline-kit/build-kit.mjs                       # all targets into offline-kit/payload
 *   node offline-kit/build-kit.mjs --out E:\             # straight onto a USB drive
 *   node offline-kit/build-kit.mjs --targets windows-x64,macos-arm64
 *
 * Trust chain: the signed manifest is fetched from the server and its Ed25519 signature is
 * checked against the same public key the desktop app embeds. Every manifest artifact is
 * checked against the manifest's SHA-256, Android SDK packages against Google's SHA-1, and
 * the EventKit installers against the release's SHA256SUMS.txt. The install scripts then
 * re-check every file's SHA-256 (from the kit index) before using it.
 */
import { createHash, createPublicKey, verify } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync } from 'node:fs';
import { copyFile, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const HERE = dirname(fileURLToPath(import.meta.url));

const DEFAULTS = {
  server: 'https://darted.gdgkiit.in',
  // Production manifest key (GitHub variable EVENTKIT_MANIFEST_PUBKEYS, key id d6880dc0b37be84b).
  pubkeys: 'qy2+kKxbjv7A5Bxpptma7kvFGCWkEyV3f+2Guve7gPs=',
  repo: 'chitrakshbotwala/eventkit',
};

const ALL_TARGETS = ['windows-x64', 'windows-arm64', 'macos-arm64', 'macos-x64', 'linux-x64'];

/** Android repository host-os names per manifest OS. */
const ANDROID_HOST = { windows: 'windows', macos: 'macosx', linux: 'linux' };
const ANDROID_REPO = 'https://dl.google.com/android/repository/';

/** Files the install scripts run or copy, next to payload/ on the drive. */
const SCRIPTS = ['README.md', 'install-windows.cmd', 'install-windows.ps1', 'install.sh'];

const { values: opts } = parseArgs({
  options: {
    out: { type: 'string' },
    targets: { type: 'string' },
    server: { type: 'string', default: process.env.EVENTKIT_SERVER_URL ?? DEFAULTS.server },
    pubkeys: {
      type: 'string',
      default: process.env.EVENTKIT_MANIFEST_PUBKEYS ?? DEFAULTS.pubkeys,
    },
    repo: { type: 'string', default: DEFAULTS.repo },
    'app-version': { type: 'string' },
    'skip-app': { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
    help: { type: 'boolean', short: 'h', default: false },
  },
});

if (opts.help) {
  console.log(`Usage: node offline-kit/build-kit.mjs [options]

  --out <dir>           Kit folder (default: offline-kit). payload/ is written inside it and
                        the install scripts are copied next to it when it is another folder.
  --targets <list>      Comma-separated, default all: ${ALL_TARGETS.join(',')}
  --server <url>        EventKit server (default ${DEFAULTS.server})
  --pubkeys <keys>      Trusted manifest public keys, comma-separated base64
  --repo <owner/name>   GitHub repo with the desktop releases (default ${DEFAULTS.repo})
  --app-version <x.y.z> Desktop release to bundle (default: latest)
  --skip-app            Don't bundle the EventKit installers
  --dry-run             Check the manifests and list the files, without downloading`);
  process.exit(0);
}

const outDir = resolve(opts.out ?? HERE);
const payload = join(outDir, 'payload');
const targets = (opts.targets ?? ALL_TARGETS.join(','))
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
for (const t of targets) {
  if (!ALL_TARGETS.includes(t)) die(`unknown target ${t} (expected one of ${ALL_TARGETS})`);
}

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

const mb = (n) => `${(n / 1e6).toFixed(1)} MB`;

// ---------------------------------------------------------------------------------------------
// Manifest signature (same rules as packages/shared: canonical JSON, Ed25519, key id = sha256)

function canonicalJson(v) {
  if (v === null) return 'null';
  if (Array.isArray(v))
    return `[${v.map((x) => (x === undefined ? 'null' : canonicalJson(x))).join(',')}]`;
  if (typeof v === 'object') {
    const keys = Object.keys(v)
      .filter((k) => v[k] !== undefined)
      .sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(v[k])}`).join(',')}}`;
  }
  if (typeof v === 'number' && !Number.isFinite(v)) throw new TypeError('non-finite number');
  return JSON.stringify(v);
}

const sha256Hex = (buf) => createHash('sha256').update(buf).digest('hex');

function verifyManifest(envelope, trusted, expect) {
  const keys = trusted
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  const key = keys.find((k) => sha256Hex(Buffer.from(k, 'base64')).slice(0, 16) === envelope.keyId);
  if (!key) throw new Error(`manifest signed by unknown key ${envelope.keyId}`);
  const publicKey = createPublicKey({
    key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(key, 'base64').toString('base64url') },
    format: 'jwk',
  });
  const sig = Buffer.from(envelope.signature, 'base64');
  const ok =
    envelope.alg === 'Ed25519' &&
    sig.length === 64 &&
    verify(null, Buffer.from(canonicalJson(envelope.payload)), publicKey, sig);
  if (!ok) throw new Error('manifest signature invalid');
  const m = envelope.payload;
  if (m.target.os !== expect.os || m.target.arch !== expect.arch)
    throw new Error('manifest is for a different platform');
  if (m.placeholder)
    throw new Error('server returned a placeholder manifest (resolve it in Admin → Settings)');
  return m;
}

// ---------------------------------------------------------------------------------------------
// Downloads

async function hashFile(path, algo = 'sha256') {
  const h = createHash(algo);
  await pipeline(createReadStream(path), h);
  return h.digest('hex');
}

/**
 * Download `url` to `dest` unless a file with the expected hash is already there.
 * `expect` is { sha256 } or { sha1 }; without one the SHA-256 is computed and returned, and
 * { keep: true } reuses a file from an earlier run instead of downloading it again.
 */
async function fetchFile(url, dest, expect = {}, label = url) {
  if (opts['dry-run']) {
    console.log(`  would get ${label}`);
    dryRunFiles.add(url);
    return { sha256: expect.sha256 ?? 'dry-run', size: 0 };
  }
  const algo = expect.sha1 ? 'sha1' : 'sha256';
  const want = expect.sha1 ?? expect.sha256;
  if (
    existsSync(dest) &&
    ((want && (await hashFile(dest, algo)) === want) || (!want && expect.keep))
  ) {
    console.log(`  have ${label}`);
    return {
      sha256: want && algo === 'sha256' ? want : await hashFile(dest),
      size: (await stat(dest)).size,
    };
  }
  await mkdir(dirname(dest), { recursive: true });
  const part = `${dest}.part`;
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(url, {
        redirect: 'follow',
        headers: { 'user-agent': 'eventkit-offline-kit' },
      });
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
      const total = Number(res.headers.get('content-length')) || 0;
      process.stdout.write(`  get  ${label}${total ? ` (${mb(total)})` : ''}…`);
      await pipeline(Readable.fromWeb(res.body), createWriteStream(part));
      const got = await hashFile(part, algo);
      if (want && got !== want) throw new Error(`${algo} mismatch: expected ${want}, got ${got}`);
      await rename(part, dest);
      const size = (await stat(dest)).size;
      process.stdout.write(` ok\n`);
      return { sha256: algo === 'sha256' ? got : await hashFile(dest), size };
    } catch (err) {
      process.stdout.write('\n');
      await rm(part, { force: true });
      if (attempt >= 3) throw new Error(`${label}: ${err.message}`);
      console.warn(`  retry ${label} (${err.message})`);
      await new Promise((r) => setTimeout(r, 2000 * attempt));
    }
  }
}

async function fetchJson(url) {
  const res = await fetch(url, {
    headers: { 'user-agent': 'eventkit-offline-kit', accept: 'application/json' },
  });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res.json();
}

async function fetchText(url) {
  const res = await fetch(url, { headers: { 'user-agent': 'eventkit-offline-kit' } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res.text();
}

// ---------------------------------------------------------------------------------------------
// Android SDK packages (sdkmanager can't fetch other hosts' archives, so read Google's repo)

let androidRepo = null;
async function androidArchive(pkgPath, os, arch) {
  androidRepo ??= await fetchText(`${ANDROID_REPO}repository2-3.xml`);
  const start = androidRepo.indexOf(`<remotePackage path="${pkgPath}"`);
  if (start === -1) throw new Error(`Android package ${pkgPath} not in repository2-3.xml`);
  const block = androidRepo.slice(start, androidRepo.indexOf('</remotePackage>', start));
  const archives = [...block.matchAll(/<archive>([\s\S]*?)<\/archive>/g)].map(([, a]) => ({
    url: /<url>([^<]+)<\/url>/.exec(a)?.[1],
    sha1: /<checksum type="sha1">([0-9a-f]{40})<\/checksum>/.exec(a)?.[1],
    hostOs: /<host-os>([^<]+)<\/host-os>/.exec(a)?.[1],
    hostArch: /<host-arch>([^<]+)<\/host-arch>/.exec(a)?.[1],
  }));
  const wantArch = arch === 'arm64' ? 'aarch64' : 'x64';
  const fits = archives.filter(
    (a) => a.url && a.sha1 && (!a.hostOs || a.hostOs === ANDROID_HOST[os]),
  );
  const pick = fits.find((a) => a.hostArch === wantArch) ?? fits.find((a) => !a.hostArch);
  if (!pick) throw new Error(`no ${os}/${arch} archive for Android package ${pkgPath}`);
  return pick;
}

// ---------------------------------------------------------------------------------------------
// EventKit installers from GitHub Releases

let release = null;
const dryRunFiles = new Set();
/** .vsix hashes by extension id: one download serves every target. */
const vsixHashes = new Map();
async function appRelease() {
  if (release) return release;
  const tag = opts['app-version'] ? `tags/v${opts['app-version'].replace(/^v/, '')}` : 'latest';
  const rel = await fetchJson(`https://api.github.com/repos/${opts.repo}/releases/${tag}`);
  const sumsAsset = rel.assets.find((a) => a.name === 'SHA256SUMS.txt');
  const sums = new Map();
  if (sumsAsset) {
    for (const line of (await fetchText(sumsAsset.browser_download_url)).split(/\r?\n/)) {
      const m = /^([0-9a-f]{64})\s+\*?(.+)$/.exec(line.trim());
      if (m) sums.set(m[2], m[1]);
    }
  }
  release = { version: rel.tag_name.replace(/^v/, ''), assets: rel.assets, sums };
  return release;
}

/** Release asset patterns per target, with the kind the install scripts dispatch on. */
const APP_ASSETS = {
  windows: [{ kind: 'app-exe', re: /^EventKit-Setup-.*-x64\.exe$/ }],
  macos: [{ kind: 'app-dmg', re: (arch) => new RegExp(`^EventKit-.*-${arch}\\.dmg$`) }],
  linux: [
    { kind: 'app-appimage', re: /^EventKit-.*\.AppImage$/ },
    { kind: 'app-deb', re: /^EventKit-.*\.deb$/ },
    { kind: 'app-rpm', re: /^EventKit-.*\.rpm$/ },
    { kind: 'app-pacman', re: /^EventKit-.*\.pkg\.tar\.(?:xz|zst)$/ },
  ],
};

// ---------------------------------------------------------------------------------------------

/** One installable file. Rows become targets/<target>.tsv for the install scripts. */
function row(kind, file, sha256, arg = '') {
  for (const v of [kind, file, sha256, arg]) {
    if (/[\t\r\n]/.test(v)) throw new Error(`unexpected whitespace in kit row: ${v}`);
  }
  return { kind, file, sha256, arg };
}

async function buildTarget(target) {
  const [os, arch] = target.split('-');
  console.log(`\n== ${target}`);
  const envelope = await fetchJson(
    `${opts.server.replace(/\/+$/, '')}/api/manifest?os=${os}&arch=${arch}`,
  );
  const m = verifyManifest(envelope, opts.pubkeys, { os, arch });
  console.log(`  manifest ${m.manifestId} (${m.event.name}), signature ok`);
  if (!opts['dry-run']) {
    await mkdir(join(payload, 'manifests'), { recursive: true });
    await writeFile(
      join(payload, 'manifests', `${target}.json`),
      JSON.stringify(envelope, null, 2),
    );
  }

  const rows = [];
  const meta = (key, value) => rows.push(row('meta', key, '-', String(value)));
  meta('event', m.event.name.replace(/[\t\r\n]/g, ' '));
  meta('manifestId', m.manifestId);

  /** Manifest artifacts keep the desktop app's cache name: <sha256[:12]>-<fileName>. */
  const artifact = async (kind, a, arg = '') => {
    if (a.hashFromMirror) {
      // Upstream publishes no hash for "current" downloads (Chrome, Android cmdline-tools):
      // the server hashed its copy, and Google may have shipped a new build since.
      const file = `files/${a.fileName}`;
      const { sha256 } = await fetchFile(a.url, join(payload, file), { keep: true }, a.fileName);
      if (sha256 !== a.sha256 && !opts['dry-run']) {
        console.warn(
          `  warning: ${a.fileName} changed upstream since the server hashed it; using the new build`,
        );
        console.warn(
          '           (refresh the manifest in Admin → Settings so the app expects it too)',
        );
      }
      rows.push(row(kind, file, sha256, arg));
      return;
    }
    const file = `files/${a.sha256.slice(0, 12)}-${a.fileName}`;
    await fetchFile(a.url, join(payload, file), { sha256: a.sha256 }, a.fileName);
    rows.push(row(kind, file, a.sha256, arg));
  };

  for (const c of m.components) {
    if (!c.enabled) continue;
    switch (c.id) {
      case 'linux-deps':
        for (const [pm, list] of Object.entries(c.packages))
          meta(`linuxPackages.${pm}`, list.join(' '));
        break;
      case 'git':
        meta('gitMinVersion', c.minVersion);
        if (os === 'windows' && c.artifact)
          await artifact('git-exe', c.artifact, c.artifact.installArgs.join(' '));
        break;
      case 'flutter':
        meta('flutterVersion', c.version);
        meta('flutterPinned', c.pinned);
        await artifact(`flutter-${c.artifact.kind}`, c.artifact);
        break;
      case 'java':
        meta('javaMajor', c.majorVersion);
        await artifact(`java-${c.artifact.kind}`, c.artifact);
        break;
      case 'android': {
        await artifact('android-cmdline-tools', c.cmdlineTools);
        for (const p of c.packages) {
          const a = await androidArchive(p, os, arch);
          const file = `android/${a.url}`;
          const { sha256 } = await fetchFile(
            new URL(a.url, ANDROID_REPO).href,
            join(payload, file),
            { sha1: a.sha1 },
            a.url,
          );
          rows.push(row('android-package', file, sha256, p));
        }
        break;
      }
      case 'chrome':
        if (c.artifact)
          await artifact(`chrome-${c.artifact.kind}`, c.artifact, c.artifact.installArgs.join(' '));
        if (c.linuxPackages) {
          await artifact('chrome-deb', c.linuxPackages.deb);
          await artifact('chrome-rpm', c.linuxPackages.rpm);
        }
        break;
      case 'vscode':
        if (c.artifact)
          await artifact(`vscode-${c.artifact.kind}`, c.artifact, c.artifact.installArgs.join(' '));
        for (const ext of c.extensions) {
          const [publisher, name] = ext.split('.');
          const file = `vscode-extensions/${ext}.vsix`;
          // Dart-Code extensions are platform-neutral, so one .vsix serves every target.
          const url = `https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${publisher}/vsextensions/${name}/latest/vspackage`;
          const known = vsixHashes.get(ext);
          const { sha256 } = known
            ? { sha256: known }
            : await fetchFile(url, join(payload, file), { keep: true }, `${ext}.vsix`);
          vsixHashes.set(ext, sha256);
          rows.push(row('vscode-extension', file, sha256, ext));
        }
        break;
      case 'warmup':
        if (c.starter) {
          await artifact('starter-project', { ...c.starter, kind: 'zip' }, c.starter.projectName);
          meta('starterSha256', c.starter.sha256);
        }
        break;
      default:
        break;
    }
  }

  if (!opts['skip-app']) {
    const rel = await appRelease();
    meta('appVersion', rel.version);
    for (const { kind, re } of APP_ASSETS[os]) {
      const pattern = typeof re === 'function' ? re(arch) : re;
      const asset = rel.assets.find((a) => pattern.test(a.name));
      if (!asset) {
        console.warn(`  warning: no release asset for ${kind} in v${rel.version}`);
        continue;
      }
      const file = `app/${asset.name}`;
      const { sha256 } = await fetchFile(
        asset.browser_download_url,
        join(payload, file),
        rel.sums.has(asset.name) ? { sha256: rel.sums.get(asset.name) } : { keep: true },
        asset.name,
      );
      rows.push(row(kind, file, sha256));
    }
  }

  if (opts['dry-run']) return { target, manifestId: m.manifestId, event: m.event, rows };
  await mkdir(join(payload, 'targets'), { recursive: true });
  const tsv = rows.map((r) => [r.kind, r.file, r.sha256, r.arg].join('\t')).join('\n') + '\n';
  await writeFile(join(payload, 'targets', `${target}.tsv`), tsv);
  return { target, manifestId: m.manifestId, event: m.event, rows };
}

async function main() {
  console.log(`EventKit offline kit → ${outDir}`);
  console.log(`server ${opts.server}, targets ${targets.join(', ')}`);
  const built = [];
  for (const t of targets) built.push(await buildTarget(t));
  if (opts['dry-run']) {
    console.log(`
Dry run: ${dryRunFiles.size} files to download, nothing written.`);
    return;
  }

  if (outDir !== HERE) {
    for (const f of SCRIPTS) await copyFile(join(HERE, f), join(outDir, f));
  }

  // Human-readable index (the install scripts read targets/*.tsv).
  let total = 0;
  const seen = new Set();
  for (const b of built) {
    for (const r of b.rows) {
      if (r.kind === 'meta' || seen.has(r.file)) continue;
      seen.add(r.file);
      total += (await stat(join(payload, r.file))).size;
    }
  }
  // Targets built by an earlier run (--targets) stay in the index.
  const index = join(payload, 'kit.json');
  const previous = existsSync(index) ? JSON.parse(await readFile(index, 'utf8')).targets : {};
  const targetsIndex = { ...previous };
  for (const b of built) {
    targetsIndex[b.target] = {
      builtAt: new Date().toISOString(),
      manifestId: b.manifestId,
      event: b.event.name,
      appVersion: release?.version ?? null,
      files: b.rows.filter((r) => r.kind !== 'meta'),
    };
  }
  await writeFile(index, JSON.stringify({ server: opts.server, targets: targetsIndex }, null, 2));
  console.log(`\nDone: ${seen.size} files, ${(total / 1e9).toFixed(2)} GB in ${payload}`);
  console.log(
    'Copy the whole kit folder to the drive (exFAT or NTFS; FAT32 is fine too, all files are < 4 GB).',
  );
}

main().catch((err) => die(err.message));
