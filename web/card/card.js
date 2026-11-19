const escc = t => String(t == null ? '' : t).replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const EWCard = {
  canRewrite: false,
  post(m) { window.webkit && window.webkit.messageHandlers.bridge.postMessage(m); },
  card(d) {
    this.canRewrite = d.canRewrite;
    document.getElementById('dot').style.background = d.color;
    document.getElementById('cat').textContent = d.category;
    // 所有插值都过 escc()，文档内容不可能注入标签
    // 原句：上下文 + 错处（红删除线）；建议单独一行（绿底）——规格要求两行分开
    document.getElementById('sent').innerHTML =
      escc(d.before) + `<span class="old">${escc(d.original)}</span>` + escc(d.after);
    document.getElementById('sugg').innerHTML = `<span class="new">${escc(d.replacement)}</span>`;
    const reason = document.getElementById('reason');
    reason.textContent = d.reason || '';
    reason.style.display = d.reason ? '' : 'none';
    document.getElementById('dict').style.display = d.allowDict ? '' : 'none';
    this.report();
  },
  more() { this.post({ action: this.canRewrite ? 'rewrite' : 'ignoreSession' }); },
  report() {
    requestAnimationFrame(() => {
      const h = document.getElementById('card').getBoundingClientRect().height + 8;
      this.post({ action: 'height', h: h });
    });
  }
};
window.EWCard = EWCard;
// 按钮统一挂事件（不在 HTML 里写 onclick，action 集合可由 selftest 断言）
document.addEventListener('DOMContentLoaded', () => {
  const bind = (id, action) => {
    const el = document.getElementById(id);
    if (el) el.addEventListener('click', () => EWCard.post({ action }));
  };
  bind('accept', 'accept');
  bind('ignore', 'ignore');
  bind('ignoreSession', 'ignoreSession');
  bind('dict', 'dict');
  bind('more', 'more');
});
