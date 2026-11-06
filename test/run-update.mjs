// 자동 업데이트 시험: 빌드한 앱(옛 버전)이 이 맥 안의 업데이트 목록에서 9.9.9를 찾아 받고,
// 번역 중이 된 뒤에 설치하고 다시 켜지는지 본다. 다른 키로 서명했거나 서명 뒤에 바뀐 업데이트는 설치하면 안 된다.
// 출시와 같은 Developer ID 서명이 필요하다. 업데이트 서명 키는 시험마다 새로 만들고, 출시 키는 쓰지 않는다.
// 새 버전 자리에는 켜지면 표시 파일만 남기고 끝나는 작은 앱을 넣는다. 사용법: ./build.sh && node test/run-update.mjs
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { generateKeyPairSync } from 'node:crypto';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildFake, fakeID, fakePids, quitFake, removeFake, sleep, until } from './fake-discord.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const sparkleBin = join(root, 'vendor/Sparkle-2.10.1/bin');
const testID = 'kr.yeoreum.discord-translator.update-test';
const base = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'krt-update-'));
const data = join(base, 'data');
const languages = join(base, 'languages.json');
const packs = join(base, 'packs.json');
const oldApp = join(base, 'installed/디스코드 번역.app');
const marker = join(base, 'installed/relaunched.txt');
mkdirSync(data);

let failures = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? '통과' : '실패'} | ${name}${detail ? ` | ${detail}` : ''}`);
  if (!ok) failures++;
}

const identity = spawnSync('security', ['find-identity', '-v', '-p', 'codesigning'], { encoding: 'utf8' }).stdout.match(/"(Developer ID Application:[^"]+)"/)?.[1];
if (!identity) {
  console.log('건너뜀 | Developer ID Application 인증서가 없어 업데이트 시험을 하지 않습니다');
  process.exit(0);
}

// Sparkle 키 파일 형식: 32바이트 시드를 base64로. 공개 키도 32바이트를 base64로.
function makeKey(name) {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const file = join(base, `${name}.key`);
  writeFileSync(file, privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32).toString('base64'));
  return { file, publicKey: publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64') };
}

const plist = (file, key, value) => execFileSync('plutil', ['-replace', key, typeof value === 'boolean' ? '-bool' : '-string', String(value), file]);
const version = () => execFileSync('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', join(oldApp, 'Contents/Info.plist')], { encoding: 'utf8' }).trim();

// 빌드한 앱을 시험용 번들 ID와 시험 키로 바꿔 출시처럼 서명한다. 실제 앱의 설정·Sparkle 기록과 섞이지 않는다.
function installOldApp(key) {
  rmSync(dirname(oldApp), { recursive: true, force: true });
  mkdirSync(dirname(oldApp));
  execFileSync('ditto', [join(root, 'build/디스코드 번역.app'), oldApp]);
  plist(join(oldApp, 'Contents/Info.plist'), 'CFBundleIdentifier', testID);
  plist(join(oldApp, 'Contents/Info.plist'), 'SUPublicEDKey', key.publicKey);
  execFileSync(join(root, 'tools/sign-app.sh'), [identity, oldApp], { stdio: 'ignore' });
}

// 새 버전 9.9.9: 켜지면 자기 버전을 표시 파일에 적고 끝난다. 출시처럼 앱과 응용 프로그램 바로가기를 담은 DMG로 낸다.
function buildNewRelease(key, folder, feedPrefix) {
  const stage = join(base, 'stage');
  rmSync(stage, { recursive: true, force: true });
  const app = join(stage, '디스코드 번역.app');
  mkdirSync(join(app, 'Contents/MacOS'), { recursive: true });
  const source = join(base, 'new.swift');
  writeFileSync(source, `import Foundation
let marker = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("relaunched.txt")
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
try? version.write(to: marker, atomically: true, encoding: .utf8)
`);
  execFileSync('swiftc', ['-swift-version', '5', '-target', 'arm64-apple-macos26.0', source, '-o', join(app, 'Contents/MacOS/DiscordTranslator')], { stdio: 'inherit' });
  writeFileSync(join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${testID}</string>
<key>CFBundleName</key><string>디스코드 번역</string>
<key>CFBundleExecutable</key><string>DiscordTranslator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>9.9.9</string>
<key>CFBundleVersion</key><string>9.9.9</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>SUPublicEDKey</key><string>${key.publicKey}</string>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
</dict></plist>`);
  execFileSync('codesign', ['--force', '--options', 'runtime', '--timestamp', '--sign', identity, app], { stdio: 'ignore' });
  symlinkSync('/Applications', join(stage, '응용 프로그램'));
  rmSync(folder, { recursive: true, force: true });
  mkdirSync(folder);
  const dmg = join(folder, 'DiscordTranslator-9.9.9.dmg');
  execFileSync('hdiutil', ['create', '-volname', '디스코드 번역', '-srcfolder', stage, '-format', 'UDZO', '-ov', dmg], { stdio: 'ignore' });
  execFileSync('codesign', ['--force', '--timestamp', '--sign', identity, dmg], { stdio: 'ignore' });
  writeFileSync(join(folder, 'DiscordTranslator-9.9.9.md'), '## 바뀐 점\n\n- 시험용 새 버전입니다.\n');
  execFileSync(join(sparkleBin, 'generate_appcast'), ['--ed-key-file', key.file, '--download-url-prefix', feedPrefix, '--embed-release-notes', folder], { stdio: 'ignore' });
}

let site = '';
const requests = [];
const server = createServer((req, res) => {
  requests.push(req.url);
  const file = join(site, decodeURIComponent(req.url.split('?')[0]));
  if (!file.startsWith(site) || !existsSync(file)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200);
  res.end(readFileSync(file));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const prefix = `http://127.0.0.1:${server.address().port}/`;

let helper;
let logs = [];
function startOldApp() {
  logs = [];
  const binary = join(oldApp, 'Contents/MacOS/DiscordTranslator');
  helper = spawn(binary, ['--headless', '--discord-bundle', fakeID, '--match', 'mock.html', '--script', join(root, 'Resources/inject.js'), '--data-dir', data,
    '--fake-languages', languages, '--fake-packs', packs, '--feed-url', `${prefix}appcast.xml`], { stdio: ['ignore', 'ignore', 'pipe'] });
  helper.exited = new Promise((r) => helper.on('exit', (code) => { helper.code = code; r(code); }));
  helper.stderr.on('data', (d) => logs.push(d.toString()));
}
const logged = (text) => logs.join('').includes(text);
const updateLines = () => logs.join('').split('\n').filter((line) => line.includes('새 버전')).map((line) => line.replace(/^.*?(새 버전)/, '$1')).join(' / ');
const stopOldApp = async () => {
  if (helper && helper.code === undefined) { helper.kill(); await helper.exited; }
};
const forgetSparkle = () => {
  spawnSync('defaults', ['delete', testID], { stdio: 'ignore' });
  rmSync(join(homedir(), 'Library/Preferences', `${testID}.plist`), { force: true });
  for (const folder of ['Library/Caches', 'Library/HTTPStorages', 'Library/Application Support']) {
    rmSync(join(homedir(), folder, testID), { recursive: true, force: true });
  }
};

try {
  buildFake();
  forgetSparkle();
  writeFileSync(packs, JSON.stringify({}));
  writeFileSync(join(data, 'settings.json'), JSON.stringify({ targetLanguage: 'ko', restartWithoutAsking: true }));
  const key = makeKey('release');
  const attacker = makeKey('attacker');

  // 다른 키로 서명한 업데이트 목록과 파일은 받지도 설치하지도 않는다.
  site = join(base, 'site-attacker');
  buildNewRelease(attacker, site, prefix);
  installOldApp(key);
  writeFileSync(languages, JSON.stringify({ ko: 'installed', ja: 'installed' }));
  startOldApp();
  await until(() => logged('번역 표시 연결'), 30000);
  const rejected = await until(() => logged('새 버전 확인 실패'), 20000);
  await sleep(3000);
  check('다른 키로 서명한 업데이트 목록은 거부함', !!rejected && !logged('새 버전 있음') && !logged('새 버전 받음') && helper.code === undefined && version() === '0.2.1', updateLines());
  await stopOldApp();
  await quitFake();
  forgetSparkle();

  // 목록은 맞게 서명됐어도 서명한 뒤에 DMG가 바뀌었으면 설치하지 않는다.
  site = join(base, 'site-tampered');
  buildNewRelease(key, site, prefix);
  const dmgPath = join(site, 'DiscordTranslator-9.9.9.dmg');
  const dmgBytes = readFileSync(dmgPath);
  dmgBytes[Math.floor(dmgBytes.length / 2)] ^= 0xff;
  writeFileSync(dmgPath, dmgBytes);
  installOldApp(key);
  startOldApp();
  await until(() => logged('번역 표시 연결'), 30000);
  const refused = await until(() => logged('새 버전 확인 실패'), 30000);
  await sleep(3000);
  check('서명 뒤에 바뀐 DMG는 설치하지 않음', !!refused && !logged('새 버전 설치') && helper.code === undefined && version() === '0.2.1', updateLines());
  await stopOldApp();
  await quitFake();
  forgetSparkle();

  // 자동 설치를 끄면 찾기만 하고 빨간 점으로 알린다.
  site = join(base, 'site');
  buildNewRelease(key, site, prefix);
  installOldApp(key);
  spawnSync('defaults', ['write', testID, 'SUAutomaticallyUpdate', '-bool', 'false']);
  startOldApp();
  const reminded = await until(() => logged('새 버전 알림: 9.9.9'), 30000);
  await sleep(3000);
  check('자동 설치를 끄면 알리기만 함', !!reminded && logged('새 버전 있음: 9.9.9') && !logged('새 버전 받음') && helper.code === undefined && version() === '0.2.1', updateLines());
  await stopOldApp();
  await quitFake();
  forgetSparkle();

  // 자동 설치: 번역 언어를 기다리는 동안 받아만 두고, 번역 중이 되면 설치하고 다시 켠다. 디스코드는 그대로다.
  installOldApp(key);
  writeFileSync(languages, JSON.stringify({ ko: 'supported', ja: 'installed' }));
  startOldApp();
  const downloaded = await until(() => logged('새 버전 받음: 9.9.9'), 30000);
  await sleep(4000);
  check('번역 중이 아니면 받아 두기만 함', !!downloaded && !logged('새 버전 설치') && helper.code === undefined && version() === '0.2.1', updateLines());
  writeFileSync(languages, JSON.stringify({ ko: 'installed', ja: 'installed' }));
  const installing = await until(() => logged('새 버전 설치'), 40000);
  const discordBefore = fakePids()[0];
  const exited = await Promise.race([helper.exited.then(() => true), sleep(30000).then(() => false)]);
  check('번역 중이 되면 설치를 시작하고 앱이 꺼짐', !!installing && exited);
  const relaunched = await until(() => existsSync(marker) && readFileSync(marker, 'utf8') === '9.9.9', 60000);
  check('새 버전으로 바뀌고 다시 켜짐', !!relaunched && version() === '9.9.9', `설치된 버전 ${version()}`);
  check('디스코드는 그대로 켜져 있음', !!discordBefore && fakePids()[0] === discordBefore);
  check('업데이트 목록과 DMG를 시험 서버에서 받음', requests.some((url) => url.startsWith('/appcast.xml')) && requests.some((url) => url.endsWith('.dmg')));
} catch (error) {
  failures++;
  console.error('시험 중단:', error);
} finally {
  await stopOldApp();
  await quitFake();
  server.close();
  removeFake();
  forgetSparkle();
  rmSync(base, { recursive: true, force: true });
}

console.log(failures ? `실패 ${failures}건` : '전부 통과');
process.exit(failures ? 1 : 0);
