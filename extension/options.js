// options.js — token 存取 + 服务探活（不预设默认值）
const $ = (id) => document.getElementById(id);
const API = 'http://127.0.0.1:17817';

function st(msg, bad) {
  const el = $('st');
  el.textContent = msg;
  el.style.color = bad ? '#c0264b' : '#17794a';
}

chrome.storage.local.get(['token'], (v) => {
  if (v.token) $('t').value = v.token;
});

$('save').onclick = () => {
  const token = $('t').value.trim();
  chrome.storage.local.set({ token }, () => st(token ? '已保存（' + token.length + ' 字符）' : '已清空 token —— 扩展将不工作', !token));
};

$('ping').onclick = async () => {
  const token = $('t').value.trim();
  try {
    const h = await fetch(API + '/v1/health').then(r => r.json());
    if (!token) { st('服务在线，但还没填 token', true); return; }
    const r = await fetch(API + '/v1/check', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-EW-Token': token },
      body: JSON.stringify({ text: 'There is many reasons why we should sent it immediatly.' })
    });
    if (r.status === 401) { st('token 不对（401）', true); return; }
    const j = await r.json();
    st('通：引擎 ' + j.engine + '，命中 ' + (j.edits ? j.edits.length : 0) + ' 条，' + j.elapsedMs + 'ms');
  } catch (e) {
    st('连不上本机服务：' + e.message + '（App 起了吗？）', true);
  }
};
