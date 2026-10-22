import * as fs from 'fs';
import { cursor } from 'uci';
import * as core from 'core';
import { sourceRequest } from 'source';
import { applyPatch, atomicWrite, writePrivate } from 'transaction';

const statePath = '/etc/podkop-config-auto-updater/schedule.json';
const statusPath = '/tmp/podkop-config-auto-updater/status.json';
const helper = '/usr/libexec/podkop-config-auto-updater/io';
const work = ARGV[1];
let config = cursor().get_all('podkop_config_auto_updater', 'main') || {};
let schedule;
try { schedule = json(fs.readfile(statePath)); } catch (e) { schedule = null; }

function status(result) {
	result.time = time();
	result.enabled = config.enabled == '1';
	result.next_run = schedule?.next || null;
	atomicWrite(statusPath, sprintf('%J', result));
	print(sprintf('%J\n', result));
}

function pending() {
	for (let path in ['/tmp/.uci/podkop', ...(fs.glob('/var/run/rpcd/uci-*/podkop') || [])])
		if (length(fs.readfile(path) || '')) return true;
	return false;
}

function randomMinute() {
	let source = fs.open('/dev/urandom', 'r');
	if (!source) die('random_failed');
	let byte;
	// Отбрасываем остаток диапазона байта, чтобы все 31 значение были равновероятны
	do { byte = ord(source.read(1)); } while (byte >= 248);
	source.close();
	return byte % 31;
}

function update() {
	if (!fs.stat('/etc/init.d/podkop')) die('podkop_missing');
	if (pending()) die('pending_changes');
	let request = sourceRequest(config.config_url, config.github_token);
	writePrivate(work + '/headers', request.headers);
	if (system([helper, 'download', work, request.url], 75000) != 0) die('download_failed');
	fs.unlink(work + '/headers');
	let data = fs.readfile(work + '/feed.json');
	if (!data || length(data) > 1048576) die('invalid_size');
	let parsed;
	try { parsed = json(data); } catch (e) { die('invalid_json'); }
	let feed = core.validateFeed(parsed);
	let original = fs.readfile('/etc/config/podkop');
	if (!original) die('podkop_missing');
	let podkop = cursor();
	if (!podkop.load('podkop')) die('invalid_podkop');
	let section = podkop.get_all('podkop', 'main') || {};
	let merged = core.mergeSection(section, feed, config.allow_deletes == '1');
	let changed = applyPatch({ work, config: '/etc/config/podkop', backup: '/etc/podkop-config-auto-updater/previous-podkop' },
		merged.patch, original, pending, () => system([helper, 'restart'], 180000) == 0);
	status({ state: changed ? 'applied' : 'unchanged', revision: feed.revision, counts: merged.counts });
}

try {
	if (ARGV[0] == 'tick') {
		if (config.enabled != '1') exit(0);
		let now = time();
		if (now < 1735689600) die('clock_not_ready');
		let interval = int(config.interval_days || '1');
		let timezone = fs.readfile('/etc/TZ') || '';
		let plan = core.planSchedule(now, schedule, interval, timezone, randomMinute());
		schedule = plan.state;
		if (plan.changed) atomicWrite(statePath, sprintf('%J', schedule));
		if (!plan.due) exit(0);
	}
	update();
}
catch (error) {
	let code = split(error.message || '', '\n')[0];
	if (!match(code, /^[a-z_]+$/)) code = 'internal_error';
	status({ state: 'error', error: code });
	exit(1);
}
