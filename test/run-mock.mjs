// 모의 화면 시험. 헤드리스 크롬에 번역 도우미를 붙여 동작을 확인한다.
// 실행 중인 디스코드는 건드리지 않는다. 사용법: node test/run-mock.mjs
import { spawn, spawnSync } from 'node:child_process';
import { appendFileSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const binary = process.env.KRT_TEST_BINARY || join(root, 'build/디스코드 번역.app/Contents/MacOS/DiscordTranslator');
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const port = 49000 + Math.floor(Math.random() * 1000);
const profile = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'krt-mock-'));
const data = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'krt-data-'));
const mock = pathToFileURL(join(here, 'mock.html')).href;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = spawn(chrome, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run', mock], { stdio: 'ignore' });
let helper;
let failures = 0;

function check(name, ok, detail = '') {
  console.log(`${ok ? '통과' : '실패'} | ${name}${detail ? ` | ${detail}` : ''}`);
  if (!ok) failures++;
}

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = pages.find((p) => p.type === 'page' && p.url.includes('mock.html'));
      if (page) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(250);
  }
  throw new Error('크롬에 연결하지 못함');
}

try {
  const socket = new WebSocket(await connect());
  await new Promise((r) => { socket.onopen = r; });
  let seq = 0;
  const waiting = new Map();
  socket.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); }
  };
  const evaluate = (expression) => new Promise((res, rej) => {
    const id = ++seq;
    waiting.set(id, (m) => {
      if (m.result?.exceptionDetails) rej(new Error(JSON.stringify(m.result.exceptionDetails)));
      else res(m.result?.result?.value);
    });
    socket.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }));
  });
  // 번역이 끝난 줄만 본다. 번역 중 표시와 중간 결과는 빼고 읽는다.
  const lineOf = (id) => evaluate(`(() => { const next = document.getElementById('message-content-${id}')?.nextElementSibling; return next?.classList.contains('krt-line') && !next.classList.contains('krt-pending') ? next.textContent : null; })()`);
  const waitLine = async (id, ms = 30000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const v = await lineOf(id);
      if (v) return v;
      await sleep(200);
    }
    return null;
  };

  // 번역 문구를 확인하는 시험이라 모델을 고정한다. KRT_TEST_MODEL=pack이면 언어팩 모델로 돈다.
  const packModel = process.env.KRT_TEST_MODEL === 'pack';
  writeFileSync(join(data, 'settings.json'), JSON.stringify({ targetLanguage: 'ko', usesLanguagePacks: packModel }));
  const startHelper = () => spawn(binary, ['--attach', String(port), '--match', 'mock.html', '--script', join(root, 'Resources/inject.js'), '--data-dir', data], { stdio: ['ignore', 'ignore', 'inherit'] });
  // 언어 판별: 확신할 수 없는 글은 번역하지 않는다.
  const detections = {
    'Anyone up for a raid tonight?': 'en', hello: 'en', 'nice one': 'en', lol: '건너뜀', ok: '건너뜀', gg: '건너뜀', 'idk tbh': '건너뜀',
    'ㅋㅋㅋ': 'ko', '감사합니다': 'ko', '이거 AI 모델 뭐 썼어요?': 'ko', 'render 왜 안 돼요': 'ko', 'Discord 서버 링크 좀': 'ko',
    'ありがとう': 'ja', '明日の夜、一緒にレイドに行きませんか？': 'ja', '草': '건너뜀', '谢谢': 'zh', '謝謝你們': 'zh',
    gracias: 'es', hola: '건너뜀', '¿Alguien quiere jugar esta noche con nosotros?': 'es', 'bonjour à tous': 'fr',
    'спасибо': 'ru', 'مرحبا بالجميع': 'ar', Sora: '건너뜀', 'Kling AI': '건너뜀', 'v2.1.0': '건너뜀',
  };
  const detected = spawnSync(binary, ['--self-test'], { input: Object.keys(detections).join('\n') + '\n', encoding: 'utf8' }).stdout.trim().split('\n');
  const wrong = Object.entries(detections).filter(([text, want], i) => !(detected[i] ?? '').startsWith(`${want}`));
  check('언어 판별이 기대와 같음', wrong.length === 0 && detected.length === Object.keys(detections).length, wrong.map(([t, w]) => `${t}: ${w}`).join(', '));

  const firstStart = Date.now();
  helper = startHelper();

  const hangul = /[가-힣]/;
  const en1 = await waitLine('en1');
  check('영어 메시지에 번역 줄이 붙음', !!en1 && hangul.test(en1), en1 ?? '');

  // 대량 메시지 번역이 끝나길 기다린다.
  const bulk = await waitLine('bulk39', 90000);
  const firstElapsed = Date.now() - firstStart;
  check('오래된 메시지도 번역됨', !!bulk && hangul.test(bulk), bulk ?? '');

  check('한국어는 건너뜀', (await lineOf('ko1')) === null);
  check('영어 단어가 섞인 한국어 글은 건너뜀', (await lineOf('koen1')) === null);
  for (const id of ['short1', 'short2', 'short3', 'short4']) check(`언어를 확신할 수 없는 짧은 글은 건너뜀: ${id}`, (await lineOf(id)) === null);
  const ja1 = await waitLine('ja1');
  check('일본어 언어팩이 있으면 일본어도 번역됨', !!ja1 && hangul.test(ja1), ja1 ?? '');
  const zh1 = await waitLine('zh1');
  check('중국어 언어팩이 있으면 중국어도 번역됨', !!zh1 && hangul.test(zh1), zh1 ?? '');
  if (packModel) {
    // 언어팩을 직접 골랐으면 받지 않은 언어는 옮기지 않는다(이 맥은 스페인어·프랑스어 언어팩이 없다).
    check('언어팩 모델: 받지 않은 스페인어는 건너뜀', (await lineOf('es1')) === null);
    check('언어팩 모델: 받지 않은 프랑스어는 건너뜀', (await lineOf('fr1')) === null);
  } else {
    const es1 = await waitLine('es1');
    check('Apple Intelligence: 스페인어가 번역됨', !!es1 && hangul.test(es1), es1 ?? '');
    const fr1 = await waitLine('fr1');
    check('Apple Intelligence: 프랑스어가 번역됨', !!fr1 && hangul.test(fr1), fr1 ?? '');
  }
  const mixed = (await waitLine('mixed1')) ?? '';
  const mixedRows = mixed.split('\n');
  check('여러 언어가 섞인 글은 줄마다 옮기고 한국어 줄은 그대로 둠', mixedRows.length === 3 && hangul.test(mixedRows[0]) && mixedRows[1] === '한국어 안내는 공지 채널에 있어요.' && hangul.test(mixedRows[2]) && !/[\u3040-\u30ff]/.test(mixed), JSON.stringify(mixedRows));
  check('링크만 있는 메시지는 건너뜀', (await lineOf('url1')) === null);
  check('코드 블록만 있는 메시지는 건너뜀', (await lineOf('code1')) === null);
  const mix = await waitLine('mix1');
  check('문장 속 인라인 코드가 번역문에 남음', !!mix && hangul.test(mix) && mix.includes('npm'), mix ?? '');
  check('답장 인용은 건너뜀', (await lineOf('rreply1')) === null);
  check('답장 본문은 번역됨', !!(await waitLine('reply1')));

  const xss = await waitLine('xss1');
  await sleep(300);
  check('메시지 속 태그가 실행되지 않음', (await evaluate('window.__xss')) === undefined, xss ?? '');
  check('번역 줄은 글자로만 들어감', (await evaluate(`document.getElementById('message-content-xss1').nextElementSibling.children.length`)) === 0);

  const list = await waitLine('list1');
  const rows = (list ?? '').split('\n');
  check('여러 줄 메시지의 줄 구조가 유지됨', rows.length === 6 && rows[1].startsWith('1.') && rows[2].startsWith('2.') && rows[3] === '' && rows[4] === '———', JSON.stringify(rows));

  const ol = await waitLine('ol1');
  const olRows = (ol ?? '').split('\n');
  check('태그로 그린 목록의 번호와 줄이 유지됨', olRows.length === 4 && olRows[1].startsWith('3.') && olRows[2].startsWith('4.') && olRows[3].startsWith('•'), JSON.stringify(olRows));

  // 맨 아래를 보다가 새 글이 오면 계속 맨 아래에 붙어 있어야 한다.
  await evaluate(`sc.scrollTop = sc.scrollHeight`);
  await sleep(300);
  await evaluate(`addMsg('new1', 'The new patch just dropped, go check it out!'); sc.scrollTop = sc.scrollHeight`);
  const new1 = await waitLine('new1');
  await sleep(300);
  check('새 메시지가 번역됨', !!new1 && hangul.test(new1), new1 ?? '');
  const gap = await evaluate(`sc.scrollHeight - sc.scrollTop - sc.clientHeight`);
  check('맨 아래에 계속 붙어 있음', gap < 8, `남은 거리 ${gap}px`);

  // 위쪽을 보는 중에 번역 줄이 하나씩 15번 늘어나도 보던 메시지가 움직이면 안 된다(반올림 오차 누적 방지).
  await evaluate(`
    for (let i = 0; i < 15; i++) {
      const el = document.getElementById('message-content-bulk' + i);
      el.nextElementSibling?.remove();
      el.textContent = 'Please keep the reading position stable while line ' + i + ' appears.';
    }
    window.__p = document.getElementById('message-content-bulk30');
    sc.scrollTop = window.__p.getBoundingClientRect().top - sc.getBoundingClientRect().top + sc.scrollTop;
  `);
  await sleep(100);
  const beforeTop = await evaluate(`window.__p.getBoundingClientRect().top`);
  await waitLine('bulk0', 30000); // 보이는 곳에서 가장 멀어 마지막에 끝난다.
  await sleep(400);
  const afterTop = await evaluate(`window.__p.getBoundingClientRect().top`);
  check('보던 위치가 유지됨', Math.abs(afterTop - beforeTop) <= 2, `${beforeTop} -> ${afterTop}`);

  // 수정된 메시지는 번역도 바뀐다.
  const editBefore = await waitLine('edit1');
  await evaluate(`document.getElementById('message-content-edit1').textContent = 'Never mind, the server is back online now.'`);
  let editAfter = editBefore;
  for (let i = 0; i < 40 && editAfter === editBefore; i++) { await sleep(200); editAfter = await lineOf('edit1'); }
  check('수정된 메시지의 번역이 바뀜', editAfter !== editBefore && hangul.test(editAfter ?? ''), `${editBefore} -> ${editAfter}`);

  // 스크롤로 메시지가 사라졌다 다시 그려져도 바로 번역 줄이 보인다.
  await evaluate(`window.__li = document.getElementById('chat-messages-1-en1'); window.__html = window.__li.innerHTML; window.__li.remove()`);
  await sleep(200);
  await evaluate(`const li = document.createElement('li'); li.id='chat-messages-1-en1'; li.innerHTML = window.__html.replace(/<div class="krt-line".*?<\\/div>/,''); list.prepend(li)`);
  await sleep(400);
  check('다시 그려진 메시지는 바로 번역됨', !!(await lineOf('en1')));

  // 메시지 내용 요소가 빠지면 번역 줄도 남지 않는다.
  await evaluate(`document.getElementById('message-content-new1').remove()`);
  await sleep(400);
  check('원문이 사라지면 번역 줄도 지워짐', (await evaluate(`document.querySelectorAll('.krt-line[data-for="message-content-new1"]').length`)) === 0);

  // 단축키로 번역 줄을 숨긴다.
  await evaluate(`window.dispatchEvent(new KeyboardEvent('keydown', { code: 'KeyT', ctrlKey: true, shiftKey: true, bubbles: true }))`);
  check('단축키로 숨김', (await evaluate(`getComputedStyle(document.querySelector('.krt-line')).display`)) === 'none');
  await evaluate(`window.dispatchEvent(new KeyboardEvent('keydown', { code: 'KeyT', ctrlKey: true, shiftKey: true, bubbles: true }))`);
  check('단축키로 다시 표시', (await evaluate(`getComputedStyle(document.querySelector('.krt-line')).display`)) !== 'none');

  // 멘션은 번역하지 않고 그대로 둔다.
  const m1 = await waitLine('m1');
  check('멘션과 채널 이름이 그대로 남음', !!m1 && hangul.test(m1) && m1.includes('@everyone') && m1.includes('#rules'), m1 ?? '');
  const m2 = await waitLine('m2');
  check('띄어쓰기 있는 닉네임이 그대로 남음', !!m2 && m2.includes('@Some User'), m2 ?? '');
  const m5 = await waitLine('m5');
  check('글자로 친 @everyone도 그대로 남음', !!m5 && m5.includes('@everyone'), m5 ?? '');
  const m6 = await waitLine('m6');
  check('표시와 똑같은 글이 있어도 멘션이 뒤바뀌지 않음', !!m6 && m6.includes('@u0') && m6.includes('@Real User'), m6 ?? '');
  check('멘션만 있는 메시지는 건너뜀', (await lineOf('m3')) === null);
  check('한국어 글의 영어 닉네임 때문에 번역하지 않음', (await lineOf('m4')) === null);
  check('제어 문자가 화면에 나오지 않음', (await evaluate(`[...document.querySelectorAll('.krt-line')].filter((l) => /[\\u0001-\\u0003]/.test(l.textContent)).length`)) === 0);

  // 용어집: 번역 뒤 치환, 번역 전 속어 풀이, 저장하면 바로 적용.
  const g1 = await waitLine('g1');
  check('용어집이 번역 뒤에 적용됨', !!g1 && g1.includes('동시 생성'), g1 ?? '');
  const g2 = await waitLine('g2');
  check('용어집이 번역 전 속어를 풀어 줌', !!g2 && !g2.includes('힘들'), g2 ?? '');
  // 모델마다 옮기는 말이 달라서, 그 모델이 실제로 쓰는 말로 규칙을 건다.
  appendFileSync(join(data, 'glossary.txt'), `\n${packModel ? '새 패치' : '새로운 패치'} = 새 패치 시험\n`);
  let m5After = m5;
  for (let i = 0; i < 40 && !m5After?.includes('새 패치 시험'); i++) { await sleep(200); m5After = await lineOf('m5'); }
  check('용어집을 고치면 켜 둔 채로 화면에 반영됨', !!m5After?.includes('새 패치 시험'), m5After ?? '');

  // 보이는 메시지부터 번역한다. 번호가 클수록 맨 아래(보이는 쪽)에 있다.
  await evaluate(`(() => {
    window.__order = [];
    const original = window.__krtTranslate;
    window.__krtTranslate = (payload) => { window.__order.push(JSON.parse(payload)[0]); return original(payload); };
    for (let i = 0; i < 24; i++) addMsg('p' + i, 'Queue check number ' + i + ' for the render settings page.');
    sc.scrollTop = sc.scrollHeight;
  })()`);
  const numberOf = (text) => Number(text.match(/number (\d+)/)?.[1]);
  const orderNow = () => evaluate(`window.__order`);
  // 앞 시험(용어집 변경)에서 남은 재번역이 먼저 나갈 수 있으니 이 시험의 메시지만 센다.
  const queued = async () => (await orderNow()).filter((text) => text.startsWith('Queue check')).map(numberOf);
  for (let i = 0; i < 100 && (await queued()).length < 3; i++) await sleep(100);
  const firstThree = (await queued()).slice(0, 3);
  check('화면 맨 아래 메시지부터 번역함', firstThree.length === 3 && firstThree.every((n) => n >= 18), firstThree.join(', '));

  // 스크롤하면 다음 번역부터 새로 보이는 곳으로 옮겨 간다.
  const seenAtScroll = await evaluate(`(() => {
    document.getElementById('message-content-p3').scrollIntoView({ block: 'center' });
    return window.__order.length;
  })()`);
  for (let i = 0; i < 100 && (await orderNow()).length <= seenAtScroll; i++) await sleep(100);
  const afterScroll = numberOf((await orderNow())[seenAtScroll]);
  check('스크롤한 곳을 먼저 번역함', Math.abs(afterScroll - 3) <= 4, String(afterScroll));

  // 번역 전에 사라진 메시지(채널 이동 등)는 번역하지 않는다.
  const removed = await evaluate(`(() => {
    const asked = new Set(window.__order);
    const gone = [];
    for (let i = 10; i < 16; i++) {
      const el = document.getElementById('message-content-p' + i);
      if (asked.has(el.textContent)) continue;
      gone.push(el.textContent);
      el.closest('li').remove();
    }
    return gone;
  })()`);
  await waitLine('p0', 30000);
  await waitLine('p17', 30000);
  await waitLine('p9', 30000);
  await sleep(800);
  const asked = await orderNow();
  check('사라진 메시지는 번역하지 않음', removed.length > 0 && removed.every((text) => !asked.includes(text)), `사라진 ${removed.length}개`);

  // 본문 없이 임베드에만 글이 있는 메시지(봇 공지, 링크 미리보기)도 번역한다.
  const embedLine = (id, part) => evaluate(`(() => {
    const next = document.querySelector('#message-accessories-${id} div[class*="${part}"]')?.nextElementSibling;
    return next?.classList.contains('krt-line') && !next.classList.contains('krt-pending') ? next.textContent : null;
  })()`);
  const waitEmbed = async (id, part, ms = 20000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const value = await embedLine(id, part);
      if (value) return value;
      await sleep(200);
    }
    return null;
  };
  await evaluate(`
    addEmbed('emb1', 'Patch notes for this week',
      'We fixed the export bug that many of you reported.\\nThe render queue now keeps its order after a restart.',
      '<div class="embedFieldName_x">Known issues</div><div class="embedFieldValue_x">Audio sync can still drift on very long videos.</div>');
    addEmbed('emb2', '이번 주 패치 노트', '많은 분이 알려 주신 내보내기 오류를 고쳤어요.');
    sc.scrollTop = sc.scrollHeight;
  `);
  const embedTitle = await waitEmbed('emb1', 'embedTitle');
  check('임베드 제목이 번역됨', !!embedTitle && hangul.test(embedTitle), embedTitle ?? '');
  const embedBody = await waitEmbed('emb1', 'embedDescription');
  check('임베드 설명이 줄 구조를 지켜 번역됨', !!embedBody && hangul.test(embedBody) && embedBody.split('\n').length === 2, embedBody ?? '');
  const embedField = await waitEmbed('emb1', 'embedFieldValue');
  check('임베드 항목이 번역됨', !!embedField && hangul.test(embedField), embedField ?? '');
  check('제목 링크에 번역 줄이 겹치지 않음', (await evaluate(`document.querySelectorAll('#message-accessories-emb1 a .krt-line, #message-accessories-emb1 [class*="embedTitle"] > .krt-line').length`)) === 0);
  await sleep(600);
  check('한국어 임베드는 건너뜀', (await evaluate(`document.querySelectorAll('#message-accessories-emb2 .krt-line').length`)) === 0);
  const placed = await evaluate(`(() => {
    const body = document.querySelector('#message-accessories-emb1 div[class*="embedDescription"]');
    const line = body.nextElementSibling;
    const a = body.getBoundingClientRect(), b = line.getBoundingClientRect();
    return { isLine: line.classList.contains('krt-line'), below: b.top >= a.bottom - 1, left: Math.abs(a.left - b.left) < 1, width: Math.abs(a.width - b.width) < 1 };
  })()`);
  check('임베드 번역 줄이 설명 바로 아래 같은 칸에 놓임', placed.isLine && placed.below && placed.left && placed.width, JSON.stringify(placed));

  // 긴 글은 번역 중임을 보여 주고, 끝난 줄부터 나온다.
  const longText = (tag, count) => Array.from({ length: count }, (_, i) => `Section ${tag} ${i} explains that the rendering pipeline now handles large projects and keeps review comments.`).join('\\n');
  await evaluate(`(() => {
    window.__states = [];
    new MutationObserver(() => {
      const line = document.querySelector('#chat-messages-1-long1 .krt-line');
      if (!line) return;
      const state = (line.classList.contains('krt-pending') ? 'P:' : 'F:') + line.textContent;
      if (window.__states.at(-1) !== state) window.__states.push(state);
    }).observe(document, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['class'] });
    addMsg('long1', '${longText('a', 7)}');
    sc.scrollTop = sc.scrollHeight;
  })()`);
  const long1 = await waitLine('long1', 30000);
  const states = await evaluate(`window.__states`);
  // 언어팩은 표시가 뜨기 전에 첫 줄이 끝나므로, 첫 화면이 중간 결과면 된다.
  check('긴 글을 번역하는 동안 번역 중이라고 표시함', packModel ? states[0]?.startsWith('P:') && states[0].endsWith('번역 중…') : states[0] === 'P:번역 중…', JSON.stringify(states[0]?.slice(-12) ?? null));
  const partials = states.filter((s) => s.startsWith('P:') && hangul.test(s.replace('번역 중…', '')));
  check('끝난 줄부터 차례로 보여 줌', partials.length >= 3, `중간 결과 ${partials.length}번`);
  check('다 끝나면 표시가 사라지고 전체 번역이 남음', !!long1 && long1.split('\n').length === 7 && !long1.includes('번역 중') && states.at(-1)?.startsWith('F:'), `${long1?.split('\n').length ?? 0}줄`);

  // 채널을 옮겨 번역 중이던 글이 사라지면 남은 줄을 기다리지 않는다.
  const waitPending = async (id, ms = 4000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (await evaluate(`!!document.querySelector('#chat-messages-1-${id} .krt-pending')`)) return true;
      await sleep(50);
    }
    return false;
  };
  await evaluate(`addMsg('long2', '${longText('b', 15)}'); sc.scrollTop = sc.scrollHeight`);
  await waitPending('long2');
  await evaluate(`document.getElementById('chat-messages-1-long2').remove(); addMsg('after1', 'The next channel should not wait for the old message.'); sc.scrollTop = sc.scrollHeight`);
  const movedAt = Date.now();
  const after1 = await waitLine('after1', 30000);
  const waited = Date.now() - movedAt;
  check('채널을 옮기면 이전 글의 남은 줄을 기다리지 않음', !!after1 && waited < 3000, `${waited}ms`);

  // 번역 중에 메시지가 다시 그려져도 새 요소에 번역이 붙는다.
  await evaluate(`addMsg('long3', '${longText('c', 4)}'); sc.scrollTop = sc.scrollHeight`);
  await waitPending('long3');
  await evaluate(`(() => {
    const old = document.getElementById('message-content-long3');
    const copy = old.cloneNode(true);
    old.nextElementSibling?.remove();
    old.replaceWith(copy);
  })()`);
  const long3 = await waitLine('long3', 30000);
  check('번역 중에 다시 그려진 메시지에도 번역이 붙음', !!long3 && hangul.test(long3) && long3.split('\n').length === 4, `${long3?.split('\n').length ?? 0}줄`);
  check('번역 중 표시가 남지 않음', (await evaluate(`document.querySelectorAll('.krt-pending').length`)) === 0);

  // 다시 켜면 저장된 번역을 그대로 쓴다.
  const storeFile = join(data, 'lines-v2.jsonl');
  const stored = readFileSync(storeFile, 'utf8');
  const storedRows = stored.trim().split('\n').length;
  check('번역 기록이 저장됨', storedRows > 40, `${storedRows}줄`);
  check('번역 기록에 원문이 없음', !stored.includes('Anyone up for a raid'));
  check('번역 기록은 본인만 읽을 수 있음', (statSync(storeFile).mode & 0o777) === 0o600);
  helper.kill();
  await sleep(500);
  await evaluate('location.reload()');
  await sleep(800);
  const secondStart = Date.now();
  helper = startHelper();
  const bulkAgain = await waitLine('bulk39', 30000);
  const secondElapsed = Date.now() - secondStart;
  check('다시 켜면 저장된 번역이 바로 나옴', !!bulkAgain && secondElapsed < firstElapsed / 3, `처음 ${firstElapsed}ms, 다시 켠 뒤 ${secondElapsed}ms`);
  await sleep(500);
  const rowsAgain = readFileSync(storeFile, 'utf8').trim().split('\n').length;
  check('다시 켠 뒤 번역기를 또 부르지 않음', rowsAgain === storedRows, `${storedRows} -> ${rowsAgain}줄`);

  // 번역 언어를 바꾸면 켜 둔 채로 화면의 번역이 그 언어로 바뀐다.
  const kana = /[\u3040-\u30ff]/;
  const setLanguage = (id) => writeFileSync(join(data, 'settings.json'), JSON.stringify({ targetLanguage: id, usesLanguagePacks: packModel }));
  const waitText = async (id, test, ms = 30000) => {
    const end = Date.now() + ms;
    let value = null;
    while (Date.now() < end) {
      value = await lineOf(id);
      if (value && test(value)) return value;
      await sleep(200);
    }
    return value;
  };
  await evaluate(`for (let i = 0; i < 8; i++) addMsg('lang' + i, 'Switching the language while line ' + i + ' is still being translated.'); sc.scrollTop = sc.scrollHeight`);
  await sleep(300); // 일부는 한국어로 번역 중일 때 언어를 바꾼다.
  setLanguage('ja');
  const switchedAt = Date.now();
  // en1은 화면에서 가장 멀어 다른 메시지를 다 번역한 뒤에 바뀐다(약 30초).
  const en1Japanese = await waitText('en1', (v) => kana.test(v), 60000);
  check('언어를 바꾸면 켜 둔 채로 번역이 바뀜', !!en1Japanese && kana.test(en1Japanese), `${Date.now() - switchedAt}ms ${en1Japanese ?? ''}`);
  const langLines = [];
  for (let i = 0; i < 8; i++) langLines.push(await waitText('lang' + i, (v) => !hangul.test(v)));
  check('바꾸기 전에 시작한 번역이 새 언어에 섞이지 않음', langLines.every((v) => v && !hangul.test(v)), langLines[0] ?? '');
  check('번역 줄의 글 방향을 언어에 맞춤', (await evaluate(`document.querySelector('.krt-line').dir`)) === 'auto');

  const rowsBeforeBack = readFileSync(storeFile, 'utf8').trim().split('\n').length;
  setLanguage('ko');
  const en1Korean = await waitText('en1', (v) => hangul.test(v));
  check('이전 언어로 돌아오면 다시 번역됨', !!en1Korean && hangul.test(en1Korean), en1Korean ?? '');
  await sleep(500);
  const koStart = await lineOf('bulk39');
  check('이전 언어의 기록을 다시 씀', !!koStart && hangul.test(koStart), koStart ?? '');
  check('언어마다 기록이 따로 쌓임', rowsBeforeBack > storedRows, `${storedRows} -> ${rowsBeforeBack}줄`);

  // 영어도 번역될 언어로 고를 수 있다. 영어 글은 건너뛰고 다른 언어를 영어로 옮긴다.
  const latinOnly = (v) => /[A-Za-z]{3}/.test(v) && !hangul.test(v);
  setLanguage('en');
  const ko1English = await waitText('ko1', latinOnly, 60000);
  check('영어로 번역하게 하면 한국어 글이 영어로 번역됨', !!ko1English && latinOnly(ko1English), ko1English ?? '');
  for (let i = 0; i < 100 && (await lineOf('en1')) !== null; i++) await sleep(200);
  check('영어로 번역하게 하면 영어 글은 건너뜀', (await lineOf('en1')) === null);

  socket.close();
} catch (error) {
  failures++;
  console.error('시험 중단:', error);
} finally {
  helper?.kill();
  browser.kill();
  await sleep(500);
  rmSync(profile, { recursive: true, force: true });
  rmSync(data, { recursive: true, force: true });
}

console.log(failures ? `실패 ${failures}건` : '전부 통과');
process.exit(failures ? 1 : 0);
