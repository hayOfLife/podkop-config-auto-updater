// Проверяем выбор команды и сообщения настоящего LuCI view с подставным RPC без доступа к роутеру
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync('package/luci-app-podkop-config-auto-updater/htdocs/luci-static/resources/view/podkop_config_auto_updater/main.js', 'utf8');
let checks = 0;
function element(tag, attributes, children) {
	return {tag, attributes, style: {}, children: Array.isArray(children) ? children : [children]};
}
function flatten(node) {
	return typeof node === 'string' ? node : (node?.textContent ?? (node?.children || []).map(flatten).join(' '));
}
function find(node, label) {
	if (node?.tag === 'button' && flatten(node) === label) return node;
	for (const child of node?.children || []) { const match = find(child, label); if (match) return match; }
}
async function fixture(exec, initial = {}) {
	const calls = [], modals = [], timers = new Map(), options = {};
	const settings = {...initial};
	const enabledNode = element('span', {}, []);
	class FormMap {
		section() { return {option(type, name) { return options[name] = {value() {}}; }}; }
		render() {
			const form = element('form', {}, Object.values(options).map(option => option.description));
			form.querySelector = selector => selector === '#podkop-updater-enabled' ? enabledNode : null;
			return Promise.resolve(form);
		}
	}
	const view = vm.runInNewContext('(function() {\n' + source + '\n})()', {
		E: element, view: {extend: value => value}, form: {Map: FormMap},
		uci: {load: () => Promise.resolve(), get: (config, section, key) => settings[key],
			set: (config, section, key, value) => { settings[key] = value; },
			unset: (config, section, key) => { delete settings[key]; }},
		fs: {exec(path, args) { calls.push([path, [...args]]); return exec(path, args); }},
		ui: {createHandlerFn: (owner, handler) => handler.bind(owner), hideModal() {},
			showModal(title, content) { modals.push(content.map(flatten).join(' ')); }},
		poll: {add(fn, interval) { timers.set(fn, interval); }, remove(fn) { timers.delete(fn); }}
	});
	const tree = await view.render({enabled: true, software: {state: 'idle'}, fields: ['main.future_option', 'settings.dns_server']});
	return {tree, calls, modals, timers, options, enabledNode, settings};
}

for (const report of [
	{state: 'tested', downloaded: true, parsed: true, valid: true},
	{state: 'error', error: 'invalid_json', downloaded: true, parsed: false, valid: false},
	{state: 'error', error: 'invalid_schema', downloaded: true, parsed: true, valid: false},
	{state: 'error', error: 'download_failed', downloaded: false, parsed: false, valid: false},
	{state: 'error', error: 'busy'}
]) {
	const app = await fixture(() => Promise.resolve({code: report.valid ? 0 : 1, stdout: JSON.stringify(report)}));
	await find(app.tree, 'Тест соединения').attributes.click();
	assert.deepEqual(app.calls.map(call => call[1]), [['test']]);
	assert.match(app.modals.at(-1), report.valid ? /Тест соединения пройден/ : /Тест соединения не пройден/);
	assert.match(app.modals.at(-1), /Настройки Podkop не изменялись/);
	if (report.downloaded) assert.match(app.modals.at(-1), /Файл скачан: да/);
	if (report.parsed) assert.match(app.modals.at(-1), /JSON разобран: да/);
	checks++;
}

for (const failure of ['broken demo_secret_json', null]) {
	const app = await fixture(() => failure ? Promise.resolve({code: 1, stdout: failure}) : Promise.reject(new Error('demo_secret_rpc')));
	await find(app.tree, 'Тест соединения').attributes.click();
	assert.match(app.modals.at(-1), /не пройден/);
	assert.doesNotMatch(app.modals.at(-1), /demo_secret/);
	checks++;
}

for (const [label, target] of [['Обновить подкоп', 'podkop'], ['Обновить себя', 'self']]) {
	let finished = false;
	const app = await fixture((path, args) => Promise.resolve({code: 0, stdout: JSON.stringify({state: finished ? 'updated' : 'running', target, stage: 'checking'})}));
	await find(app.tree, label).attributes.click();
	assert.deepEqual(app.calls.map(call => call[1]), [[target], ['status']]);
	assert.ok(app.calls.every(call => call[0].endsWith('/software')));
	assert.match(app.modals.at(-1), /продолжится в фоне/);
	finished = true;
	const timer = [...app.timers.entries()].find(([, interval]) => interval === 3)[0];
	await timer();
	assert.match(app.modals.at(-1), /обновлён/);
	assert.equal(app.timers.has(timer), false);
	checks++;
}

for (const [result, expected] of [
	[{code: 1, stdout: '', stderr: "Syntax error: Unable to compile module demo_secret"}, /ошибка компиляции ucode/],
	[{code: 1, stdout: '', stderr: 'demo_secret'}, /завершился без результата/],
	[new Error('RPC Access denied demo_secret'), /LuCI отказал/],
	[new Error('Request timed out demo_secret'), /LuCI не дождался/]
]) {
	const app = await fixture(() => result instanceof Error ? Promise.reject(result) : Promise.resolve(result));
	await find(app.tree, 'Тест соединения').attributes.click();
	assert.match(app.modals.at(-1), expected);
	assert.doesNotMatch(app.modals.at(-1), /demo_secret/);
	checks++;
}

const statusApp = await fixture(() => Promise.resolve({stdout: JSON.stringify({enabled: false})}));
assert.match(statusApp.options.enabled.description, /id="podkop-updater-enabled"/);
assert.equal(statusApp.enabledNode.textContent, 'Программа "Podkop config auto updater" работает');
assert.equal(statusApp.enabledNode.style.color, '#22863a');
const statusTimer = [...statusApp.timers.entries()].find(([, interval]) => interval === 30)[0];
await statusTimer();
assert.equal(statusApp.enabledNode.textContent, 'Программа "Podkop config auto updater" выключена');
assert.equal(statusApp.enabledNode.style.color, '#b94a48');
assert.match(statusApp.options.github_token.description, /<a href="https:\/\/github.com/);
checks++;

for (const [error, expected] of [
	['download_http_unauthorized', /HTTP 401/], ['download_http_forbidden', /HTTP 403/],
	['download_http_not_found', /также означает отсутствие доступа/], ['download_http_rate_limited', /HTTP 429/],
	['download_timeout', /Истёк срок/], ['download_dns_failed', /IP-адрес сервера/],
	['download_certificate_failed', /не прошёл проверку/]
]) {
	const app = await fixture(() => Promise.resolve({code: 1, stdout: JSON.stringify({state: 'error', error, downloaded: false, parsed: false, valid: false})}));
	await find(app.tree, 'Тест соединения').attributes.click();
	assert.match(app.modals.at(-1), expected);
	checks++;
}
const selection = await fixture(() => Promise.resolve({}), {ignored_options: ['settings.dns_server']});
assert.equal(selection.options._apply_main_user_domains.cfgvalue('main'), '1');
assert.equal(selection.options._apply_main_future_option.cfgvalue('main'), '1');
assert.equal(selection.options._apply_settings_dns_server.cfgvalue('main'), '0');
assert.equal(selection.options._heading_main.cfgvalue(), '<h3>Секция MAIN</h3>');
assert.equal(selection.options._heading_settings.cfgvalue(), '<h3>Общие настройки Podkop</h3>');
const fieldOrder = Object.keys(selection.options);
assert.ok(fieldOrder.indexOf('_apply_main_future_option') < fieldOrder.indexOf('_heading_settings'));
assert.ok(fieldOrder.indexOf('_apply_settings_dns_server') > fieldOrder.indexOf('_heading_settings'));
selection.options._apply_main_user_domains.write('main', '0');
assert.deepEqual([...selection.settings.ignored_options], ['settings.dns_server', 'main.user_domains']);
selection.options._apply_settings_dns_server.write('main', '1');
assert.deepEqual([...selection.settings.ignored_options], ['main.user_domains']);
selection.options._apply_main_user_domains.write('main', '1');
assert.equal(selection.settings.ignored_options, undefined);
assert.equal(selection.calls.length, 0);
checks++;
console.log(`LuCI actions: ${checks} command routing, popup, selection and background completion scenarios passed`);
