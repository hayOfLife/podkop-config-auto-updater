// Проверяем выбор команды и сообщения настоящего LuCI view с подставным RPC без доступа к роутеру
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync('package/luci-app-podkop-config-auto-updater/htdocs/luci-static/resources/view/podkop_config_auto_updater/main.js', 'utf8');
let checks = 0;
function element(tag, attributes, children) {
	return {tag, attributes, children: Array.isArray(children) ? children : [children]};
}
function flatten(node) {
	return typeof node === 'string' ? node : (node?.children || []).map(flatten).join(' ');
}
function find(node, label) {
	if (node?.tag === 'button' && flatten(node) === label) return node;
	for (const child of node?.children || []) { const match = find(child, label); if (match) return match; }
}
async function fixture(exec) {
	const calls = [], modals = [], timers = new Map();
	class FormMap {
		section() { return {option() { return {value() {}}; }}; }
		render() { return Promise.resolve(element('form', {}, [])); }
	}
	const view = vm.runInNewContext('(function() {\n' + source + '\n})()', {
		E: element, view: {extend: value => value}, form: {Map: FormMap},
		fs: {exec(path, args) { calls.push([path, [...args]]); return exec(path, args); }},
		ui: {createHandlerFn: (owner, handler) => handler.bind(owner), hideModal() {},
			showModal(title, content) { modals.push(content.map(flatten).join(' ')); }},
		poll: {add(fn, interval) { timers.set(fn, interval); }, remove(fn) { timers.delete(fn); }}
	});
	const tree = await view.render({enabled: true, software: {state: 'idle'}});
	return {tree, calls, modals, timers};
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
console.log(`LuCI actions: ${checks} command routing, popup and background completion scenarios passed`);
