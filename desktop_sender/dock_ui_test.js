'use strict';
// Exercise the shipped UI with a live-status fixture and its actual click handlers.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');

function dock() {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      value: '', textContent: '', disabled: false, hidden: false, handlers: {},
      setAttribute() {}, replaceChildren() {},
      addEventListener(event, fn) { this.handlers[event] = fn; },
    });
    return elements.get(id);
  };
  let state = {
    ready: false, obs_error: 'OBS is not ready to perform the request.',
    token: 'fixture', addresses: ['192.168.1.45'], bridge: {},
    usb: {native_available: true, ready: true, running: false},
  };
  const requests = [];
  const context = vm.createContext({
    document: {getElementById: element, querySelectorAll: () => []},
    localStorage: {getItem: () => 'usb', setItem() {}},
    Option: function(text, value) { this.text = text; this.value = value; },
    setInterval() {}, setTimeout() {},
    fetch: async (url, options) => {
      if (url === '/api/command') {
        const command = JSON.parse(options.body);
        requests.push(command);
        state.usb.running = command.action !== 'stop_stream';
        state.bridge.last_command = 'done';
        return {ok: true, json: async () => ({id: 'done'})};
      }
      return {ok: true, json: async () => structuredClone(state)};
    },
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../obs-plugin/dock/app.js'), 'utf8'), context);
  return {element, requests, state, refresh: () => vm.runInContext('refresh()', context)};
}

test('USB prepare, stop and restart remain usable while OBS stream control returns 207', async () => {
  const ui = dock();
  await ui.refresh();
  assert.equal(ui.element('configure').disabled, false);
  assert.equal(ui.element('broadcast').disabled, false);
  assert.equal(ui.element('status').textContent, '尚未准备 USB 直连');
  await ui.element('configure').handlers.click();
  assert.equal(ui.requests[0].mode, 'usb');
  assert.equal(ui.element('broadcast').textContent, '停止直连');
  await ui.element('broadcast').handlers.click();
  await ui.element('broadcast').handlers.click();
  assert.deepEqual(ui.requests.map(r => [r.action, r.mode]), [
    ['configure_stream', 'usb'], ['stop_stream', 'usb'], ['start_stream', 'usb'],
  ]);
});

test('USB missing endpoint disables prepare, while an active sender can still be stopped', async () => {
  const ui = dock();
  ui.state.usb.ready = false;
  ui.state.usb.control_error = 'USB module unavailable';
  await ui.refresh();
  assert.equal(ui.element('configure').disabled, true);
  assert.equal(ui.element('detail').textContent, 'USB module unavailable');
  ui.state.usb.running = true;
  await ui.refresh();
  assert.equal(ui.element('broadcast').disabled, false);
});

test('LAN continues to report unavailable streaming control', async () => {
  const ui = dock();
  await ui.refresh();
  ui.element('mode_lan').handlers.click();
  await ui.refresh();
  assert.equal(ui.element('configure').disabled, true);
  assert.equal(ui.element('status').textContent, 'OBS 直播控制未就绪');
});
