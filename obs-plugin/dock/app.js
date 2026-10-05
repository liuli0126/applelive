'use strict';
const $ = id => document.getElementById(id);
let state, token, pendingId = null, busyUntil = 0, hostsKey = '';
let selectedMode = localStorage.getItem('applelive.mode') === 'usb' ? 'usb' : 'lan';
let modeTouched = false;

function showError(message) {
  $('error').hidden = !message;
  $('error').textContent = message || '';
}

function updateAddresses() {
  const host = $('host').value;
  $('publish_server').textContent = host ? `rtmp://${host}:1935/live` : '等待电脑 IP';
  $('rtmp_pull_address').textContent = host ? `rtmp://${host}:1935/live/applelive` : '等待电脑 IP';
  $('rtsp_pull_address').textContent = host ? `rtsp://${host}:8554/live/applelive` : '等待电脑 IP';
}

function updateModeUI() {
  const lan = selectedMode === 'lan';
  $('mode_lan').setAttribute('aria-pressed', String(lan));
  $('mode_usb').setAttribute('aria-pressed', String(!lan));
  $('lan_host').hidden = !lan;
  $('lan_publish').hidden = !lan;
  $('lan_addresses').hidden = !lan;
  $('lan_access').hidden = !lan;
  $('usb_panel').hidden = lan;
  $('configure').textContent = lan ? '获取推流码' : '准备 USB 直连';
}

function selectMode(mode) {
  if (!['lan', 'usb'].includes(mode)) return;
  const active = selectedMode === 'usb' ? !!state?.usb?.running : !!state?.bridge?.stream_active;
  if (active || pendingId) return;
  selectedMode = mode;
  modeTouched = true;
  localStorage.setItem('applelive.mode', mode);
  updateModeUI();
  refresh();
}

async function requestFirewall() {
  const button = $('allow_lan');
  button.disabled = true;
  button.textContent = '正在打开 Windows 授权...';
  const response = await fetch('/api/firewall', {method: 'POST', headers: {'X-AppleLive-Token': token}});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '授权失败');
  button.textContent = '请在 Windows 窗口点击“是”';
}

async function configure() {
  try {
    if (selectedMode === 'lan' && !state?.firewall_ready) await requestFirewall();
    await command('configure_stream');
  } catch (error) {
    showError(error.message);
    $('allow_lan').disabled = false;
  }
}

async function command(action) {
  busyUntil = Date.now() + 16000;
  $('configure').disabled = $('broadcast').disabled = true;
  showError('');
  try {
    const response = await fetch('/api/command', {
      method: 'POST',
      headers: {'Content-Type': 'application/json', 'X-AppleLive-Token': token},
      body: JSON.stringify({
        action,
        mode: action === 'configure_stream' ? selectedMode : undefined,
        host: action === 'configure_stream' && selectedMode === 'lan' ? $('host').value : undefined,
      }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '操作失败');
    pendingId = result.id;
  } catch (error) {
    busyUntil = 0;
    showError(error.message);
  }
  await refresh();
}

async function refresh() {
  try {
    const response = await fetch('/api/status');
    if (!response.ok) throw new Error('控制服务暂不可用');
    state = await response.json();
    token = state.token;
    const hosts = state.addresses || [];
    const key = JSON.stringify(hosts);
    if (key !== hostsKey) {
      const selected = $('host').value;
      $('host').replaceChildren(...hosts.map(host => new Option(host, host)));
      if (hosts.includes(selected)) $('host').value = selected;
      hostsKey = key;
      updateAddresses();
    }
    const bridge = state.bridge || {};
    if (!modeTouched && bridge.stream_mode) {
      selectedMode = bridge.stream_mode;
      localStorage.setItem('applelive.mode', selectedMode);
      updateModeUI();
    }
    if (pendingId && bridge.last_command === pendingId) {
      pendingId = null;
      busyUntil = 0;
      if (bridge.command_error) showError(bridge.command_error);
    }
    if (pendingId && Date.now() > busyUntil) {
      pendingId = null;
      showError('OBS 没有完成操作，请检查脚本是否已加载');
    }

    const usb = state.usb || {};
    const usbActive = selectedMode === 'usb' && !!usb.running;
    const active = selectedMode === 'usb' ? usbActive : !!bridge.stream_active;
    const configured = selectedMode === 'usb' ? usbActive : !!bridge.stream_configured;
    const path = state.stream_path || {};
    const selectedServer = `rtmp://${$('host').value}:1935/live`;
    const tracks = path.tracks || [];
    const usbConnected = selectedMode === 'usb' && (usb.usb_clients || 0) > 0;

    $('status').textContent = !state.ready ? '等待 OBS 控制连接'
      : selectedMode === 'usb' && usbConnected ? 'USB 数据线已连接'
      : selectedMode === 'usb' && active ? '等待手机 USB 连接'
      : active && path.ready ? '电脑画面已送达本机'
      : active ? '正在等待电脑画面'
      : configured ? (selectedMode === 'usb' ? 'USB 直连已准备' : '推流码已写入 OBS')
      : (selectedMode === 'usb' ? '尚未准备 USB 直连' : '尚未获取推流码');
    $('detail').textContent = !state.ready ? (state.obs_error || '请在 OBS 工具 → 脚本中加载 AppleLive.lua')
      : selectedMode === 'usb' && usb.error ? usb.error
      : selectedMode === 'usb' && active ? (usbConnected ? 'OBS 编码流正在通过数据线传输' : '保持 iPhone 解锁并连接数据线')
      : selectedMode === 'usb' ? '点击准备 USB 直连会自动启动 OBS 画面输出，不需要 OBS 开播'
      : active && !state.stream_server_ready ? '本地流服务器未就绪'
      : active && !path.ready ? 'OBS 已开播，本地流服务器尚未收到画面'
      : active && !tracks.includes('H264') ? '请将 OBS 视频编码设为 H.264'
      : active && !tracks.includes('MPEG-4 Audio') ? '请将 OBS 音频编码设为 AAC'
      : active ? `手机拉流连接：${path.readers || 0}` : '本地流尚未开始';
    $('usb_status').textContent = usbConnected ? '已连接手机'
      : usb.state === 'error' ? (usb.error || 'USB 发送器错误')
      : usb.running ? `正在查找 iPhone（${usb.input_url || 'OBS 本地编码流'}）` : '等待准备 USB 直连';
    $('light').className = 'light' + (selectedMode === 'usb' ? (usbConnected ? ' on' : '') : (active && path.ready ? ' on' : ''));
    $('configure').disabled = !state.ready || (selectedMode === 'lan' && !hosts.length) || active || !!pendingId;
    $('broadcast').disabled = !state.ready || !!pendingId ||
      (selectedMode === 'lan' && (!configured || !state.firewall_ready ||
        (!active && !state.stream_server_ready) || bridge.stream_server !== selectedServer));
    $('broadcast').textContent = selectedMode === 'usb' ? (active ? '停止直连' : '开始直连') : (active ? '下播' : '开播');
    $('broadcast').className = active ? 'stop' : '';
    if (selectedMode === 'lan' && configured && !active && bridge.stream_server !== selectedServer) $('broadcast').disabled = true;
    $('mode_lan').disabled = $('mode_usb').disabled = active || !!pendingId;
    $('phone_plugin').hidden = !state.phone_plugin?.available;
    $('lan_status').textContent = state.firewall_ready ? '局域网端口已授权'
      : state.firewall_pending ? '等待 Windows 管理员授权'
      : '局域网端口未授权，手机会连接超时';
    $('lan_status').className = 'network_status' + (state.firewall_ready ? ' ready' : '');
    if (state.firewall_ready) {
      $('allow_lan').textContent = '局域网访问已授权';
      $('allow_lan').disabled = true;
    } else if (state.firewall_pending) {
      $('allow_lan').textContent = '请在 Windows 窗口点击“是”';
      $('allow_lan').disabled = true;
    } else {
      $('allow_lan').textContent = '授权局域网访问';
      $('allow_lan').disabled = false;
      if (state.firewall_error) showError(state.firewall_error);
    }
  } catch (error) {
    $('status').textContent = '控制面板未连接';
    $('detail').textContent = '请重新加载 OBS 脚本';
    $('configure').disabled = $('broadcast').disabled = true;
  }
}

$('host').addEventListener('change', updateAddresses);
$('mode_lan').addEventListener('click', () => selectMode('lan'));
$('mode_usb').addEventListener('click', () => selectMode('usb'));
$('configure').addEventListener('click', configure);
$('broadcast').addEventListener('click', () => command(
  (selectedMode === 'usb' ? !!state?.usb?.running : !!state?.bridge?.stream_active)
    ? 'stop_stream' : 'start_stream'));
document.querySelectorAll('.copy_address').forEach(button => button.addEventListener('click', async () => {
  const label = button.textContent;
  try {
    await navigator.clipboard.writeText($(button.dataset.target).textContent);
    button.textContent = '已复制';
    setTimeout(() => { button.textContent = label; }, 1500);
  } catch (error) { showError('无法复制，请选中地址手动复制'); }
}));
$('allow_lan').addEventListener('click', async () => {
  showError('');
  try {
    await requestFirewall();
  } catch (error) {
    showError(error.message);
    $('allow_lan').disabled = false;
  }
});
updateModeUI();
refresh();
setInterval(refresh, 1000);
