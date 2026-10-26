import * as fs from 'fs';
import { cursor } from 'uci';
import * as core from 'core';
import { parseConfig, selectConfig, configFields, mergeConfig } from 'config';
import { sourceRequest } from 'source';
import { applyPatch, atomicWrite, writePrivate } from 'transaction';

const statePath = '/tmp/podkop-config-auto-updater/schedule.json';
const statusPath = '/tmp/podkop-config-auto-updater/status.json';
const helper = '/usr/libexec/podkop-config-auto-updater/io';
const work = ARGV[1];
const testing = ARGV[0] == 'test';
let config = cursor().get_all('podkop_config_auto_updater', 'main') || {};
let ignored = config.ignored_options || [];
if (type(ignored) == 'string') ignored = [ignored];
let progress = { downloaded: false, parsed: false, valid: false };
let schedule;
if (!testing) {
	try { schedule = json(fs.readfile(statePath)); } catch (e) { schedule = null; }
}

function status(result) {
	let parts = split(work, '/');
	result.operation = parts[length(parts) - 1];
	result.time = time();
	result.enabled = config.enabled == '1';
	result.next_run = schedule?.next || null;
	atomicWrite(statusPath, sprintf('%J', result));
	if (result.state != 'running') print(sprintf('%J\n', result));
}

function pending() {
	for (let path in ['/tmp/.uci/podkop', ...(fs.glob('/var/run/rpcd/uci-*/podkop') || [])])
		if (length(fs.readfile(path) || '')) return true;
	return false;
}

function randomMinute() {
	let source = fs.open('/dev/urandom', 'r');
	if (!source) die('random_failed');
	let byte = 255;
	// Отбрасываем остаток диапазона байта, чтобы все 31 значение были равновероятны
	while (byte >= 248) byte = ord(source.read(1));
	source.close();
	return byte % 31;
}

function fetchFeed() {
	let request = sourceRequest(config.config_url, config.github_token);
	writePrivate(work + '/headers', request.headers);
	let downloaded = system([helper, 'download', work, request.url], 75000) == 0;
	fs.unlink(work + '/headers');
	if (!downloaded) {
		let error = trim(fs.readfile(work + '/download-error') || '');
		if (index(['download_proxy_dns_failed', 'download_dns_failed', 'download_connect_failed',
			'download_timeout', 'download_tls_failed', 'download_certificate_failed', 'download_ca_failed',
			'download_too_large', 'download_http_unauthorized', 'download_http_forbidden', 'download_http_not_found',
			'download_http_rate_limited', 'download_http_server_error', 'download_http_redirect', 'download_http_error'], error) < 0)
			error = 'download_failed';
		die(error);
	}
	progress.downloaded = true;

	let data = fs.readfile(work + '/feed.json');
	if (!data || length(data) > 1048576) die('invalid_size');
	let parsed;
	try { parsed = parseConfig(data); } catch (e) { die('invalid_json'); }
	progress.parsed = true;

	let feed = selectConfig(parsed, ignored);
	progress.valid = true;
	atomicWrite('/tmp/podkop-config-auto-updater/fields.json', sprintf('%J', { fields: configFields(parsed) }));
	return feed;
}

function update() {
	if (!fs.stat('/etc/init.d/podkop')) die('podkop_missing');
	if (pending()) die('pending_changes');
	status({ state: 'running', stage: 'downloading' });
	let feed = fetchFeed();
	status({ state: 'running', stage: 'preparing', revision: feed.revision });

	let original = fs.readfile('/etc/config/podkop');
	if (!original) die('podkop_missing');
	let podkop = cursor();
	if (!podkop.load('podkop')) die('invalid_podkop');
	let section = podkop.get_all('podkop', 'main') || {};
	let merged = mergeConfig(section, podkop.get_all('podkop', 'settings') || {}, feed, config.allow_deletes == '1', ignored,
		podkop.get_all('podkop', 'notUnderSanctions') || {});
	let changed = applyPatch({ work, config: '/etc/config/podkop', backup: '/tmp/podkop-config-auto-updater/previous-podkop' },
		merged.patches, original, pending, () => {
			status({ state: 'running', stage: 'restarting', revision: feed.revision });
			return system([helper, 'restart'], 180000) == 0;
		}, merged.order);
	status({ state: changed ? 'applied' : 'unchanged', revision: feed.revision, counts: merged.counts });
}

try {
	if (testing) {
		let feed = fetchFeed();
		print(sprintf('%J\n', { state: 'tested', ...progress, revision: feed.revision }));
		exit(0);
	}

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
	if (testing) print(sprintf('%J\n', { state: 'error', error: code, ...progress }));
	else status({ state: 'error', error: code });
	exit(1);
}
