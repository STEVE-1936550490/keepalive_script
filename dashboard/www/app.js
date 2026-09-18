'use strict';
let state = null;
let filter = 'all';
let busy = false;
let locked = false;
let sessionGeneration = 0;
const $ = (selector, root = document) => root.querySelector(selector);
const phases = { active: ['活跃中', 'active'], waiting: ['等待调度', 'good'], finished: ['本轮已完成', 'good'], error: ['本轮异常', 'bad'], stopped: ['主控未运行', 'neutral'], disabled: ['未启用', 'neutral'] };
const connections = { ok: '最近登录成功', timeout: '连接超时', authentication_failed: '认证失败', connection_refused: '端口拒绝连接', missing_password: '未配置密码', missing_sshpass_or_password: '密码或 sshpass 缺失', missing_key: '密钥文件缺失', ssh_unreachable: 'SSH 无法连接', ssh_error: 'SSH 连接失败', unknown: '尚未检查', host_key_mismatch: '主机密钥变更', network_unreachable: '网络不可达' };
const actions = { start: '开始活跃', cpu: 'CPU 采样', disk: '磁盘读写', finish: '活跃结束', cpu_pause: 'CPU 保护暂停', disk_skip: '跳过磁盘写入', schedule: '生成调度', activation_failed: '活跃失败', skip: '跳过主机', error: '运行异常', cancel: '取消任务' };
function localTime(seconds) { return new Date(seconds * 1000).toLocaleString('zh-CN', { hour12: false }); }
function setText(selector, value, root = document) { $(selector, root).textContent = value; }
function render() {
    const c = state.controller;
    setText('#controller-state', c.running ? '运行中' : '已停止');
    $('#controller-dot').className = `dot ${c.running ? 'green' : ''}`;
    setText('#controller-detail', c.running ? `PID ${c.pid} · 已运行 ${Math.max(0, Math.floor((state.generated_at - c.started_at) / 60))} 分钟` : '没有正在运行的调度进程');
    setText('#host-count', state.hosts.length);
    setText('#hosts-total', state.hosts.length);
    setText('#enabled-count', `${state.hosts.filter(h => h.enabled).length} 台已启用 · ${state.hosts.filter(h => !h.enabled).length} 台未启用`);
    const remotes = state.hosts.filter(h => h.type === 'remote');
    setText('#connection-count', `${remotes.filter(h => h.connection === 'ok').length} / ${remotes.length}`);
    setText('#active-count', state.hosts.filter(h => h.phase === 'active').length);
    setText('#clock', localTime(state.generated_at));
    const cards = document.createDocumentFragment();
    for (const h of state.hosts.filter(h => filter === 'all' || h.type === filter)) {
        const card = $('#host-template').content.firstElementChild.cloneNode(true);
        setText('h3', h.name, card);
        setText('.address', h.type === 'local' ? '本机 · LOCAL' : h.ip, card);
        const phase = phases[h.phase] || phases.stopped;
        setText('.phase', phase[0], card); $('.phase', card).className = `phase tag ${phase[1]}`;
        setText('.connection strong', h.type === 'local' ? '本地执行' : (connections[h.connection] || '检查失败'), card);
        $('.connection .dot', card).className = `dot ${h.type === 'local' || h.connection === 'ok' ? 'green' : (h.connection === 'unknown' ? '' : 'red')}`;
        setText('.connection time', h.connection_at || '—', card);
        setText('.cpu-value', h.cpu === null ? '—' : `${h.cpu}%`, card);
        const samples = h.cpu_history.filter(Number.isFinite);
        const points = samples.map((v, i) => `${samples.length === 1 ? 160 : (i / (samples.length - 1)) * 320},${52 - Math.min(100, Math.max(0, v)) * .5}`).join(' ');
        $('.cpu-line', card).setAttribute('points', points);
        setText('.sample-time', h.cpu_at ? `采样于 ${h.cpu_at} · 虚线为 70% 参考线` : '暂无活跃采样', card);
        setText('.disk-value', h.disk_mb === null ? '—' : `${h.disk_mb} MiB`, card);
        $('.disk-value', card).title = h.disk_at || '';
        setText('.next-value', c.running && h.next_at ? localTime(h.next_at) : '—', card);
        cards.append(card);
    }
    $('#hosts').replaceChildren(cards);
    const rows = document.createDocumentFragment();
    for (const e of [...state.events].reverse()) {
        const tr = document.createElement('tr');
        const detail = [e.cpu === null ? '' : `CPU ${e.cpu}%`, e.disk_mb === null ? '' : `${e.disk_mb} MiB`, e.rc === null ? '' : `退出码 ${e.rc}`].filter(Boolean).join(' · ') || '—';
        for (const value of [e.at, e.host, actions[e.action] || e.action, detail]) { const td = document.createElement('td'); td.textContent = value; tr.append(td); }
        rows.append(tr);
    }
    if (!state.events.length) { const tr = document.createElement('tr'); const td = document.createElement('td'); td.colSpan = 4; td.className = 'empty'; td.textContent = '暂无活跃记录，启动 keepalive 后将显示在这里。'; tr.append(td); rows.append(tr); }
    $('#events').replaceChildren(rows);
}
async function refresh() {
    if (busy) return;
    busy = true;
    const generation = sessionGeneration;
    try {
        const response = await fetch('/cgi-bin/state.sh', { cache: 'no-store', signal: AbortSignal.timeout(8000) });
        if (response.status === 401) { showLogin(); return; }
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const next = await response.json();
        if (generation !== sessionGeneration) return;
        if (!Array.isArray(next.hosts) || !next.controller) throw new Error('Invalid state');
        state = next; locked = false; render();
        $('#login-screen').hidden = true; $('#dashboard-screen').hidden = false;
        $('#error').hidden = true; $('#refresh-dot').className = 'dot green'; setText('#refresh-status', '状态已更新');
    } catch (_) {
        $('#error').hidden = false; $('#refresh-dot').className = 'dot red'; setText('#refresh-status', '刷新失败 · 数据可能过期');
        if (!state) setText('#login-message', '服务暂时无法访问，请稍后重试。');
    } finally { busy = false; }
}
function showLogin() {
    sessionGeneration++;
    locked = true; state = null;
    $('#dashboard-screen').hidden = true; $('#login-screen').hidden = false;
    $('#hosts').replaceChildren(); $('#events').replaceChildren();
    $('#password').value = '';
}
$('#login-form').addEventListener('submit', async event => {
    event.preventDefault(); $('#login-submit').disabled = true; setText('#login-message', '');
    try {
        const response = await fetch('/cgi-bin/login.sh', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: $('#password').value, signal: AbortSignal.timeout(10000) });
        if (!response.ok) { setText('#login-message', response.status === 429 ? '尝试次数过多，请 5 分钟后重试。' : response.status === 401 ? '密码不正确，请重试。' : '登录服务暂时不可用。'); return; }
        $('#password').value = ''; locked = false; await refresh();
    } catch (_) { setText('#login-message', '无法连接服务，请稍后重试。'); }
    finally { $('#login-submit').disabled = false; }
});
$('#logout').addEventListener('click', async () => {
    try { const response = await fetch('/cgi-bin/logout.sh', { method: 'POST', signal: AbortSignal.timeout(8000) }); if (!response.ok && response.status !== 401) throw new Error(); showLogin(); }
    catch (_) { $('#error').hidden = false; setText('#error', '退出失败，请重试。'); }
});
$('#refresh').addEventListener('click', refresh);
for (const button of document.querySelectorAll('[data-filter]')) button.addEventListener('click', () => { filter = button.dataset.filter; for (const b of document.querySelectorAll('[data-filter]')) b.classList.toggle('selected', b === button); if (state) render(); });
refresh();
setInterval(() => { if (!locked) refresh(); }, 5000);
