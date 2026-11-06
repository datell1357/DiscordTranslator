// 시험용 가짜 디스코드: 진짜 디스코드 대신 띄워서 디버그 포트와 화면(mock.html)을 흉내 낸다.
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
export const fakeID = 'test.krt.fake-discord';
// 임시 폴더의 앱은 macOS가 번들 ID로 찾아 주지 않아서 build/ 아래에 만든다.
const fakeApp = join(root, 'build/test/FakeDiscord.app');
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export const until = async (test, ms = 20000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const value = await test();
    if (value) return value;
    await sleep(200);
  }
  return null;
};

export function buildFake() {
  rmSync(fakeApp, { recursive: true, force: true });
  const contents = join(fakeApp, 'Contents');
  mkdirSync(join(contents, 'MacOS'), { recursive: true });
  mkdirSync(join(contents, 'Resources'));
  execFileSync('swiftc', ['-swift-version', '5', '-target', 'arm64-apple-macos26.0', join(here, 'fake-discord.swift'), '-o', join(contents, 'MacOS/FakeDiscord')], { stdio: 'inherit' });
  writeFileSync(join(contents, 'Resources/mock-url.txt'), pathToFileURL(join(here, 'mock.html')).href);
  writeFileSync(join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${fakeID}</string>
<key>CFBundleExecutable</key><string>FakeDiscord</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>`);
  execFileSync('codesign', ['--force', '--sign', '-', fakeApp], { stdio: 'ignore' });
  execFileSync(lsregister, ['-f', fakeApp]);
}

export function removeFake() {
  spawnSync(lsregister, ['-u', fakeApp]);
  rmSync(join(root, 'build/test'), { recursive: true, force: true });
}

export const fakePids = () => {
  const out = spawnSync('pgrep', ['-f', 'FakeDiscord.app/Contents/MacOS/FakeDiscord'], { encoding: 'utf8' }).stdout.trim();
  return out ? out.split('\n').map(Number) : [];
};

export const fakePort = () => {
  for (const pid of fakePids()) {
    const args = spawnSync('ps', ['-o', 'args=', '-p', String(pid)], { encoding: 'utf8' }).stdout;
    const match = args.match(/--remote-debugging-port=(\d+)/);
    if (match) return Number(match[1]);
  }
  return null;
};

export const launchFake = async () => {
  spawnSync('open', ['-g', fakeApp]);
  return until(() => fakePids().length > 0);
};

export const quitFake = async () => {
  fakePids().forEach((pid) => { try { process.kill(pid, 'SIGTERM'); } catch {} });
  await until(() => fakePids().length === 0);
};
