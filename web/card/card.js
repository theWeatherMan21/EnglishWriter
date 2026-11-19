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
    document.getElementById('sent').innerHTML =
      escc(d.before) + `<span class="old">${escc(d.original)}</span> ` +
      `<span class="new">${escc(d.replacement)}</span>` + escc(d.after);
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
