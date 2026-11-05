// 실패 상황 시험: 스포일러, 번역 앱만 꺼진 경우, 일시적 번역 실패.
// 헤드리스 크롬의 모의 화면만 쓰고 실행 중인 디스코드는 건드리지 않는다. 사용법: node test/run-resilience.mjs
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const binary = process.env.KRT_TEST_BINARY || join(root, 'build/디스코드 번역.app/Contents/MacOS/DiscordTranslator');
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const port = 46000 + Math.floor(Math.random() * 1000);
const profile = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'krt-res-'));
const data = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'krt-res-data-'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hangul = /[가-힣]/;
const browser = spawn(chrome, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run', pathToFileURL(join(here, 'mock.html')).href], { stdio: 'ignore' });
const temporary = [];
let helper;
let failures = 0;

function check(name, ok, detail = '') {
  console.log(`${ok ? '통과' : '실패'} | ${name}${detail ? ` | ${detail}` : ''}`);
  if (!ok) failures++;
}

try {
  let url;
  for (let i = 0; i < 60 && !url; i++) {
    try { url = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((p) => p.type === 'page' && p.url.includes('mock.html'))?.webSocketDebuggerUrl; } catch {}
    await sleep(250);
  }
  const socket = new WebSocket(url);
  await new Promise((r) => { socket.onopen = r; });
  let seq = 0;
  const waiting = new Map();
  // 크롬과의 연결이 끊기면 조용히 멈추지 않고 원인을 남기고 끝낸다.
  let finished = false;
  browser.on('exit', (code, signal) => { if (!finished) console.error(`크롬이 끝남: 코드 ${code}, 신호 ${signal}`); });
  socket.onclose = (e) => {
    if (finished) return;
    console.error(`시험 중단: 크롬 연결이 끊김(코드 ${e.code})`);
    helper?.kill('SIGKILL');
    browser.kill();
    process.exit(1);
  };
  socket.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m.result?.result?.value); waiting.delete(m.id); } };
  const evaluate = (expression) => new Promise((res) => { const id = ++seq; waiting.set(id, res); socket.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression, returnByValue: true } })); });

  // 번역이 끝난 줄과 번역 중 표시를 나눠 읽는다.
  const state = (id) => evaluate(`(() => { const n = document.getElementById('message-content-${id}')?.nextElementSibling; if (!n?.classList.contains('krt-line')) return null; return { pending: n.classList.contains('krt-pending'), text: n.textContent }; })()`);
  const waitDone = async (id, ms = 20000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const s = await state(id);
      if (s && !s.pending) return s.text;
      await sleep(100);
    }
    return null;
  };
  const pendingCount = () => evaluate(`document.querySelectorAll('.krt-pending').length`);
  const add = (id, html) => evaluate(`addMsg('${id}', ${JSON.stringify(html)}); sc.scrollTop = sc.scrollHeight; 1`);
  let logs = '';
  const startHelper = (...options) => {
    const dir = options.includes('--data-dir') ? [] : ['--data-dir', data];
    const child = spawn(binary, ['--attach', String(port), '--match', 'mock.html', '--script', join(root, 'Resources/inject.js'), ...dir, ...options], { stdio: ['ignore', 'ignore', 'pipe'] });
    logs = '';
    child.stderr.on('data', (d) => { logs += d.toString(); });
    return child;
  };
  const stopHelper = async () => { helper.kill('SIGKILL'); await sleep(300); };

  // 모델은 자동이다. 언어팩이 있으면 언어팩, 없으면 Apple Intelligence로 돈다.
  writeFileSync(join(data, 'settings.json'), JSON.stringify({ targetLanguage: 'ko' }));
  helper = startHelper();
  await sleep(1500);
  await evaluate(`sc.scrollTop = sc.scrollHeight; 1`);
  await sleep(1000);

  // 1. 스포일러: 가려진 글이 번역 줄로 새면 안 된다.
  const hidden = (text) => `<span class="spoilerContent__299eb hiddenSpoiler__299eb" role="button"><span class="spoilerInnerContainer__299eb" aria-hidden="true">${text}</span></span>`;
  await add('spoil1', `The movie was really great and ${hidden('the hero dies at the very end')} so everyone cried.`);
  const spoil1 = await waitDone('spoil1');
  check('스포일러 글이 번역 줄에 나오지 않음', !!spoil1 && hangul.test(spoil1) && !/죽|사망/.test(spoil1) && spoil1.includes('███'), spoil1 ?? '');
  await add('spoil2', hidden('the hero dies at the very end'));
  await sleep(1500);
  check('전부 스포일러인 메시지는 번역하지 않음', (await state('spoil2')) === null);
  await evaluate(`(() => {
    addEmbed('spoil3', 'The secret ending of the movie', 'The hero dies at the very end of the story.');
    const article = document.querySelector('#message-accessories-spoil3 article');
    const box = document.createElement('div');
    box.className = 'spoilerEmbed__623de';
    article.replaceWith(box);
    box.appendChild(article);
    sc.scrollTop = sc.scrollHeight;
  })()`);
  await sleep(1500);
  check('스포일러로 가린 임베드는 번역하지 않음', (await evaluate(`document.querySelectorAll('#message-accessories-spoil3 .krt-line').length`)) === 0);

  // 2. 디스코드는 켠 채 번역 앱만 꺼진 경우: 번역 중 표시가 남으면 안 된다.
  await add('long0', 'This message is here so the translator has already shown at least one finished line.');
  await waitDone('long0');
  await stopHelper();
  await add('off1', 'This message arrived right after the translator app was closed by the user.');
  await sleep(1500);
  const whileDying = await state('off1');
  await sleep(7500);
  check('앱이 꺼지면 번역 중 표시가 사라짐', (await pendingCount()) === 0 && (await state('off1')) === null, JSON.stringify(whileDying));
  await add('off2', 'Another new message arrived while the translator app is still closed by the user.');
  await sleep(2000);
  check('앱이 꺼져 있는 동안 새 메시지에 표시가 생기지 않음', (await pendingCount()) === 0 && (await state('off2')) === null);

  // 2-1. 다시 켜면 화면이 움직이지 않아도 바로 이어진다.
  helper = startHelper();
  const resumedAt = Date.now();
  const off1 = await waitDone('off1', 15000);
  const off2 = await waitDone('off2', 15000);
  check('앱을 다시 켜면 밀린 메시지가 번역됨', !!off1 && !!off2 && hangul.test(off1) && hangul.test(off2), `${Date.now() - resumedAt}ms`);

  // 2-2. 번역 도중 앱이 죽고 곧바로 다시 켜져도 30초를 기다리지 않는다.
  await stopHelper();
  await add('quick1', 'A message that was still waiting when the app restarted very quickly just now.');
  await sleep(600);
  helper = startHelper();
  const quickAt = Date.now();
  const quick1 = await waitDone('quick1', 15000);
  check('앱이 곧바로 다시 켜지면 기다리지 않고 이어짐', !!quick1 && Date.now() - quickAt < 8000, `${Date.now() - quickAt}ms`);

  // 3. 일시적 번역 실패: 「번역 안 함」으로 굳으면 안 된다.
  await stopHelper();
  helper = startHelper('--fail-once-containing', 'fails once on purpose');
  await sleep(1500);
  await add('fail1', 'This sentence fails once on purpose and has to be translated on the next attempt.');
  const fail1 = await waitDone('fail1', 15000);
  check('일시적으로 실패한 글을 다시 번역함', !!fail1 && hangul.test(fail1), fail1 ?? '');

  await stopHelper();
  helper = startHelper('--fail-once-containing', 'fails once on purpose');
  await sleep(1500);
  await add('fail2', 'The first line of this notice fails once on purpose today.\nThe second line of this notice is translated on the first attempt.');
  let partial = null;
  for (let i = 0; i < 60 && !partial; i++) {
    const s = await state('fail2');
    if (s && !s.pending && s.text.includes('The first line')) partial = s.text;
    await sleep(50);
  }
  let finalText = await waitDone('fail2');
  for (let i = 0; i < 150 && (!finalText || finalText.includes('The first line')); i++) { await sleep(100); finalText = (await state('fail2'))?.text ?? finalText; }
  check('일부 줄만 실패하면 끝난 줄을 보여 주고 나중에 채움', !!partial && hangul.test(partial) && !!finalText && !finalText.includes('The first line') && finalText.split('\n').length === 2, JSON.stringify(finalText));
  check('실패 뒤 번역 중 표시가 남지 않음', (await pendingCount()) === 0);

  // 4. 번역 호출이 돌아오지 않아도 대기열이 영원히 멈추면 안 된다.
  await stopHelper();
  helper = startHelper('--hang-once-containing', 'hangs once on purpose', '--translation-timeout-seconds', '2');
  await sleep(1500);
  await add('hang1', 'This sentence hangs once on purpose and has to be translated after the time limit.');
  const hang1 = await waitDone('hang1', 20000);
  check('번역이 멈추면 시간 제한 뒤 다시 번역함', !!hang1 && hangul.test(hang1), hang1 ?? '');
  await add('hang2', 'The queue keeps moving after a translation call stopped answering for a while.');
  const hang2 = await waitDone('hang2', 8000);
  check('번역이 멈춘 뒤에도 다음 글이 번역됨', !!hang2 && hangul.test(hang2), hang2 ?? '');

  // 5. 기록 크기: 켜 둔 채로 오래 써도 제한을 넘지 않는다.
  await stopHelper();
  const small = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'krt-res-data-'));
  temporary.push(small);
  writeFileSync(join(small, 'settings.json'), JSON.stringify({ targetLanguage: 'ko' }));
  helper = startHelper('--data-dir', small, '--line-store-limit', '20');
  await sleep(1500);
  await evaluate(`for (let i = 0; i < 40; i++) addMsg('store' + i, 'Store check number ' + i + ' writes a brand new line into the translation record.'); sc.scrollTop = sc.scrollHeight; 1`);
  await waitDone('store39', 30000);
  const storeFile = join(small, 'lines-v2.jsonl');
  const countRows = () => readFileSync(storeFile, 'utf8').trim().split('\n').length;
  for (let i = 0; i < 300 && (await evaluate(`[...document.querySelectorAll('[id^="message-content-store"]')].filter((e) => e.nextElementSibling?.classList.contains('krt-line')).length`)) < 40; i++) await sleep(100);
  check('켜 둔 채로도 번역 기록이 제한을 넘지 않음', countRows() <= 25, `${countRows()}줄`);
  check('줄인 뒤에도 기록은 본인만 읽음', (statSync(storeFile).mode & 0o777) === 0o600);
  const before = countRows();
  await add('store40', 'One more line after the record was shortened should still be written to the file.');
  await waitDone('store40');
  await sleep(300);
  check('줄인 뒤에도 기록이 이어서 저장됨', countRows() !== before || countRows() <= 25, `${before} -> ${countRows()}줄`);

  // 6. 로그 크기와 권한.
  await stopHelper();
  const logged = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'krt-res-data-'));
  temporary.push(logged);
  writeFileSync(join(logged, 'settings.json'), JSON.stringify({ targetLanguage: 'ko' }));
  writeFileSync(join(logged, 'app.log'), 'x'.repeat(5000), { mode: 0o644 });
  helper = startHelper('--data-dir', logged, '--log-limit-bytes', '1000');
  const logFile = join(logged, 'app.log');
  for (let i = 0; i < 100 && !existsSync(`${logFile}.1`); i++) await sleep(100);
  check('로그가 제한을 넘으면 새 파일로 넘어감', statSync(logFile).size <= 1000 && existsSync(`${logFile}.1`), `${statSync(logFile).size}바이트`);
  check('로그는 본인만 읽음', (statSync(logFile).mode & 0o777) === 0o600 && existsSync(`${logFile}.1`) && (statSync(`${logFile}.1`).mode & 0o777) === 0o600);

  // 7. 긴 글: 2,000자가 넘어도 끝까지 번역하고, 잘리는 글은 잘렸다고 표시하며, 이모지 중간에서 잘려도 멈추지 않는다.
  await stopHelper();
  helper = startHelper();
  await sleep(1500);
  const longLines = Array.from({ length: 40 }, (_, i) => `Paragraph ${i} of this long notice explains how the render queue behaves after the update.`).join('\\n');
  await evaluate(`addMsg('long1', '${longLines}'); sc.scrollTop = sc.scrollHeight; 1`);
  const long1 = await waitDone('long1', 60000);
  check('2,000자가 넘는 글도 끝까지 번역함', !!long1 && long1.split('\n').length === 40, `${long1?.split('\n').length ?? 0}줄`);
  const hugeLines = Array.from({ length: 90 }, (_, i) => `Section ${i} of this enormous notice repeats how the render queue behaves after the update.`).join('\\n');
  await evaluate(`addMsg('huge1', '${hugeLines}'); sc.scrollTop = sc.scrollHeight; 1`);
  const huge1 = await waitDone('huge1', 60000);
  check('아주 긴 글은 잘렸다고 표시함', !!huge1 && huge1.trim().endsWith('…'), JSON.stringify(huge1?.slice(-12) ?? null));
  // 어느 길이에서 잘려도 이모지 한가운데가 걸리도록 영어 뒤에 이모지를 길게 붙인다.
  // 아래쪽 글부터 번역하므로 뒤이을 글을 위에 둬야, 깨진 글이 막으면 드러난다.
  await evaluate(`addMsg('emoji3', 'The next message must not wait for the broken one to time out.'); addMsg('emoji1', 'Some english text comes first here. ' + '😀'.repeat(4000)); addMsg('emoji2', 'Some english text comes first here!! ' + '😀'.repeat(4000)); sc.scrollTop = sc.scrollHeight; 1`);
  const emoji3 = await waitDone('emoji3', 8000);
  check('이모지 중간에서 잘려도 다음 글이 멈추지 않음', !!emoji3 && hangul.test(emoji3), emoji3 ?? '');

  // 8. Apple Intelligence가 잠깐 안 돼도 번역을 초기화하지 않는다.
  await stopHelper();
  const aiFile = join(data, 'fake-ai.txt');
  const emptyPacks = join(data, 'no-packs.json');
  writeFileSync(aiFile, 'available');
  writeFileSync(emptyPacks, '{}');
  helper = startHelper('--fake-ai', aiFile, '--fake-packs', emptyPacks);
  for (let i = 0; i < 50 && !logs.includes('번역 언어: ko'); i++) await sleep(100);
  logs = '';
  writeFileSync(aiFile, 'off');
  await sleep(3000);
  writeFileSync(aiFile, 'available');
  await sleep(3000);
  check('Apple Intelligence가 3초 끊겨도 번역을 멈추지 않음', !logs.includes('번역 언어: 없음'), logs.trim().split('\n').slice(-2).join(' / ').slice(0, 100));
  logs = '';
  writeFileSync(aiFile, 'notReady');
  await sleep(9000);
  check('모델 준비 중이면 꺼진 것으로 보지 않음', !logs.includes('번역 언어: 없음') && !logs.includes('(언어팩)'));
  writeFileSync(aiFile, 'off');
  let turnedOff = false;
  for (let i = 0; i < 150 && !turnedOff; i++) { await sleep(100); turnedOff = logs.includes('번역 언어: 없음'); }
  check('Apple Intelligence를 정말 끄면 알아챔', turnedOff);
  logs = '';
  writeFileSync(aiFile, 'available');
  let back = false;
  for (let i = 0; i < 80 && !back; i++) { await sleep(100); back = logs.includes('번역 언어: ko'); }
  check('다시 켜면 바로 이어짐', back);

  // 9. 끝낼 수밖에 없을 때는 안내하고 끝낸다.
  await stopHelper();
  helper = spawn(binary, ['--attach', String(port + 500), '--match', 'mock.html', '--script', join(root, 'Resources/inject.js'), '--data-dir', data], { stdio: ['ignore', 'ignore', 'pipe'] });
  let lastLogs = '';
  helper.stderr.on('data', (d) => { lastLogs += d.toString(); });
  await new Promise((r) => { const timer = setTimeout(r, 75000); helper.on('exit', () => { clearTimeout(timer); r(); }); });
  check('연결을 못 해서 끝날 때 안내함', lastLogs.includes('알림(시험): 디스코드에 연결하지 못했어요') && helper.exitCode === 1, lastLogs.trim().split('\n').slice(-1)[0]?.slice(0, 80));

  finished = true;
  socket.close();
} catch (error) {
  failures++;
  console.error('시험 중단:', error);
} finally {
  helper?.kill('SIGKILL');
  browser.kill();
  await sleep(500);
  rmSync(profile, { recursive: true, force: true });
  rmSync(data, { recursive: true, force: true });
  temporary.forEach((dir) => rmSync(dir, { recursive: true, force: true }));
}

console.log(failures ? `실패 ${failures}건` : '전부 통과');
process.exit(failures ? 1 : 0);
