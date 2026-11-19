// content.js — EnglishWriter 浏览器侧：取文本 → 本地 API 查 → 画线 → 卡片 → 直接改 DOM
//
// 关键设计：
//   · 文本与矩形全部来自 DOM（Range.getClientRects），完全不依赖 AX —— Chromium 的 AX 写回实测不可用
//   · 下划线画在 shadow DOM 里的绝对定位覆盖层，不污染宿主页面样式
//   · 接受 = 真的改 DOM（contenteditable 用 Range，input/textarea 用原生 setter + input 事件）
//   · 撤销 = 保留上一次接受的范围与原词，反向改回去
//   · token 从 chrome.storage 取，没有就静默待命（不报错骚扰用户）
//   · 调试证据：window.__EW_DEBUG = {lastEdits, lastRects, engine, elapsedMs, accepted, undone}

(() => {
  if (window.__EW_LOADED__) return;
  window.__EW_LOADED__ = true;

  const API = 'http://127.0.0.1:17817';
  const DEBOUNCE = 800;        // 模型检查（贵，慢一点）
  const FAST_DEBOUNCE = 150;   // 本地即时检查（要快）
  let token = null;
  let host = null, root = null, layer = null, card = null;
  // 划线与建议的对应关系（键盘 ←/→ 切换要用同一份，不能靠再查一遍 DOM）
  let anchors = [];
  let activeIndex = -1;
  let lastTarget = null;
  let lastAccept = null;
  let ignoreList = new Set();

  window.__EW_DEBUG = { ready: false, lastEdits: [], lastRects: [], engine: '', elapsedMs: 0,
                        accepted: 0, undone: 0, notes: [], rectSource: 'none', lastTarget: null };

  function readToken(cb) {
    chrome.storage.local.get(['token', 'ignore'], (v) => {
      token = v.token || null;
      if (Array.isArray(v.ignore)) v.ignore.forEach(k => ignoreList.add(k));
      cb && cb(token);
    });
  }
  readToken((t) => {
    window.__EW_DEBUG.ready = true;
    window.__EW_DEBUG.notes.push(t ? 'token ok' : 'no token');
  });
  // 用户在扩展选项里后填 token / 改 token，页面不用刷新也能生效
  if (chrome.storage.onChanged) {
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === 'local' && changes.token) {
        token = changes.token.newValue || null;
        window.__EW_DEBUG.notes.push(token ? 'token updated' : 'token cleared');
      }
    });
  }

  // ---------- 覆盖层 ----------
  function ensureLayer() {
    if (host) return;
    host = document.createElement('div');
    host.id = '__ew_host__';
    host.style.cssText = 'all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647';
    root = host.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    style.textContent = `
      .u{position:absolute;pointer-events:auto;cursor:pointer;background:transparent;border:0;padding:0;margin:0}
      .u i{position:absolute;left:0;right:0;bottom:-1px;height:0;display:block}
      .u.spell i{background:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='6' height='3'><path d='M0 2 Q1.5 0 3 2 T6 2' fill='none' stroke='%23d93025' stroke-width='1'/></svg>") repeat-x bottom;height:3px;bottom:-3px}
      .u.gram i{background:#d93025;height:1.5px}
      .u.clar i{background:#2f6df6;height:1px}
      .u.style i{background:#9a6a00;height:1px;border-top:1px dashed #9a6a00;background:none}
      .card{position:absolute;pointer-events:auto;width:320px;background:#fff;border:1px solid #e3e6ea;border-radius:10px;
            box-shadow:0 8px 24px rgba(20,24,32,.16);font:13px -apple-system,"PingFang SC",sans-serif;color:#15171c;overflow:hidden}
      .card .hd{padding:8px 12px;border-bottom:1px solid #eef0f3;font-size:11px;color:#8a93a0}
      .card .bd{padding:10px 12px;line-height:1.5}
      .card .orig{color:#c0264b;text-decoration:line-through}
      .card .rep{color:#17794a;font-weight:600}
      .card .rs{margin-top:6px;color:#56606e;font-size:12px}
      .card .ft{display:flex;gap:8px;padding:10px 12px;border-top:1px solid #eef0f3}
      .card button{font:12px -apple-system;padding:5px 10px;border-radius:6px;border:1px solid #e3e6ea;background:#fff;cursor:pointer}
      .card button.pri{background:#2f6df6;border-color:#2f6df6;color:#fff}
      .card button:hover{filter:brightness(.97)}
      .card .rw{padding:0 12px 10px;color:#56606e;font-size:12px}
      .card .rw:empty{display:none}
      .card .rwi{display:flex;gap:8px;align-items:flex-start;padding:6px 0;border-top:1px solid #f1f3f5}
      .card .rwt{flex:1;line-height:1.45}
    `;
    root.appendChild(style);
    layer = document.createElement('div');
    layer.className = 'uls';          // 只放划线；卡片直接挂 root，重画时不会被清掉
    root.appendChild(layer);
    document.documentElement.appendChild(host);
  }

  // ---------- 取焦点可编辑元素 ----------
  function editable(el) {
    if (!el) return null;
    if (el.tagName === 'TEXTAREA') return el;
    if (el.tagName === 'INPUT' && /^(text|search|url|email)$/i.test(el.type)) return el;
    if (el.isContentEditable) return el;
    return null;
  }

  function textOf(el) {
    return el.isContentEditable ? el.innerText : el.value;
  }

  // 光标所在句（与原生同一口径：. ! ? \n）
  function sentenceAround(text, caret) {
    let start = 0;
    for (let i = caret - 1; i >= 0; i--) {
      if ('.!?\n'.includes(text[i])) { start = i + 1; break; }
    }
    let end = text.length;
    for (let i = caret; i < text.length; i++) {
      if ('.!?\n'.includes(text[i])) { end = i + 1; break; }
    }
    // 光标正停在句末标点之后（刚打完一句的常态）→ 上面切出来是空串，回退取上一句
    if (text.slice(start, end).trim().length === 0 && start > 0) {
      end = start;
      start = 0;
      for (let i = end - 2; i >= 0; i--) {
        if ('.!?\n'.includes(text[i])) { start = i + 1; break; }
      }
    }
    return { start, end, text: text.slice(start, end) };
  }

  function caretOf(el) {
    if (el.isContentEditable) {
      const s = window.getSelection();
      if (!s || s.rangeCount === 0) return textOf(el).length;
      const r = s.getRangeAt(0).cloneRange();
      r.selectNodeContents(el);
      r.setEnd(s.getRangeAt(0).endContainer, s.getRangeAt(0).endOffset);
      return r.toString().length;
    }
    return el.selectionStart ?? textOf(el).length;
  }

  // ---------- 矩形：DOM 侧自己算，不依赖任何宿主接口 ----------
  // contenteditable 用 Range；input/textarea 用镜像 div（同字体、同 padding、同宽）
  function setRectSource(s) { window.__EW_DEBUG.rectSource = s; }

  function rangeRects(container, start, end) {
    const range = rangeForOffsets(container, start, end);
    if (!range) return [];
    const out = [];
    for (const r of range.getClientRects()) {
      if (r.width > 0 && r.height > 0) out.push({ x: r.left, y: r.top, w: r.width, h: r.height });
    }
    return out;
  }

  // contenteditable 兜底：Chromium 的 AX 侧不给 AXBoundsForRange 矩形，DOM 侧也不是所有结构
  // 都能一次 Range.getClientRects 出矩形（跨 <br>、空行、嵌套段落都会返回空）。
  // 这里逐个文本节点算：落在目标区间里的节点各自取 rect，再并起来；仍为 0 才退元素级 rect。
  function childUnionRects(el, absStart, length) {
    const targetEnd = absStart + length;
    const out = [];
    let acc = 0;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
    let n;
    while ((n = walker.nextNode())) {
      const len = n.nodeValue.length;
      const nodeStart = acc, nodeEnd = acc + len;
      acc = nodeEnd;
      if (nodeEnd <= absStart || nodeStart >= targetEnd) continue;
      const r = document.createRange();
      try {
        r.setStart(n, Math.max(0, absStart - nodeStart));
        r.setEnd(n, Math.min(len, targetEnd - nodeStart));
      } catch (e) { continue; }
      for (const rect of r.getClientRects()) {
        if (rect.width > 0 && rect.height > 0) out.push({ x: rect.left, y: rect.top, w: rect.width, h: rect.height });
      }
    }
    if (out.length) { setRectSource('child-union'); return out; }
    const box = el.getBoundingClientRect();
    if (box.width > 0 && box.height > 0) { setRectSource('element'); return [{ x: box.left, y: box.top, w: box.width, h: box.height }]; }
    return [];
  }

  function rectsFor(el, absStart, length) {
    if (el.isContentEditable) {
      const primary = rangeRects(el, absStart, absStart + length);
      if (primary.length) { setRectSource('range'); return primary; }
      const fallback = childUnionRects(el, absStart, length);
      if (window.__EW_DEBUG.rectSource !== 'element') setRectSource(fallback.length ? 'child-union' : 'none');
      return fallback;
    }
    const mirror = mirrorFor(el);
    if (!mirror) return [];
    const range = rangeForOffsets(mirror, absStart, absStart + length);
    if (!range) return [];
    const box = el.getBoundingClientRect();
    const mbox = mirror.getBoundingClientRect();
    const dx = box.left - mbox.left + (el.offsetWidth - el.clientWidth);
    const dy = box.top - mbox.top + (el.offsetHeight - el.clientHeight);
    const out = [];
    for (const r of range.getClientRects()) {
      if (r.width > 0 && r.height > 0) out.push({ x: r.left + dx - (el.offsetWidth - el.clientWidth), y: r.top + dy - (el.offsetHeight - el.clientHeight), w: r.width, h: r.height });
    }
    setRectSource('mirror');
    return out;
  }

  function rangeForOffsets(container, start, end) {
    let acc = 0, startNode = null, startOff = 0, endNode = null, endOff = 0;
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, null);
    let n;
    while ((n = walker.nextNode())) {
      const len = n.nodeValue.length;
      if (startNode === null && acc + len >= start) { startNode = n; startOff = start - acc; }
      if (acc + len >= end) { endNode = n; endOff = end - acc; break; }
      acc += len;
    }
    if (!startNode || !endNode) return null;
    const r = document.createRange();
    try { r.setStart(startNode, Math.min(startOff, startNode.nodeValue.length)); } catch { return null; }
    try { r.setEnd(endNode, Math.min(endOff, endNode.nodeValue.length)); } catch { return null; }
    return r;
  }

  let mirrorCache = new WeakMap();
  function mirrorFor(el) {
    let m = mirrorCache.get(el);
    if (m && m.parentNode) { syncMirror(el, m); return m; }
    m = document.createElement('div');
    const cs = getComputedStyle(el);
    for (const p of ['fontFamily','fontSize','fontWeight','lineHeight','letterSpacing','padding','border','boxSizing','whiteSpace','wordWrap','wordBreak','width']) {
      m.style[p] = cs[p];
    }
    m.style.position = 'absolute';
    m.style.visibility = 'hidden';
    m.style.left = '-99999px';
    m.style.top = '0';
    m.style.height = 'auto';
    m.style.overflow = 'hidden';
    document.body.appendChild(m);
    syncMirror(el, m);
    mirrorCache.set(el, m);
    return m;
  }
  function syncMirror(el, m) {
    m.style.width = getComputedStyle(el).width;
    m.textContent = el.value;
    m.style.whiteSpace = el.tagName === 'INPUT' ? 'pre' : 'pre-wrap';
  }

  // ---------- 画线 ----------
  function clearUnderlines() {
    if (layer) layer.innerHTML = '';   // 只清划线
    hideCard();
    window.__EW_DEBUG.lastRects = [];
  }

  function drawUnderlines(el, edits, sentStart) {
    ensureLayer();
    layer.innerHTML = '';              // 只清划线，卡片保留
    window.__EW_DEBUG.lastTarget = {
      tag: el.tagName, id: el.id || '',
      contenteditable: !!el.isContentEditable,
      textLen: textOf(el).length
    };
    const rects = [];
    anchors = [];
    activeIndex = -1;
    edits.forEach((e, ei) => {
      const rs = rectsFor(el, sentStart + e.start, e.length);
      const cls = e.type === 'spelling' ? 'spell' : (e.type === 'clarity' ? 'clar' : (e.type === 'style' ? 'style' : 'gram'));
      rs.forEach((r) => {
        const d = document.createElement('div');
        d.className = 'u ' + cls;
        d.style.left = r.x + 'px';
        d.style.top = r.y + 'px';
        d.style.width = r.w + 'px';
        d.style.height = r.h + 'px';
        const line = document.createElement('i');
        d.appendChild(line);
        anchors.push({ el: d, edit: e });
        // 单击划线处 → 直接弹卡片（爹地 11-19：悬停那套是复杂化，点了才出才是他要的）
        d.onclick = (ev) => { ev.preventDefault(); ev.stopPropagation(); showCard(e, d, ei); };
        layer.appendChild(d);
        rects.push({ ...r, type: e.type });
      });
    });
    window.__EW_DEBUG.lastRects = rects;
  }

  // ---------- 卡片 ----------
  function hideCard() {
    if (card && card.parentNode) card.remove();
    card = null;
  }

  function showCard(edit, anchor, index) {
    if (typeof index === 'number') activeIndex = index;
    ensureLayer();
    hideCard();
    card = document.createElement('div');
    card.className = 'card';
    const typeCn = { spelling: '拼写', grammar: '语法', clarity: '清晰度', style: '风格' }[edit.type] || '语法';
    card.innerHTML = `
      <div class="hd">EnglishWriter · ${typeCn}</div>
      <div class="bd">
        <span class="orig"></span> → <span class="rep"></span>
        <div class="rs"></div>
      </div>
      <div class="ft">
        <button class="pri" data-a="accept">接受</button>
        <button data-a="ignore">忽略</button>
        <button data-a="dict">加入词典</button>
        <button data-a="rewrite">改写</button>
        <button data-a="close">关闭</button>
      </div>
      <div class="rw"></div>`;
    card.querySelector('.orig').textContent = edit.original;
    card.querySelector('.rep').textContent = edit.replacement;
    card.querySelector('.rs').textContent = edit.reason || '';
    const box = anchor.getBoundingClientRect();
    let left = box.left, top = box.bottom + 6;
    if (left + 320 > window.innerWidth - 8) left = Math.max(8, window.innerWidth - 328);
    if (top + 180 > window.innerHeight - 8) top = Math.max(8, box.top - 190);
    card.style.left = left + 'px';
    card.style.top = top + 'px';
    card.addEventListener('mousedown', (ev) => ev.stopPropagation());
    card.querySelector('[data-a=accept]').onclick = () => { accept(edit); hideCard(); };
    card.querySelector('[data-a=ignore]').onclick = () => { ignoreOnce(edit); hideCard(); };
    card.querySelector('[data-a=dict]').onclick = () => { ignore(edit); hideCard(); };
    card.querySelector('[data-a=close]').onclick = () => hideCard();
    card.querySelector('[data-a=rewrite]').onclick = async () => {
      const box = card.querySelector('.rw');
      box.textContent = '正在改写…';
      const sent = sentenceAround(textOf(lastTarget), (window.__EW_DEBUG.sentStart || 0) + edit.start).text || edit.original;
      try {
        const r = await fetch(API + '/v1/rewrite', {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-ew-token': token },
          body: JSON.stringify({ text: sent })
        });
        const d = await r.json();
        if (d.error === 'model-not-configured') { box.textContent = '改写需要先在设置里配好模型'; return; }
        if (!d.candidates || !d.candidates.length) { box.textContent = '没有更好的写法'; return; }
        box.innerHTML = '';
        d.candidates.slice(0, 3).forEach((c) => {
          const it = document.createElement('div');
          it.className = 'rwi';
          const t = document.createElement('div');
          t.className = 'rwt';
          t.textContent = c.text;
          const b = document.createElement('button');
          b.textContent = '用这句';
          b.onclick = () => { replaceSegment(sent, c.text); hideCard(); };
          it.appendChild(t); it.appendChild(b);
          box.appendChild(it);
        });
      } catch (e) {
        box.textContent = '改写失败：' + e.message;
      }
    };
    root.appendChild(card);   // 卡片不放在 .uls 里，重画不冲掉
  }

  /// 用改写结果替换整个句子（与建议的逐词替换不同层级）
  function replaceSegment(segment, text) {
    const el = lastTarget;
    if (!el) return;
    const full = textOf(el);
    const at = full.indexOf(segment);
    if (at < 0) return;
    if (el.isContentEditable) {
      const r = rangeForOffsets(el, at, at + segment.length);
      if (!r) return;
      el.focus();
      const sel = window.getSelection();
      sel.removeAllRanges(); sel.addRange(r);
      document.execCommand('insertText', false, text);
    } else {
      el.value = full.slice(0, at) + text + full.slice(at + segment.length);
      el.dispatchEvent(new Event('input', { bubbles: true }));
    }
  }

  // ---------- 接受 / 忽略 / 撤销：直接改 DOM ----------
  function accept(edit) {
    const el = lastTarget;
    if (!el) return;
    const sentStart = window.__EW_DEBUG.sentStart || 0;
    const abs = sentStart + edit.start;
    if (el.isContentEditable) {
      const r = rangeForOffsets(el, abs, abs + edit.length);
      if (!r) return;
      el.focus();
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
      document.execCommand('insertText', false, edit.replacement);
      lastAccept = { el, start: abs, len: edit.replacement.length, original: edit.original, contenteditable: true };
    } else {
      const v = el.value;
      const before = v.slice(0, abs), after = v.slice(abs + edit.length);
      setNativeValue(el, before + edit.replacement + after);
      lastAccept = { el, start: abs, len: edit.replacement.length, original: edit.original, contenteditable: false };
    }
    window.__EW_DEBUG.accepted++;
    runCheck(true);
  }

  function undo() {
    const la = lastAccept;
    if (!la) return false;
    if (la.contenteditable) {
      const r = rangeForOffsets(la.el, la.start, la.start + la.len);
      if (r) {
        la.el.focus();
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(r);
        document.execCommand('insertText', false, la.original);
      }
    } else {
      const v = la.el.value;
      setNativeValue(la.el, v.slice(0, la.start) + la.original + v.slice(la.start + la.len));
    }
    lastAccept = null;
    window.__EW_DEBUG.undone++;
    runCheck(true);
    return true;
  }

  // 忽略本次：只在这次会话里不再提示（Grammarly 的 Ignore once）
  const ignoredOnce = new Set();
  function ignoreOnce(edit) {
    ignoredOnce.add(edit.original + '→' + edit.replacement);
    clearUnderlines();
    runCheck(true);
  }

  // 加入词典：永久（跨会话，写 chrome.storage）
  function ignore(edit) {
    const key = edit.original + '→' + edit.replacement;
    ignoreList.add(key);
    chrome.storage.local.set({ ignore: [...ignoreList] });
    clearUnderlines();
  }

  function setNativeValue(el, value) {
    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
  }

  // ---------- 主流程 ----------
  // 两档去抖：本地快检 150ms 就出线（Grammarly 的「停笔即有」），模型检查 800ms 后跟上。
  let fastTimer = null;
  let modelTimer = null;
  let lastInputAt = 0;
  function onEdit(ev) {
    const el = editable(ev.target);
    if (!el) return;
    lastTarget = el;
    lastInputAt = performance.now();
    clearTimeout(fastTimer);
    clearTimeout(modelTimer);
    fastTimer = setTimeout(() => {
      // 量三段：输入事件→定时器触发（调度延迟）、定时器→画线（规则+绘制）
      window.__EW_DEBUG.timerDelayMs = Math.round(performance.now() - lastInputAt);
      const seq = ++runSeq;
      runLocalFast(false, seq);
    }, FAST_DEBOUNCE);
    modelTimer = setTimeout(() => {
      if (modelBusy) { rerunWanted = true; return; }
      modelBusy = true;
      const seq = ++runSeq;
      runModel(false, seq).finally(() => {
        modelBusy = false;
        if (rerunWanted) { rerunWanted = false; onEdit({ target: lastTarget }); }
      });
    }, DEBOUNCE);
  }

  document.addEventListener('input', onEdit, true);
  document.addEventListener('focusin', (e) => { const el = editable(e.target); if (el) lastTarget = el; }, true);
  document.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'z' && e.shiftKey) { if (undo()) e.preventDefault(); return; }
    if (!card) return;                       // 卡片没开，键盘只处理撤销
    if (e.key === 'Escape') { hideCard(); e.preventDefault(); return; }
    // ←/→ 在建议之间切换（Grammarly 同款：不用回到正文找下一条）
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      if (!anchors.length) return;
      const step = e.key === 'ArrowRight' ? 1 : -1;
      const cur = activeIndex < 0 ? 0 : activeIndex;
      const next = (cur + step + anchors.length) % anchors.length;
      const a = anchors[next];
      if (a) { a.el.scrollIntoView({ block: 'nearest' }); showCard(a.edit, a.el, next); }
      e.preventDefault();
    }
  }, true);

  // 同一时刻只跑一个检查：打字期间连续触发会排队，导致最后一个结果 10 秒后才回来
  let runSeq = 0;
  let modelBusy = false;
  let rerunWanted = false;

  async function runCheck(force) {
    // 只对「模型请求」排队：本地即时段不排队，否则会被上一条模型请求（可能 3 秒）挡住，
    // 表现就是「有时候 35ms 出线，有时候 3.5 秒」——11-19 夜里抓到的真因。
    const mySeq = ++runSeq;
    await runLocalFast(force, mySeq);
    if (modelBusy) { rerunWanted = true; return; }
    modelBusy = true;
    try {
      await runModel(force, mySeq);
    } finally {
      modelBusy = false;
      if (rerunWanted) { rerunWanted = false; runCheck(true); }
    }
  }

    // 解析当前目标与检查范围（两段共用）
  async function prepare(force, mySeq) {
    const el = lastTarget;
    if (!el) return null;
    if (!token) {
      token = await new Promise((r) => chrome.storage.local.get(['token'], (v) => r(v.token || null)));
    }
    if (!token) { window.__EW_DEBUG.notes.push('skip: no token'); return null; }
    const text = textOf(el);
    if (!text || text.length > 5000) return null;
    const caret = caretOf(el);
    let scopeText, scopeStart, scope;
    if (text.length <= 2000) {
      scopeText = text; scopeStart = 0; scope = 'document';
    } else {
      const sent = sentenceAround(text, caret);
      scopeText = sent.text; scopeStart = sent.start; scope = 'sentence';
    }
    window.__EW_DEBUG.scope = scope;
    if (scopeText.trim().length < 3) { clearUnderlines(); return null; }
    return { el, scopeText, scopeStart, scope };
  }

  // 本地即时结果留底：模型结果到达时与它取并集，不许把已画的线抹掉（知澜定的不变量）
  let fastEditsCache = [];
  const sig = (e) => e.start + ':' + e.length + ':' + e.replacement;

  function unionEdits(fast, model) {
    const seen = new Set(fast.map(sig));
    const out = fast.slice();
    for (const e of model) {
      if (seen.has(sig(e))) continue;
      // 与已有线重叠的更短结果丢弃（同一处不画两条）
      const overlaps = fast.some(f => e.start < f.start + f.length && f.start < e.start + e.length);
      if (overlaps) continue;
      seen.add(sig(e));
      out.push(e);
    }
    return out.sort((a, b) => a.start - b.start);
  }

  const drawWith = (ctx, j) => {
    let edits = (j.edits || []).filter(e => {
      const k = e.original + '→' + e.replacement;
      return !ignoreList.has(k) && !ignoredOnce.has(k);
    });
    if (j.engine === 'page-local') fastEditsCache = edits;
    else if (fastEditsCache.length) edits = unionEdits(fastEditsCache, edits);
    window.__EW_DEBUG.lastEdits = edits;
    window.__EW_DEBUG.engine = j.engine || '';
    window.__EW_DEBUG.elapsedMs = j.elapsedMs || 0;
    window.__EW_DEBUG.sentStart = ctx.scopeStart;
    window.__EW_DEBUG.sentText = ctx.scopeText;
    // 「停笔 → 出线」的真实延迟（页面内部计时，比探针轮询准）
    if (lastInputAt) window.__EW_DEBUG.lastLatencyMs = Math.round(performance.now() - lastInputAt);
    if (!edits.length) { clearUnderlines(); return; }
    drawUnderlines(ctx.el, edits, ctx.scopeStart);
  };

  async function postCheck(payload) {
    return fetch(API + '/v1/check', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-EW-Token': token },
      body: JSON.stringify(payload)
    });
  }

  // ---------- 页内即时规则（零请求，Grammarly 体感的来源）----------
  // 服务端 mode:"local" 要 40ms + 往返，且受 content script 调度影响；
  // 这里直接在页面里跑最小规则集，停笔后立刻有线，随后模型结果覆盖。
  const FAST_SPELL = {
    immediatly: 'immediately', recieve: 'receive', seperate: 'separate',
    occured: 'occurred', definately: 'definitely', accomodate: 'accommodate',
    adress: 'address', untill: 'until', wich: 'which', thier: 'their',
    becuase: 'because', buisness: 'business', enviroment: 'environment',
    sucess: 'success', propably: 'probably', wierd: 'weird', tommorow: 'tomorrow'
  };
  const FAST_RULES = [
    { re: /\b(there) (is)(?=\s+(many|several|numerous|few|lots of|two|three|four|five))\b/gi,
      fix: (m, a, b) => a + ' are', why: '主谓一致：there is + 复数 → there are' },
    { re: /\b(we|they|you) (was)\b/gi, fix: (m, a) => a + ' were', why: '主谓一致：we/they/you 配 were' },
    { re: /\b(he|she|it) (were)\b/gi, fix: (m, a) => a + ' was', why: '主谓一致：he/she/it 配 was' },
    { re: /\b(advise|inform|notify) (us|me|them|him|her) (the|your|our|this|that)\b/gi,
      fix: (m, a, b, c) => a + ' ' + b + ' of ' + c, why: '动词缺介词：advise sb of sth' },
    { re: /\b(have|has|had) (send|go|come|take|make|do|see|write|speak|break|choose|drive|eat|give|know)\b/gi,
      fix: (m, aux, v) => aux + ' ' + ({ send:'sent', go:'gone', come:'come', take:'taken', make:'made',
        do:'done', see:'seen', write:'written', speak:'spoken', break:'broken', choose:'chosen',
        drive:'driven', eat:'eaten', give:'given', know:'known' }[v.toLowerCase()] || v),
      why: '完成时用过去分词' },
    { re: /\b(was|were|is|are|been) (load|ship|pack|book|deliver|receive|confirm|inspect|discharge|release|issue)\b/gi,
      fix: (m, be, v) => be + ' ' + ({ load:'loaded', ship:'shipped', pack:'packed', book:'booked',
        deliver:'delivered', receive:'received', confirm:'confirmed', inspect:'inspected',
        discharge:'discharged', release:'released', issue:'issued' }[v.toLowerCase()] || v),
      why: '被动语态用过去分词' },
    { re: /\b(look(?:ing)? forward to) (hear|receive|meet|see|work|talk)\b/gi,
      fix: (m, a, v) => a + ' ' + ({ hear:'hearing', receive:'receiving', meet:'meeting',
        see:'seeing', work:'working', talk:'talking' }[v.toLowerCase()] || v),
      why: 'look forward to 后接动名词' },
    { re: /\b(will|would|shall|should|can|could|may|might|must) ([a-z]+ing)\b/gi,
      fix: (m, m1, v) => m1 + ' ' + v.replace(/ing$/i, '').replace(/([bdgklmnprt])\1$/i, '$1'),
      why: '情态动词后接动词原形' },
    { re: /\b(shipment|cargo|vessel|invoice|payment|order|container|document|report|booking|schedule) (have)\b/gi,
      fix: (m, n) => n + ' has', why: '主谓一致：单数主语配 has' },
    { re: /\b([A-Za-z]{2,}) \1\b/g, fix: (m, w) => w, why: '重复词' }
  ];

  function localFastEdits(text) {
    const out = [];
    for (const r of FAST_RULES) {
      r.re.lastIndex = 0;
      let m;
      while ((m = r.re.exec(text)) !== null) {
        const rep = r.fix.apply(null, m);
        if (!rep || rep === m[0]) continue;
        out.push({ start: m.index, length: m[0].length, original: m[0],
                   replacement: rep, type: 'grammar', reason: r.why });
      }
    }
    const re = /\b([A-Za-z]{4,})\b/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const fix = FAST_SPELL[m[1].toLowerCase()];
      if (!fix) continue;
      out.push({ start: m.index, length: m[1].length, original: m[1],
                 replacement: fix, type: 'spelling', reason: '拼写：' + m[1] + ' → ' + fix });
    }
    return out;
  }

  // 第一段：本地即时（不排队、不等模型）
  async function runLocalFast(force, mySeq) {
    const ctx = await prepare(force, mySeq);
    if (!ctx) return;
    try {
      const edits = localFastEdits(ctx.scopeText);   // 纯页内，零请求
      if (mySeq === runSeq) {
        drawWith(ctx, { edits, engine: 'page-local', elapsedMs: 0 });
        if (lastInputAt) window.__EW_DEBUG.fastLatencyMs = Math.round(performance.now() - lastInputAt);
      }
    } catch (e) {
      window.__EW_DEBUG.notes.push('fast err=' + e.message);
    }
  }

  // 第二段：完整检查（含模型），排队执行，过期结果丢弃
  async function runModel(force, mySeq) {
    const ctx = await prepare(force, mySeq);
    if (!ctx) return;
    try {
      const res = await postCheck({ text: ctx.scopeText, language: 'en-GB' });
      if (res.status === 401) { window.__EW_DEBUG.notes.push('401 bad token'); return; }
      const j = await res.json();
      if (mySeq !== runSeq) return;
      drawWith(ctx, j);
    } catch (e) {
      window.__EW_DEBUG.notes.push('fetch fail: ' + e.message);
    }
  }

  // 供验收器调用（不靠鼠标悬停也能触发卡片/接受）
  window.__EW_TEST__ = {
    check: () => runCheck(true),
    state: () => window.__EW_DEBUG,
    // 矩形探针：forceFallback=true 时强制走「逐文本节点并集」兜底，用来证明兜底路径真能出矩形
    rectProbe: (sel, start, len, forceFallback) => {
      const el = document.querySelector(sel);
      if (!el) return { rects: [], source: 'no-element' };
      if (forceFallback) {
        window.__EW_DEBUG.rectSource = 'none';
        const rs = childUnionRects(el, start, len);
        return { rects: rs, source: window.__EW_DEBUG.rectSource };
      }
      const rs = rectsFor(el, start, len);
      return { rects: rs, source: window.__EW_DEBUG.rectSource };
    },
    acceptByOriginal: (orig) => {
      const e = (window.__EW_DEBUG.lastEdits || []).find(x => x.original === orig);
      if (!e) return false;
      accept(e);
      return true;
    },
    undo: () => undo()
  };
})();
