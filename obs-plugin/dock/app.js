'use strict';
const $ = id => document.getElementById(id);
let state, token, busy = false, initialized = false, pendingId = null, busyUntil = 0;
let pluginKey = '';
function refreshPlugin() {
  const plugin = state?.phone_plugin, hosts = state?.addresses || [];
  $('phone_plugin').disabled = !plugin?.available || !hosts.length;
  if (!$('plugin_dialog').open) return;
  const selected = $('plugin_host').value;
  const key = JSON.stringify([hosts, plugin?.port, plugin?.available, plugin?.lan_ready]);
  if (pluginKey === key) return;
  pluginKey = key;
  $('plugin_host').replaceChildren(...hosts.map(host => new Option(host, host)));
  if (hosts.includes(selected)) $('plugin_host').value = selected;
  $('plugin_host').hidden = $('plugin_host_label').hidden = hosts.length < 2;
  updatePluginDownload();
}
function updatePluginDownload() {
  const plugin = state?.phone_plugin, host = $('plugin_host').value;
  const available = plugin?.available && !!host;
  $('download_plugin').hidden = !available;
  $('download_plugin').href = '/api/phone-plugin?host=' + encodeURIComponent(host);
  $('plugin_qr').hidden = true;
  if (!available) { $('plugin_message').textContent = '手机插件或电脑地址暂不可用'; return; }
  $('plugin_message').textContent = plugin.lan_ready ? '正在生成二维码…' : '扫码下载需要电脑开启局域网传输';
  if (plugin.lan_ready) $('plugin_qr').src = '/api/phone-qr?host=' + encodeURIComponent(host) + '&port=' + plugin.port;
}
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
    refreshPlugin();
    if (busy && Date.now() > busyUntil) { busy = false; pendingId = null; initialized = false; showError('操作未完成，请重试。'); }
    const s = state.sender, b = state.bridge, active = ['starting','running','stopping'].includes(s.state);
    if (pendingId && b.last_command === pendingId) { pendingId = null; busy = false; initialized = false; if (b.command_error) showError(b.command_error); }
    if (!initialized && !busy && b.settings) {
      $('quality').value = b.settings.quality; $('connection_mode').value = b.settings.connection_mode;
      $('computer_audio').checked = b.settings.computer_audio; initialized = true;
    }
    const usb = s.usb_clients > 0, lan = s.clients > (s.usb_clients || 0);
    const pullReaders = s.rtmp_readers || 0, totalClients = (s.clients || 0) + pullReaders;
    // Display the mode applied to the running sender, never an unapplied setting.
    if (active && ['usb','lan'].includes(s.connection_mode)) $('connection_mode').value = s.connection_mode;
    $('status').textContent = !state.ready ? '等待 OBS 控制连接' : s.state === 'running' ? (totalClients > 0 ? '已连接手机' : '等待手机连接') : ({starting:'正在启动传输',stopping:'正在停止传输',error:'传输遇到问题'}[s.state] || '尚未开始传输');
    const mode = active && s.connection_mode ? s.connection_mode : $('connection_mode').value;
    $('detail').textContent = !state.ready ? '请加载或重载 AppleLive.lua 脚本' : s.state === 'running' ? (usb && lan ? 'USB 和局域网均有接收连接' : usb ? '正在通过 USB 传输画面' : pullReaders ? '局域网 · 标准拉流已连接' : lan ? '正在通过局域网传输画面' : mode === 'usb' ? 'USB · 等待手机自动连接' : '局域网 · 等待手机自动连接') : 'OBS 节目画面 → iPhone';
    $('light').className = 'light' + (s.state === 'running' && totalClients ? ' on' : s.state === 'error' ? ' error' : '');
    $('fields').disabled = active || busy || state.pending || !state.ready;
    $('toggle').disabled = busy || state.pending || !state.ready || ['starting','stopping'].includes(s.state);
    $('toggle').textContent = s.state === 'stopping' ? '正在停止…' : s.state === 'starting' ? '正在启动…' : active ? '停止传输' : '开始传输';
    $('toggle').className = active ? 'stop' : '';
    $('settings_hint').textContent = active ? '需要调整画质时，先停止传输' : busy || state.pending ? '正在保存…' : '设置自动保存';
    $('mode_hint').textContent = mode === 'usb' ? '仅通过 USB 数据线传输，手机自动跟随。' : '局域网 · 手机自动连接';
    $('stream_box').hidden = mode === 'usb' || !s.rtmp_enabled;
    $('allow_lan').hidden = mode === 'usb';
    $('stream_address').textContent = state.addresses.length ? 'rtmp://' + state.addresses[0] + ':1935/live/applelive' : '';
    if (s.state === 'error' && !busy) showError(s.error || '发送器启动失败，请查看插件目录中的日志');
  } catch(error) { $('status').textContent = '控制面板暂时断开'; $('detail').textContent = '请在 OBS 中重新加载 AppleLive.lua'; $('toggle').disabled = true; $('fields').disabled = true; }
}
$('settings').addEventListener('submit', event => event.preventDefault());
$('fields').addEventListener('change', () => command('settings', settings()));
$('toggle').addEventListener('click', () => command(state?.sender.state === 'running' ? 'stop' : 'start'));
$('copy_stream').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('stream_address').textContent); $('copy_stream').textContent = '已复制'; }
  catch { showError('无法复制，请选中拉流地址复制'); }
  setTimeout(() => { $('copy_stream').textContent = '复制地址'; }, 1500);
});
$('allow_lan').addEventListener('click', async () => {
  const button = $('allow_lan');
  button.disabled = true;
  try {
    const response = await fetch('/api/firewall', {method: 'POST', headers: {'X-AppleLive-Token': token}});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '无法打开防火墙设置');
    button.textContent = '请在系统窗口中确认授权';
  } catch (error) { showError(error.message); button.disabled = false; }
  setTimeout(() => { button.textContent = '重新授权局域网访问'; button.disabled = false; }, 5000);
});
$('phone_plugin').addEventListener('click', () => { pluginKey = ''; $('plugin_dialog').showModal(); refreshPlugin(); });
$('close_plugin').addEventListener('click', () => $('plugin_dialog').close());
$('plugin_host').addEventListener('change', updatePluginDownload);
$('plugin_qr').addEventListener('load', () => { if (state?.phone_plugin?.lan_ready && $('plugin_dialog').open) { $('plugin_qr').hidden = false; $('plugin_message').textContent = '手机扫码下载'; } });
$('plugin_qr').addEventListener('error', () => { $('plugin_qr').hidden = true; $('plugin_message').textContent = '二维码暂不可用，可下载文件'; });
refresh(); setInterval(refresh, 1000);
