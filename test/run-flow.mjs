// 실행 흐름 시험: 언어팩 대기, 디스코드 재시작 승인, 상주, 새 버전 알림.
// 진짜 디스코드 대신 가짜 앱을 쓰고, 상단 막대 아이콘과 창 없이 돌린다. 사용법: node test/run-flow.mjs
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const binary = join(root, 'build/디스코드 번역.app/Contents/MacOS/DiscordTranslator');
const lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
const base = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'krt-flow-'));
const data = join(base, 'data');
mkdirSync(data);
const languages = join(base, 'languages.json');
const settings = join(data, 'settings.json');
const fakeID = 'test.krt.fake-discord';
// 임시 폴더의 앱은 macOS가 번들 ID로 찾아 주지 않아서 build/ 아래에 만든다.
const fakeApp = join(root, 'build/test/FakeDiscord.app');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failures = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? '통과' : '실패'} | ${name}${detail ? ` | ${detail}` : ''}`);
  if (!ok) failures++;
}

function buildFake() {
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

const fakePids = () => {
  const out = spawnSync('pgrep', ['-f', 'FakeDiscord.app/Contents/MacOS/FakeDiscord'], { encoding: 'utf8' }).stdout.trim();
  return out ? out.split('\n').map(Number) : [];
};
const fakePort = () => {
  for (const pid of fakePids()) {
    const args = spawnSync('ps', ['-o', 'args=', '-p', String(pid)], { encoding: 'utf8' }).stdout;
    const match = args.match(/--remote-debugging-port=(\d+)/);
    if (match) return Number(match[1]);
  }
  return null;
};
const until = async (test, ms = 20000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const value = await test();
    if (value) return value;
    await sleep(200);
  }
  return null;
};
const launchFake = async () => {
  spawnSync('open', ['-g', fakeApp]);
  return until(() => fakePids().length > 0);
};
const quitFake = async () => {
  fakePids().forEach((pid) => { try { process.kill(pid, 'SIGTERM'); } catch {} });
  await until(() => fakePids().length === 0);
};

// 가짜 디스코드 화면에 번역 줄이 붙을 때까지 기다린다.
async function translatedLine(ms = 40000) {
  return until(async () => {
    const port = fakePort();
    if (!port) return null;
    try {
      const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = pages.find((p) => p.type === 'page' && p.url.includes('mock.html'));
      if (!page) return null;
      const socket = new WebSocket(page.webSocketDebuggerUrl);
      await new Promise((r, j) => { socket.onopen = r; socket.onerror = j; });
      const value = await new Promise((r) => {
        socket.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id === 1) r(m.result?.result?.value); };
        socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { returnByValue: true, expression: `document.getElementById('message-content-en1')?.nextElementSibling?.textContent` } }));
      });
      socket.close();
      return /[가-힣]/.test(value ?? '') ? value : null;
    } catch {
      return null;
    }
  }, ms);
}

let helper;
let logs = [];
function startHelper(...options) {
  logs = [];
  helper = spawn(binary, ['--headless', '--discord-bundle', fakeID, '--match', 'mock.html', '--script', join(root, 'Resources/inject.js'), '--data-dir', data, ...(options.includes('--fake-packs') ? options : [...options, '--fake-packs', packsFile])], { stdio: ['ignore', 'ignore', 'pipe'] });
  helper.exited = new Promise((r) => helper.on('exit', (code) => { helper.code = code; r(code); }));
  helper.stderr.on('data', (d) => logs.push(d.toString()));
}
const logged = (text) => logs.join('').includes(text);
const stopHelper = async () => {
  if (helper && helper.code === undefined) { helper.kill(); await helper.exited; }
};
const exitedIn = (ms) => Promise.race([helper.exited.then(() => true), sleep(ms).then(() => false)]);
const writeSettings = (value) => writeFileSync(settings, JSON.stringify(value));
const writeLanguages = (value) => writeFileSync(languages, JSON.stringify(value));
// 이 맥에 실제로 받은 언어팩과 무관하게 시험하도록 언어팩 상태는 언제나 가짜로 준다. 기본은 받은 언어팩 없음.
const packsFile = join(base, 'packs.json');
const writePacks = (value) => writeFileSync(packsFile, JSON.stringify(value));

let feed = { status: 404, body: {} };
const server = createServer((req, res) => {
  res.writeHead(feed.status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(feed.body));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const feedURL = `http://127.0.0.1:${server.address().port}/latest`;

try {
  buildFake();
  writePacks({});

  // 로그인 직후처럼 막 켜지는 디스코드는 첫 종료 요청을 놓칠 수 있다. 그래도 번역 모드로 다시 켜져야 한다.
  writeLanguages({ ko: 'installed', ja: 'installed' });
  writeSettings({ targetLanguage: 'ko', restartWithoutAsking: true });
  let raceFailures = 0;
  for (let round = 0; round < 6; round++) {
    await launchFake();
    startHelper('--fake-languages', languages);
    const startedAt = Date.now();
    const ok = !!(await until(() => fakePort(), 15000)) && !logged('끄지 못했어요');
    if (!ok) raceFailures++;
    console.log(`  막 켜지는 디스코드 ${round + 1}회: ${ok ? '성공' : '실패'} ${Date.now() - startedAt}ms${ok ? '' : ` | ${logs.join('').trim().split('\n').slice(-4).join(' / ')} | 프로세스 ${fakePids().length}개`}`);
    await stopHelper();
    await quitFake();
  }
  check('막 켜지는 디스코드도 번역 모드로 다시 켜짐', raceFailures === 0, `실패 ${raceFailures}회`);
  if (process.env.KRT_FLOW_ONLY === 'launch-race') throw new Error('STOP');

  writeSettings({ targetLanguage: 'ko' });
  writeLanguages({ ko: 'installed', ja: 'installed' });

  // 언어가 없으면 디스코드를 건드리지 않고 기다리다가, 언어가 생기면 앱을 다시 켜지 않아도 시작한다.
  writeLanguages({ ko: 'supported', ja: 'installed' });
  startHelper('--fake-languages', languages);
  await sleep(4000);
  check('언어가 없으면 기다림', logged('번역 언어가 없어 기다립니다') && helper.code === undefined);
  check('기다리는 동안 디스코드를 켜지 않음', fakePids().length === 0);
  writeLanguages({ ko: 'installed', ja: 'installed' });
  const firstLine = await translatedLine();
  check('언어를 받으면 앱을 다시 켜지 않아도 번역이 시작됨', !!firstLine, firstLine ?? '');

  // 실행 중에 언어가 사라졌다가 돌아와도 이어서 번역한다.
  writeLanguages({ ko: 'supported', ja: 'installed' });
  check('실행 중 언어가 사라지면 알아챔', !!(await until(() => logged('번역 언어: 없음'))));
  logs = [];
  writeLanguages({ ko: 'installed', ja: 'installed' });
  check('언어가 돌아오면 이어서 번역', !!(await until(() => logged('번역 언어: ko'))));

  // 번역 모델 자동: 언어팩이 있으면 언어팩, 없으면 Apple Intelligence. 켜 둔 채로 따라간다.
  const plainModel = () => /번역 언어: ko\n/.test(logs.join(''));
  const saved = () => JSON.parse(readFileSync(settings, 'utf8')).usesLanguagePacks;
  writePacks({ ko: 'supported', ja: 'installed' });
  await stopHelper();
  logs = [];
  startHelper('--fake-languages', languages, '--fake-packs', packsFile);
  await until(() => logged('번역 언어'));
  const canChoose = plainModel();
  if (canChoose) {
    check('자동: 언어팩이 없으면 Apple Intelligence로 번역함', !logged('(언어팩)'));
    logs = [];
    writePacks({ ko: 'installed', ja: 'installed' });
    check('자동: 언어팩이 생기면 켜 둔 채로 언어팩으로 바뀜', !!(await until(() => logged('번역 언어: ko (언어팩)'))));
    check('자동은 설정에 모델을 적지 않음', saved() === undefined);
    logs = [];
    writePacks({ ko: 'supported', ja: 'installed' });
    check('자동: 언어팩을 지우면 멈추지 않고 Apple Intelligence로 돌아감', !!(await until(plainModel)) && !logged('없음'));

    // 언어팩을 직접 골랐는데 언어팩이 없으면 기다렸다가 받으면 시작한다.
    logs = [];
    writeSettings({ targetLanguage: 'ko', usesLanguagePacks: true });
    check('언어팩을 직접 골랐는데 언어팩이 없으면 기다림', !!(await until(() => logged('번역 언어: 없음 (언어팩)'))));
    logs = [];
    writePacks({ ko: 'installed', ja: 'installed' });
    check('언어팩이 생기면 언어팩 모델로 번역을 시작함', !!(await until(() => logged('번역 언어: ko (언어팩)'))));

    // Apple Intelligence를 직접 고르면 언어팩이 있어도 자동으로 바꾸지 않는다.
    logs = [];
    writeSettings({ targetLanguage: 'ko', usesLanguagePacks: false });
    check('Apple Intelligence를 직접 고르면 그 모델로 돌아옴', !!(await until(plainModel)));
    await sleep(3000);
    check('직접 고른 모델은 언어팩이 있어도 유지됨', !logged('(언어팩)'));

    // 언어팩이 없을 때 언어팩을 고르면 지금 모델로 계속 번역하다가, 다 받으면 바뀐다(받기 창을 닫은 뒤에도).
    await stopHelper();
    logs = [];
    writePacks({ ko: 'supported', ja: 'installed' });
    writeSettings({ targetLanguage: 'ko' });
    startHelper('--fake-languages', languages, '--fake-packs', packsFile, '--choose-pack-model');
    await until(() => logged('번역 언어: ko'));
    await sleep(6000);
    check('언어팩을 받는 동안 지금 모델로 계속 번역함', plainModel() && !logged('없음') && !logged('(언어팩)'));
    check('언어팩을 받기 전에는 설정을 바꾸지 않음', saved() !== true);
    writePacks({ ko: 'installed', ja: 'installed' });
    check('언어팩을 다 받으면 창 없이도 언어팩 모델로 바뀌고 설정에 남음', !!(await until(() => logged('번역 언어: ko (언어팩)') && saved() === true)));
  } else {
    console.log('건너뜀 | 이 맥은 Apple Intelligence를 쓸 수 없어 모델 전환을 시험하지 않음');
  }

  // Apple Intelligence가 없는 맥은 언어팩 모델만 쓴다. 고르는 설정이 꺼져 있어도 마찬가지다.
  await stopHelper();
  logs = [];
  writePacks({ ko: 'supported', ja: 'installed' });
  writeSettings({ targetLanguage: 'ko' });
  startHelper('--fake-languages', languages, '--fake-packs', packsFile, '--no-apple-intelligence');
  check('Apple Intelligence가 없으면 언어팩이 있어야 시작함', !!(await until(() => logged('번역 언어가 없어 기다립니다'))));
  writePacks({ ko: 'installed', ja: 'installed' });
  check('Apple Intelligence가 없으면 언어팩 모델로 번역함', !!(await until(() => logged('번역 언어: ko (언어팩)'))));
  await stopHelper();
  logs = [];
  writePacks({});
  startHelper('--fake-languages', languages, '--discord-gone-seconds', '6');
  await until(() => logged('번역 언어: ko'));

  // 로그인 시작을 쓰지 않으면 디스코드와 함께 끝난다.
  await quitFake();
  check('평소에는 디스코드를 끄면 함께 끝남', await exitedIn(12000), `종료 코드 ${helper.code}`);

  // 디스코드가 업데이트로 잠깐 꺼졌다가 번역 없이 다시 켜져도 번역이 사라지지 않는다.
  await launchFake();
  startHelper('--fake-languages', languages, '--prompt-answer', 'yes');
  check('시험 준비: 번역 모드로 연결됨', !!(await until(() => fakePort() && logged('번역 표시 연결'))));
  await quitFake();
  await sleep(9000);
  check('업데이트처럼 잠깐 꺼져도 앱이 먼저 끝나지 않음', helper.code === undefined && logged('디스코드가 꺼져 있어 기다립니다') && !logged('함께 끝냅니다'));
  await launchFake();
  check('번역 없이 다시 켜지면 번역 모드로 되돌림', !!(await until(() => fakePort(), 30000)) && logged('번역 모드로 다시 시작'));
  await stopHelper();
  await quitFake();

  // 번역 없이 켜진 디스코드: 거절하면 끝나고, 디스코드는 그대로다.
  await launchFake();
  const running = fakePids()[0];
  startHelper('--prompt-answer', 'no');
  check('거절하면 앱이 끝남', await exitedIn(10000));
  check('거절하면 디스코드를 끄지 않음', fakePids()[0] === running && logged('확인 창(시험)'));

  // 로그인 시작 상태에서 거절: 남아 있고, 디스코드도 그대로이며, 다시 묻지 않는다.
  startHelper('--prompt-answer', 'no', '--resident');
  await sleep(6000);
  const asked = logs.join('').split('확인 창(시험)').length - 1;
  check('로그인 시작이면 거절해도 앱이 남음', helper.code === undefined && logged('디스코드 번역 시작'));
  check('거절한 디스코드는 건드리지 않음', fakePids()[0] === running);
  check('거절한 뒤 다시 묻지 않음', asked === 1, `${asked}번 물음`);
  await stopHelper();

  // 승인하면 번역 모드로 다시 켠다.
  startHelper('--prompt-answer', 'yes');
  const afterYes = await translatedLine();
  check('승인하면 번역 모드로 다시 켜짐', !!afterYes && fakePids()[0] !== running, afterYes ?? '');
  await stopHelper();
  await quitFake();

  // 사전 승인: 묻지 않고 다시 켠다.
  await launchFake();
  const beforeAuto = fakePids()[0];
  writeSettings({ targetLanguage: 'ko', restartWithoutAsking: true });
  startHelper('--resident');
  const afterAuto = await translatedLine();
  check('사전 승인하면 묻지 않고 다시 켜짐', !!afterAuto && fakePids()[0] !== beforeAuto && logged('묻지 않고 다시 시작') && !logged('확인 창(시험)'), afterAuto ?? '');

  // 로그인 시작: 디스코드를 꺼도 남아 있다가, 번역 없이 다시 켜지면 번역 모드로 바꾼다.
  await quitFake();
  check('로그인 시작이면 디스코드를 꺼도 남음', !!(await until(() => logged('디스코드가 꺼져 있어 기다립니다'))) && helper.code === undefined);
  await sleep(1000);
  check('디스코드가 꺼진 동안 앱이 켜 주지 않음', fakePids().length === 0);
  await launchFake();
  const relaunched = fakePids()[0];
  const afterRelaunch = await translatedLine();
  check('번역 없이 다시 켜지면 번역 모드로 바꿈', !!afterRelaunch && fakePids()[0] !== relaunched, afterRelaunch ?? '');
  await stopHelper();
  await quitFake();

  // 설정 창 상태 줄: 지금 할 수 있는 일만 버튼으로 보여 준다(상단 막대 아이콘은 누르면 설정 창을 연다).
  const statusNow = () => logs.join('').split('상태 줄(시험): ').at(-1)?.split('\n')[0] ?? '';
  const plist = readFileSync(join(root, 'build/디스코드 번역.app/Contents/Info.plist'), 'utf8');
  check('Dock에 나오지 않는 앱으로 빌드됨', /<key>LSUIElement<\/key>\s*<true\/>/.test(plist));
  writePacks({});
  writeLanguages({ ko: 'installed', ja: 'installed' });
  writeSettings({ targetLanguage: 'ko', restartWithoutAsking: true });
  await launchFake();
  startHelper('--fake-languages', languages, '--resident', '--dump-status');
  await until(() => fakePort() && logged('번역 표시 연결'));
  check('번역 중 상태 줄에는 상태와 종료만 있음', !!(await until(() => statusNow() === '번역 중 | 종료')), statusNow());
  await quitFake();
  check('디스코드가 꺼지면 켜기 버튼이 나옴', !!(await until(() => statusNow() === '디스코드가 꺼져 있어요 | 번역 모드로 켜기 | 종료')), statusNow());
  await stopHelper();
  await launchFake();
  writeSettings({ targetLanguage: 'ko' });
  startHelper('--fake-languages', languages, '--resident', '--dump-status', '--prompt-answer', 'no');
  const firstRestartRow = () => logs.join('').split('상태 줄(시험): ').slice(1).map((l) => l.split('\n')[0]).find((l) => l.includes('다시 시작')) ?? '';
  check('재시작을 거절했으면 처음부터 번역 없이 켜짐과 다시 시작 버튼이 나옴', !!(await until(() => firstRestartRow())) && firstRestartRow() === '디스코드가 번역 없이 켜져 있어요 | 다시 시작 | 종료', firstRestartRow());
  await stopHelper();
  await quitFake();

  // 처음 실행 안내: 끝나기 전에는 디스코드를 건드리지 않는다.
  const readSaved = () => { try { return JSON.parse(readFileSync(settings, 'utf8')); } catch { return null; } };
  writePacks({});
  writeLanguages({ ko: 'installed', ja: 'installed' });
  rmSync(settings, { force: true });
  await launchFake();
  const plainDiscord = fakePids()[0];
  startHelper('--fake-languages', languages, '--onboarding-answer', 'auto');
  await sleep(1000);
  check('안내가 끝나기 전에는 설정 파일을 남기지 않음', readSaved() === null);
  check('안내가 끝나기 전에는 디스코드를 건드리지 않음', fakePids()[0] === plainDiscord && !fakePort() && !logged('확인 창'));
  check('안내의 버튼이 승인이라 또 묻지 않고 다시 켜짐', !!(await until(() => fakePort())) && logged('안내에서 승인') && !logged('확인 창') && fakePids()[0] !== plainDiscord);
  check('안내를 마치면 끝난 것으로 남고 모델은 자동', !!(await until(() => readSaved()?.onboardingPending === undefined)) && readSaved()?.targetLanguage === 'ko' && readSaved()?.usesLanguagePacks === undefined);
  await translatedLine();
  check('첫 번역이 붙으면 기록함', !!(await until(() => logged('온보딩: 첫 번역'))));
  const stepLog = logs.join('');
  check('단계를 맥 안 로그에 남김', stepLog.includes('온보딩: 시작') && stepLog.includes('온보딩: 번역 켜기'));
  check('첫 번역 기록은 한 번만 남음', stepLog.split('온보딩: 첫 번역').length === 2);
  await stopHelper();
  await quitFake();

  // 안내를 끝내지 않고 끈 경우: 다음 실행 때 다시 뜬다.
  await launchFake();
  const reopened = fakePids()[0];
  writeSettings({ targetLanguage: 'ko', onboardingPending: true });
  startHelper('--fake-languages', languages, '--onboarding-answer', 'ai');
  await sleep(1000);
  check('끝내지 않은 안내는 다시 뜸', fakePids()[0] === reopened && !fakePort() && !logged('디스코드 번역 시작'));
  check('안내를 마치면 고른 모델이 남음', !!(await until(() => readSaved()?.onboardingPending === undefined)) && (!canChoose || readSaved()?.usesLanguagePacks === false));
  await until(() => fakePort());
  await stopHelper();
  await quitFake();

  // 한 번 마친 안내는 다시 뜨지 않는다.
  await launchFake();
  startHelper('--fake-languages', languages, '--onboarding-answer', 'auto', '--prompt-answer', 'no');
  check('마친 안내는 다시 뜨지 않음', await exitedIn(10000) && logged('확인 창(시험)') && !logged('온보딩: 시작'));
  await quitFake();

  if (canChoose) {
    // 언어팩 제안: 자동 모델이 언어팩 없이 오래 번역할 때 한 번만, 번역이 끝난 뒤에 권한다.
    const hint = "안내: 언어팩 제안";
    await launchFake();
    writeLanguages({ th: 'installed' });
    writePacks({});
    writeSettings({ targetLanguage: 'th', restartWithoutAsking: true });
    startHelper('--fake-languages', languages, '--fake-packs', packsFile, '--pack-hint-after-ms', '1');
    check('언어팩 없이 오래 번역하면 언어팩을 권함', !!(await until(() => logged(hint), 60000)));
    await sleep(3000);
    check('언어팩 제안은 한 번만 함', logs.join('').split(hint).length === 2 && readSaved()?.packHintShown === true);
    await stopHelper();
    logs = [];
    startHelper('--fake-languages', languages, '--fake-packs', packsFile, '--pack-hint-after-ms', '1');
    await sleep(6000);
    check('다시 켜도 언어팩을 또 권하지 않음', !logged(hint));
    await stopHelper();

    // Apple Intelligence를 직접 고르면 권하지 않는다.
    writeSettings({ targetLanguage: 'th', restartWithoutAsking: true, usesLanguagePacks: false });
    startHelper('--fake-languages', languages, '--fake-packs', packsFile, '--pack-hint-after-ms', '1');
    await sleep(6000);
    check('Apple Intelligence를 직접 골랐으면 권하지 않음', !logged(hint));
    await stopHelper();
    await quitFake();
    writeLanguages({ ko: 'installed', ja: 'installed' });
  }

  if (canChoose) {
    // 언어팩을 골랐는데 아직 없으면 지금 모델로 시작하고, 다 받으면 바뀐다.
    await launchFake();
    writeSettings({ targetLanguage: 'ko', onboardingPending: true });
    startHelper('--fake-languages', languages, '--fake-packs', packsFile, '--onboarding-answer', 'pack');
    check('언어팩을 받는 중이어도 번역을 시작함', !!(await until(() => logged('번역 언어: ko') && !logged('(언어팩)'))));
    writePacks({ ko: 'installed', ja: 'installed' });
    check('언어팩을 다 받으면 언어팩으로 바뀌고 설정에 남음', !!(await until(() => logged('번역 언어: ko (언어팩)') && readSaved()?.usesLanguagePacks === true)));
    await stopHelper();
    await quitFake();
    writePacks({});

    // 언어를 기다리다 한참 뒤에 갑자기 디스코드를 끄면 안 된다. 승인은 30초가 지나면 다시 묻는다.
    await launchFake();
    const waitingDiscord = fakePids()[0];
    writeLanguages({ ko: 'supported', ja: 'installed' });
    writeSettings({ targetLanguage: 'ko', onboardingPending: true });
    startHelper('--fake-languages', languages, '--onboarding-answer', 'ai', '--prompt-answer', 'no');
    await until(() => logged('번역 언어가 없어 기다립니다'));
    await sleep(32000);
    check('언어를 기다리는 동안 디스코드를 끄지 않음', fakePids()[0] === waitingDiscord);
    writeLanguages({ ko: 'installed', ja: 'installed' });
    check('승인이 지나면 다시 묻고 거절하면 그대로 둠', await exitedIn(10000) && logged('확인 창(시험)') && !logged('안내에서 승인') && fakePids()[0] === waitingDiscord);
    await quitFake();
  }

  // 새 버전 알림
  writeSettings({ targetLanguage: 'ko' });
  const checkFeed = async (body, status = 200) => {
    feed = { status, body };
    const out = join(base, 'out.png');
    // 이 프로세스의 시험 서버가 응답해야 하므로 동기 실행을 쓰면 안 된다.
    const run = spawn(binary, ['--headless', '--data-dir', data, '--update-url', feedURL, '--render-settings', out], { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    run.stderr.on('data', (d) => { stderr += d; });
    await new Promise((r) => run.on('exit', r));
    return stderr;
  };
  const page = 'https://example.com/releases/latest';
  feed = { status: 200, body: { tag_name: 'v9.9.9', html_url: page } };
  writeSettings({ targetLanguage: 'ko', restartWithoutAsking: true });
  await launchFake();
  startHelper('--fake-languages', languages, '--resident', '--update-url', feedURL);
  check('켜 둔 동안에도 새 버전을 찾음', !!(await until(() => logged('새 버전 있음: 9.9.9'))));
  await stopHelper();
  await quitFake();
  writeSettings({ targetLanguage: 'ko' });
  check('새 버전이 있으면 알림', (await checkFeed({ tag_name: 'v9.9.9', html_url: page })).includes('새 버전 있음: 9.9.9'));
  check('10.0.0이 9.9.9보다 새 버전', (await checkFeed({ tag_name: 'v10.0.0', html_url: page })).includes('새 버전 있음: 10.0.0'));
  check('같은 버전이면 알리지 않음', !(await checkFeed({ tag_name: 'v0.2.0', html_url: page })).includes('새 버전 있음'));
  check('옛 버전이면 알리지 않음', !(await checkFeed({ tag_name: 'v0.1.0', html_url: page })).includes('새 버전 있음'));
  check('저장소가 아직 없어도(404) 그대로 동작', (await checkFeed({ message: 'Not Found' }, 404)).includes('새 버전 확인 실패'));
  check('https가 아닌 주소는 무시', !(await checkFeed({ tag_name: 'v9.9.9', html_url: 'http://example.com/' })).includes('새 버전 있음'));
} catch (error) {
  if (error.message !== 'STOP') {
    failures++;
    console.error('시험 중단:', error);
  }
} finally {
  await stopHelper();
  await quitFake();
  server.close();
  spawnSync(lsregister, ['-u', fakeApp]);
  rmSync(base, { recursive: true, force: true });
  rmSync(join(root, 'build/test'), { recursive: true, force: true });
}

console.log(failures ? `실패 ${failures}건` : '전부 통과');
process.exit(failures ? 1 : 0);
