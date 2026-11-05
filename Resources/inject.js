// 디스코드 화면의 외국어 메시지 아래에 번역 줄을 붙인다.
// 화면의 글을 읽어 맥 안의 번역 도우미에게 넘길 뿐, 디스코드 서버에는 아무 요청도 보내지 않는다.
(() => {
  if (window.__krt) return;

  const BINDING = '__krtTranslate';
  const MAX_TEXT = 6000; // 디스코드 글자 수 제한(Nitro 메시지 4,000자, 임베드 전체 6,000자)에 맞춘다.
  const MAX_CACHE = 5000;
  const STALL_MS = 30000;
  const PENDING_MS = 400; // 금방 끝나는 번역은 표시 없이 바로 보여 준다.
  const PENDING_TEXT = '번역 중…';
  const OFFLINE_MS = 6000; // 도우미 신호가 이만큼 끊기면 앱이 꺼진 것으로 본다.
  const RETRY_MS = 5000; // 번역이 실패하면 이 간격부터 늘려 가며 다시 시도한다.
  const RETRY_MAX_MS = 120000;
  const CONTENT = '[id^="message-content-"]';
  // 봇 공지와 링크 미리보기는 본문이 비고 글이 임베드에만 있다.
  const EMBED = ['embedTitle', 'embedDescription', 'embedFieldName', 'embedFieldValue']
    .map((part) => `[id^="message-accessories-"] article [class*="${part}"]`)
    .join(', ');
  const TARGET = `${CONTENT}, ${EMBED}`;
  const MENTION = '.mention, [class*="channelMention"], [class*="roleMention"]';
  // 가려진 글도 화면 구조에는 들어 있어서, 빼지 않으면 번역 줄에 그대로 드러난다.
  const SPOILER = '[class*="spoiler" i]';
  // 글 전체를 가린 묶음. 넓게 잡으면 채널 전체를 건너뛸 수 있어 이름을 좁혀 둔다.
  const SPOILER_BLOCK = '[class*="spoilerEmbed"], [class*="spoilerContainer"], [class*="spoilerWrapper"]';

  const cache = new Map(); // 원문 -> 번역문(건너뛰는 글은 null)
  const wanted = new Map(); // 번역을 기다리는 글 -> 메시지 요소
  let inflight = null; // 도우미가 지금 번역 중인 글
  let inflightEl = null; // 그 글이 있는 요소
  let inflightAt = 0;
  let lastRaw = new WeakMap(); // 메시지 요소 -> 마지막으로 처리한 글
  let held = null; // 스크롤 위치를 맞출 때 기준으로 삼은 메시지와 그 위치
  let timer = 0;
  let pendingTimer = 0;
  let nextKey = 0;
  let lastSeen = Date.now(); // 도우미 신호를 마지막으로 받은 시각
  let offline = false;
  const retries = new Map(); // 번역에 실패한 글 -> 시도 횟수와 다시 시도할 시각

  function addStyle() {
    if (document.getElementById('krt-style') || !document.documentElement) return;
    const style = document.createElement('style');
    style.id = 'krt-style';
    style.textContent = `
      .krt-line {
        color: var(--text-muted, #949ba4);
        font-size: 0.875em;
        line-height: 1.375;
        margin-top: 2px;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        user-select: text;
        grid-column: 1 / 1; /* 임베드는 격자라서 설명과 같은 칸에 놓는다. */
      }
      .krt-line.krt-pending { opacity: 0.7; }
      html.krt-off .krt-line { display: none; }
    `;
    document.documentElement.appendChild(style);
  }

  // 채널 멘션은 #을 아이콘으로 그려서 글자에는 이름만 남는다.
  function mentionLabel(el) {
    const name = el.textContent.trim();
    return /^[@#/]/.test(name) || !el.querySelector('svg') ? name : `#${name}`;
  }

  // 코드 블록, 링크, 이모지 이름은 번역하지 않는다. 문장 속 인라인 코드는 문맥이라 남긴다.
  // 멘션은 \u0002, \u0003으로 감싸 넘겨서 도우미가 번역하지 않고 그대로 되돌려 놓게 한다.
  function textOf(el) {
    const copy = el.cloneNode(true);
    copy.querySelectorAll('pre, time, img, [class*="timestamp"], [class*="edited"]').forEach((n) => n.remove());
    // 멘션처럼 감싸 넘겨 문장의 자리는 지키고 글자는 번역기에 보내지 않는다.
    copy.querySelectorAll(SPOILER).forEach((hidden) => hidden.replaceWith('\u0002███\u0003'));
    copy.querySelectorAll(MENTION).forEach((mention) => mention.replaceWith(`\u0002${mentionLabel(mention)}\u0003`));
    copy.querySelectorAll('a').forEach((a) => {
      if (/^https?:\/\//i.test(a.textContent.trim())) a.remove();
    });
    // 디스코드는 목록과 제목을 태그로 그려서, 글만 읽으면 번호와 줄바꿈이 사라진다.
    copy.querySelectorAll('ol').forEach((ol) => {
      let number = Number(ol.getAttribute('start')) || 1;
      ol.querySelectorAll(':scope > li').forEach((li) => li.prepend(`${number++}. `));
    });
    copy.querySelectorAll('ul > li').forEach((li) => li.prepend('• '));
    const BREAK = '\u0001';
    copy.querySelectorAll('li, h1, h2, h3, blockquote').forEach((block) => {
      block.before(BREAK);
      block.after(BREAK);
    });
    const text = copy.textContent
      .replace(/[\n\u0001]*\u0001[\n\u0001]*/g, '\n') // 태그 경계가 겹쳐도 줄바꿈은 하나만
      .replace(/[ \t]+/g, ' ')
      .split('\n')
      .filter((line) => !/^[\s,.;:]+$/.test(line) || !line.trim()) // 링크를 뺀 자리에 남은 문장 부호
      .join('\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
    if (text.length <= MAX_TEXT) return text;
    // 이모지 한가운데서 자르면 도우미가 글을 읽지 못한다. 줄임표는 줄 하나로 두어 번역하지 않고 그대로 보여 준다.
    return `${text.slice(0, MAX_TEXT).replace(/[\uD800-\uDBFF]$/, '').trimEnd()}\n…`;
  }

  function findScroller(el) {
    for (let node = el.parentElement; node; node = node.parentElement) {
      const overflow = getComputedStyle(node).overflowY;
      if ((overflow === 'auto' || overflow === 'scroll') && node.scrollHeight > node.clientHeight) return node;
    }
    return null;
  }

  // 번역 줄이 늘어나도 보던 메시지가 움직이지 않게 스크롤 위치를 맞춘다.
  function keepPosition(changes) {
    if (!changes.length) return;
    const scroller = findScroller(changes[0].el);
    if (!scroller) {
      changes.forEach((apply) => apply.run());
      return;
    }
    scroller.style.overflowAnchor = 'none';
    const atBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 8;
    const viewTop = scroller.getBoundingClientRect().top;
    const anchor = [...scroller.querySelectorAll(CONTENT)].find((m) => m.getBoundingClientRect().bottom > viewTop);
    // 스크롤 값은 픽셀 단위로 반올림돼 보정할 때마다 오차가 쌓인다.
    // 사용자가 스크롤하지 않았다면 새로 재지 않고 처음 잰 위치를 계속 기준으로 삼는다.
    const steady = held && held.anchor === anchor && held.scrollTop === scroller.scrollTop;
    const before = steady ? held.top : anchor ? anchor.getBoundingClientRect().top : 0;
    changes.forEach((apply) => apply.run());
    held = null;
    if (atBottom) {
      scroller.scrollTop = scroller.scrollHeight;
    } else if (anchor && anchor.isConnected) {
      scroller.scrollTop += anchor.getBoundingClientRect().top - before;
      held = { anchor, top: before, scrollTop: scroller.scrollTop };
    }
  }

  function lineOf(el) {
    const next = el.nextElementSibling;
    return next && next.classList.contains('krt-line') ? next : null;
  }

  // 번역 줄이 어느 요소 것인지 가리는 값. 임베드 글에는 id가 없어 따로 붙인다.
  function keyOf(el) {
    if (el.id) return el.id;
    if (!el.dataset.krtKey) el.dataset.krtKey = `krt-${++nextKey}`;
    return el.dataset.krtKey;
  }

  function changeFor(el, translated, pending = false) {
    const line = lineOf(el);
    if (!translated) return line ? { el, run: () => line.remove() } : null;
    const paint = (node) => {
      node.textContent = translated;
      node.classList.toggle('krt-pending', pending);
    };
    if (line) {
      const same = line.textContent === translated && line.classList.contains('krt-pending') === pending;
      return same ? null : { el, run: () => paint(line) };
    }
    return {
      el,
      run: () => {
        const added = document.createElement('div');
        added.className = 'krt-line';
        added.dataset.for = keyOf(el);
        added.dir = 'auto'; // 아랍어·히브리어로 옮기면 오른쪽에서 왼쪽으로 쓴다.
        paint(added);
        el.after(added);
      },
    };
  }

  function apply(el, translated, pending) {
    const change = changeFor(el, translated, pending);
    if (change) keepPosition([change]);
  }

  // 답장 위에 뜨는 인용은 다른 메시지의 번호를 달고 있다.
  function isQuoted(el) {
    if (el.closest('[id^="message-reply-context-"]')) return true;
    if (!el.id) return false; // 임베드 글
    const row = el.closest('li[id^="chat-messages-"]');
    if (!row) return false;
    return row.id.split('-').pop() !== el.id.replace('message-content-', '');
  }

  function scan() {
    timer = 0;
    addStyle();

    // 편집 등으로 원래 메시지와 떨어진 번역 줄은 지운다.
    const changes = [];
    document.querySelectorAll('.krt-line').forEach((line) => {
      const previous = line.previousElementSibling;
      if (!previous || (previous.id || previous.dataset.krtKey) !== line.dataset.for) {
        line.remove();
      } else if (line.classList.contains('krt-pending') && previous !== inflightEl) {
        changes.push({ el: previous, run: () => line.remove() }); // 더 기다리지 않는 번역의 표시
      }
    });

    wanted.clear();
    document.querySelectorAll(TARGET).forEach((el) => {
      if (!el.id && el.parentElement.closest(EMBED)) return; // 제목 안의 링크처럼 겹친 요소
      if (isQuoted(el) || el.closest(SPOILER_BLOCK)) return;
      const raw = el.textContent;
      const hasLine = !!lineOf(el);
      if (lastRaw.get(el) === raw && hasLine) return;
      const text = textOf(el);
      // 글자가 있는 글만 도우미에게 넘긴다. 어느 언어인지는 도우미가 판별한다.
      if (!/\p{L}.*\p{L}/su.test(text.replace(/\u0002[^\u0003]*\u0003/g, ''))) {
        lastRaw.set(el, raw);
        const change = changeFor(el, null);
        if (change) changes.push(change);
        return;
      }
      if (cache.has(text)) {
        lastRaw.set(el, raw);
        const change = changeFor(el, cache.get(text));
        if (change) changes.push(change);
      } else if (text === inflight) {
        inflightEl = el; // 번역 중에 다시 그려졌으면 새 요소에 붙인다.
      } else if (!(retries.get(text)?.at > Date.now())) {
        wanted.set(text, el);
      }
    });

    // 스크롤 영역별로 묶어 위치를 맞춘다.
    const byScroller = new Map();
    changes.forEach((change) => {
      const root = change.el.closest('ol, ul') || document.body;
      if (!byScroller.has(root)) byScroller.set(root, []);
      byScroller.get(root).push(change);
    });
    byScroller.forEach(keepPosition);

    pump();
  }

  // 메시지가 스크롤 영역에서 보이는 구간과 얼마나 떨어져 있는지. 보이면 0.
  function distanceToView(box, el, views) {
    const root = el.closest('ol, ul') || document.body;
    if (!views.has(root)) {
      const scroller = findScroller(el);
      views.set(root, scroller ? scroller.getBoundingClientRect() : { top: 0, bottom: window.innerHeight });
    }
    const view = views.get(root);
    if (box.bottom <= view.top) return view.top - box.bottom;
    if (box.top >= view.bottom) return box.top - view.bottom;
    return 0;
  }

  // 보이는 메시지 중 가장 아래(최신), 없으면 화면에 가장 가까운 메시지를 고른다.
  function nextText() {
    const views = new Map();
    let best = null;
    let bestDistance = Infinity;
    let bestTop = -Infinity;
    wanted.forEach((el, text) => {
      if (!el.isConnected) {
        wanted.delete(text);
        return;
      }
      const box = el.getBoundingClientRect();
      const distance = distanceToView(box, el, views);
      if (distance < bestDistance || (distance === bestDistance && box.top > bestTop)) {
        best = text;
        bestDistance = distance;
        bestTop = box.top;
      }
    });
    return best;
  }

  // 번역이 오래 걸리면 메시지 아래에 번역 중이라고 표시한다.
  function armPending() {
    clearTimeout(pendingTimer);
    pendingTimer = setTimeout(() => {
      if (inflightEl && inflightEl.isConnected && !lineOf(inflightEl)) apply(inflightEl, PENDING_TEXT, true);
    }, PENDING_MS);
  }

  // 한 번에 한 개만 맡긴다. 그래야 스크롤하거나 채널을 옮겨도 다음 번역을 지금 화면 기준으로 고른다.
  // 번역 중인 글이 화면에서 사라졌으면 끝나길 기다리지 않는다. 도우미는 새 글을 받으면 남은 줄을 멈춘다.
  function pump() {
    if (offline) return; // 도우미가 꺼져 있으면 보내도 답이 오지 않는다.
    const waiting = inflight !== null && inflightEl && inflightEl.isConnected;
    if (waiting && Date.now() - inflightAt < STALL_MS) return;
    inflight = null;
    inflightEl = null;
    if (typeof window[BINDING] !== 'function') return;
    const text = nextText();
    if (text === null) return;
    inflightEl = wanted.get(text);
    wanted.delete(text);
    inflight = text;
    inflightAt = Date.now();
    armPending();
    window[BINDING](JSON.stringify([text]));
  }

  function schedule() {
    if (!timer) timer = setTimeout(scan, 120);
  }

  function forgetInflight() {
    clearTimeout(pendingTimer);
    inflight = null;
    inflightEl = null;
  }

  // 도우미가 살아 있다는 신호. 꺼졌다 돌아왔으면 밀린 글을 이어서 맡긴다.
  function seen() {
    lastSeen = Date.now();
    if (!offline) return;
    offline = false;
    schedule();
  }

  // 디스코드는 켠 채 번역 앱만 꺼지면 답이 오지 않는다. 번역 중 표시를 지우고 다시 켜질 때까지 쉰다.
  setInterval(() => {
    if (offline || Date.now() - lastSeen < OFFLINE_MS) return;
    offline = true;
    forgetInflight();
    schedule();
  }, 1000);

  window.__krt = {
    done(rows) {
      seen();
      for (const [text, translated] of rows) {
        retries.delete(text);
        if (text === inflight) {
          if (inflightEl && inflightEl.isConnected) apply(inflightEl, translated);
          forgetInflight();
        }
        cache.set(text, translated);
      }
      while (cache.size > MAX_CACHE) cache.delete(cache.keys().next().value);
      pump();
      schedule();
    },
    // 긴 글은 끝난 줄부터 보여 준다.
    progress(text, partial) {
      seen();
      if (text !== inflight || !inflightEl || !inflightEl.isConnected) return;
      clearTimeout(pendingTimer);
      inflightAt = Date.now();
      apply(inflightEl, `${partial}\n${PENDING_TEXT}`, true);
    },
    // 일시적인 실패는 건너뛴 글과 달리 기억하지 않고 나중에 다시 시도한다. 끝난 줄이 있으면 그것만 보여 준다.
    failed(text, partial) {
      seen();
      const tries = (retries.get(text)?.tries ?? 0) + 1;
      const delay = Math.min(RETRY_MS * 2 ** (tries - 1), RETRY_MAX_MS);
      if (retries.size > 500) retries.clear();
      retries.set(text, { tries, at: Date.now() + delay });
      setTimeout(schedule, delay + 50);
      if (text === inflight) {
        if (inflightEl && inflightEl.isConnected) apply(inflightEl, partial);
        forgetInflight();
      }
      pump();
      schedule();
    },
    alive: seen,
    // 앱이 새로 연결됐다. 이전 앱이 맡았던 글의 답은 오지 않으니 기다리지 않는다.
    attached() {
      seen();
      forgetInflight();
      schedule();
    },
    // 용어집이나 번역 언어가 바뀌면 화면의 번역을 새로 받는다.
    reset() {
      forgetInflight();
      retries.clear();
      cache.clear();
      lastRaw = new WeakMap();
      schedule();
    },
  };

  new MutationObserver(schedule).observe(document, {
    childList: true,
    subtree: true,
    characterData: true,
  });

  // Ctrl+Shift+T: 번역 줄 켜기/끄기
  window.addEventListener('keydown', (event) => {
    if (event.ctrlKey && event.shiftKey && !event.metaKey && event.code === 'KeyT') {
      document.documentElement.classList.toggle('krt-off');
      event.preventDefault();
      event.stopPropagation();
    }
  }, true);

  schedule();
})();
