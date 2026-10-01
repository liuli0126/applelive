'use strict';
const $ = id => document.getElementById(id);
let state, token, busy = false, initialized = false, pendingId = null, busyUntil = 0;
function showError(message) { $('error').hidden = !message; $('error').textContent = message || ''; }
function settings() { return { quality: $('quality').value, connection_mode: $('connection_mode').value, computer_audio: $('computer_audio').checked }; }
async function command(action, values = {}) {
  busy = true; $('toggle').disabled = true; $('fields').disabled = true; showError('');
  busyUntil = Date.now() + 16000;
  try {
    const response = await fetch('/api/command', {method: 'POST', headers: {'Content-Type':'application/json','X-AppleLive-Token':token}, body:JSON.stringify({action, settings:values})});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '操作失败');
    pendingId = result.id;
  } catch(error) { showError(error.message); busy = false; initialized = false; }
  await refresh();
}
async function refresh() {
  try {
    const response = await fetch('/api/status');
    if (!response.ok) throw new Error('控制服务暂不可用');
    state = await response.json(); token = state.token;
    if (busy && Date.now() > busyUntil) { busy = false; pendingId = null; initialized = false; showError('操作未完成，请重试。'); }
    const s = state.sender, b = state.bridge, active = ['starting','running','stopping'].includes(s.state);
    if (pendingId && b.last_command === pendingId) { pendingId = null; busy = false; initialized = false; if (b.command_error) showError(b.command_error); }
    if (!initialized && !busy && b.settings) {
      $('quality').value = b.settings.quality; $('connection_mode').value = b.settings.connection_mode;
      $('computer_audio').checked = b.settings.computer_audio; initialized = true;
    }
    const usb = s.usb_clients > 0, lan = s.clients > (s.usb_clients || 0);
    // Display the mode applied to the running sender, never an unapplied setting.
    if (active && ['usb','lan'].includes(s.connection_mode)) $('connection_mode').value = s.connection_mode;
    $('status').textContent = !state.ready ? '等待 OBS 控制连接' : s.state === 'running' ? (s.clients > 0 ? '已连接手机' : '等待手机连接') : ({starting:'正在启动传输',stopping:'正在停止传输',error:'传输遇到问题'}[s.state] || '尚未开始传输');
    const mode = active && s.connection_mode ? s.connection_mode : $('connection_mode').value;
    $('detail').textContent = !state.ready ? '请加载或重载 AppleLive.lua 脚本' : s.state === 'running' ? (usb && lan ? 'USB 和局域网均有接收连接' : usb ? '正在通过 USB 传输画面' : lan ? '正在通过局域网传输画面' : mode === 'usb' ? 'USB · 等待手机自动连接' : '局域网 · 等待手机自动连接') : 'OBS 节目画面 → iPhone';
    $('light').className = 'light' + (s.state === 'running' && s.clients ? ' on' : s.state === 'error' ? ' error' : '');
    $('fields').disabled = active || busy || state.pending || !state.ready;
    $('toggle').disabled = busy || state.pending || !state.ready || ['starting','stopping'].includes(s.state);
    $('toggle').textContent = s.state === 'stopping' ? '正在停止…' : s.state === 'starting' ? '正在启动…' : active ? '停止传输' : '开始传输';
    $('toggle').className = active ? 'stop' : '';
    $('settings_hint').textContent = active ? '需要调整画质时，先停止传输' : busy || state.pending ? '正在保存…' : '设置自动保存';
    $('mode_hint').textContent = mode === 'usb' ? '仅通过 USB 数据线传输，手机自动跟随。' : '仅通过局域网传输，手机自动跟随。首次使用请在手机填写下方地址。';
    $('address_box').hidden = mode === 'usb';
    $('addresses').textContent = state.addresses.map(a => a + ':' + (b.settings?.port || 8765)).join(' / ') || '请连接路由器后重新加载脚本';
    if (s.state === 'error' && !busy) showError(s.error || '发送器启动失败，请查看插件目录中的日志');
  } catch(error) { $('status').textContent = '控制面板暂时断开'; $('detail').textContent = '请在 OBS 中重新加载 AppleLive.lua'; $('toggle').disabled = true; $('fields').disabled = true; }
}
$('settings').addEventListener('submit', event => event.preventDefault());
$('fields').addEventListener('change', () => command('settings', settings()));
$('toggle').addEventListener('click', () => command(state?.sender.state === 'running' ? 'stop' : 'start'));
refresh(); setInterval(refresh, 1000);
