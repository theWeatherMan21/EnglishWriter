// 侧栏逻辑 —— 桌面 App 与浏览器扩展共用。所有来自文档的文本先 esc() 再拼 DOM。
const esc = t => String(t == null ? '' : t).replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const typeColor = t => t === 'clarity' ? '#4A6EDE' : (t === 'style' ? '#7E57C2' : '#EE1437');

const EW = {
  data: null,
  filter: null,
  post(m) { window.webkit && window.webkit.messageHandlers.bridge.postMessage(m); },

  render(d) {
    this.data = d;
    document.getElementById('score').textContent = d.overall;
    document.getElementById('band').textContent = d.band;
    const pct = Math.max(0, Math.min(1, d.overall / 100));
    const arc = document.getElementById('arc');
    arc.style.stroke = pct >= .8 ? '#2E7D32' : (pct >= .5 ? '#F59E0B' : '#EE1437');
    arc.style.strokeDashoffset = (257.6 * (1 - pct)).toFixed(1);

    document.getElementById('dims').innerHTML = d.dims.map(x => {
      const sev = x.value >= 80 ? '#2E7D32' : (x.value >= 50 ? '#F59E0B' : '#EE1437');
      const cat = { '正确性': '#EE1437', '清晰度': '#4A6EDE', '吸引力': '#2E7D32', '表达': '#7E57C2' }[x.name] || '#027E6F';
      // 每行只放「维度名 / 分数 / 进度条」，计数与百分比一律不进评分行（避免口径混在一起）
      return `<div class="dim" title="${esc(x.note || '')}"><span class="n">${esc(x.name)}</span>
        <span class="v" style="color:${sev}">${x.value}</span>
        <span class="bar"><i style="width:${x.value}%;background:${cat}"></i></span></div>`;
    }).join('');

    const colors = ['#1F2328', '#EE1437', '#4A6EDE', '#7E57C2'];
    document.getElementById('tabs').innerHTML = d.tabs.map((t, i) =>
      `<div class="tab ${(this.filter === null && i === 0) || this.filter === ['grammar', 'clarity', 'style'][i - 1] ? 'on' : ''}"
            onclick="EW.pick(${i})"><i style="background:${colors[i]}"></i>
       <span>${esc(t.name)}<b>${t.n}</b></span></div>`).join('')
      + `<button class="allbtn" title="一次改完所有建议，可用 ⌘Z 撤销" onclick="EW.post({action:'acceptAll'})">全部接受</button>`;

    const groups = (d.groups || []).filter(g => !this.filter || g.type === this.filter);
    if (!groups.length) {
      document.getElementById('list').innerHTML =
        `<div class="empty"><div class="tick">✓</div><div>没有发现问题</div></div>`;
      document.getElementById('tone').textContent = d.tone ? ('语气：' + d.tone) : '';
      return;
    }
    document.getElementById('list').innerHTML = groups.map(g => `<div class="group">
      <div class="ghead"><em style="background:${typeColor(g.type)}"></em>
        ${esc(g.title)} <span>${g.items.length}</span></div>
      ${g.items.map(it => `<div class="row" data-id="${it.id}" onclick="EW.post({action:'jump',id:${it.id}})">
          <div class="line"><span class="old">${esc(it.original)}</span> → <span class="new">${esc(it.replacement)}</span></div>
          <div class="reason">${esc(it.reason)}</div>
          <div class="acts">
            <button class="btn" onclick="event.stopPropagation();EW.post({action:'dismiss',id:${it.id}})">忽略</button>
            <button class="btn primary" onclick="event.stopPropagation();EW.accept(${it.id}, this)">接受</button>
          </div></div>`).join('')}
    </div>`).join('') || '<div class="foot">没有更多建议</div>';

    document.getElementById('tone').textContent = d.tone ? ('语气：' + d.tone) : '';
  },

  // 接受：先在 200ms 内淡出这张卡，再通知 Swift（Swift 会重推新的计数与分数）
  accept(id, btn) {
    const row = btn.closest('.row');
    if (row) { row.classList.add('leaving'); }
    setTimeout(() => this.post({ action: 'accept', id: id }), 180);
  },

  pick(i) { this.filter = i === 0 ? null : ['grammar', 'clarity', 'style'][i - 1]; this.render(this.data); },

  focus(i) {
    const el = document.querySelector(`.row[data-id="${i}"]`);
    if (!el) return;
    el.scrollIntoView({ block: 'nearest' });
    el.classList.add('flash');
    setTimeout(() => el.classList.remove('flash'), 900);
  },

  saved() {
    const s = document.getElementById('saved');
    s.classList.add('on');
    setTimeout(() => s.classList.remove('on'), 1500);
  }
};
window.EW = EW;
