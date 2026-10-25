import * as fs from 'fs';
import { cursor } from 'uci';
import { atomicWrite, writePrivate } from 'transaction';
import { classifyProbe, planProbe } from 'health';

const base = '/tmp/podkop-config-auto-updater';
const helper = '/usr/libexec/podkop-config-auto-updater/health-io';
const groupTag = 'notUnderSanctions-out';
const work = ARGV[1];
const mode = ARGV[0];
let config = cursor().get_all('podkop_config_auto_updater', 'main') || {};
let section = cursor().get_all('podkop', 'notUnderSanctions') || {};
let state;
let fingerprint;

function load(path) {
	try { return json(fs.readfile(path)); } catch (e) { return null; }
}

function safeTag(value) {
	return type(value) == 'string' && length(value) <= 128 && index(value, '\u0000') < 0 &&
		!match(value, /[[:space:][:cntrl:]]/) && match(value, /^notUnderSanctions-[A-Za-z0-9_-]+$/);
}

function emptyState() {
	return { version: 1, fingerprint, previous: null, owned: null, pending: null, plan: null, cooldowns: {}, next_check: 0 };
}

function save() {
	atomicWrite(base + '/health-state.json', sprintf('%J', state));
}

function report(name, error) {
	let result = { state: name, checked_at: state?.checked_at || null,
		next_check: state?.next_check || null, selected: safeTag(state?.owned) ? state.owned : null,
		failures: state?.plan?.failures || 0 };
	if (error) result.error = error;
	atomicWrite(base + '/health.json', sprintf('%J', result));
	print(sprintf('%J\n', result));
}

function run(action, timeout) {
	if (system([helper, action, work], timeout) != 0) die('api_unavailable');
}

function currentHash() {
	run('hash', 3000);
	let lines = split(fs.readfile(work + '/config-hash') || '', '\n');
	let value = substr(lines[0] || '', 0, 64);
	let runtime = substr(lines[1] || '', 0, 64);
	if (!match(value, /^[a-f0-9]{64}$/) || (runtime != 'missing' && !match(runtime, /^[a-f0-9]{64}$/))) die('invalid_runtime');
	return value + ':' + runtime;
}

function discover() {
	run('discover', 10000);
	let address, secret;
	if (trim(fs.readfile(work + '/backend') || '') == 'experimental') {
		if (load(work + '/runtime-status.json')?.running !== true) die('api_unavailable');
		let facts = load(work + '/runtime-facts.json');
		address = facts?.clash_api;
		secret = facts?.clash_secret || '';
	}
	else {
		let text = fs.readfile(work + '/runtime-config.json') || '';
		let start = index(text, '{');
		let runtime;
		try { runtime = start < 0 ? null : json(substr(text, start)); } catch (e) { die('invalid_runtime'); }
		address = runtime?.experimental?.clash_api?.external_controller;
		secret = runtime?.experimental?.clash_api?.secret || '';
	}
	if (type(address) != 'string' || index(address, '\u0000') >= 0 || type(secret) != 'string' ||
		length(secret) > 8192 || index(secret, '\u0000') >= 0 || match(secret, /[[:space:][:cntrl:]]/))
		die('invalid_runtime');
	let parts = split(address, ':');
	let ip = length(parts) == 2 ? iptoarr(parts[0]) : null;
	if (!ip || length(ip) != 4 || !match(parts[1], /^[0-9]{1,5}$/) || int(parts[1]) < 1 || int(parts[1]) > 65535)
		die('invalid_runtime');
	if (parts[0] == '0.0.0.0') parts[0] = '127.0.0.1';
	else if (!(ip[0] == 127 || ip[0] == 10 || (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) ||
		(ip[0] == 192 && ip[1] == 168) || (ip[0] == 169 && ip[1] == 254))) die('invalid_runtime');
	writePrivate(work + '/api-url', 'http://' + parts[0] + ':' + parts[1]);
	writePrivate(work + '/api-headers', secret ? 'Authorization: Bearer ' + secret + '\n' : '');
}

function snapshot(optional) {
	if (currentHash() != fingerprint) die('selection_changed');
	run('proxies', 5000);
	let proxies = load(work + '/proxies.json')?.proxies;
	let group = type(proxies) == 'object' ? proxies[groupTag] : null;
	if (optional && type(proxies) == 'object' && (!group || lc(group.type || '') != 'selector'))
		return { proxies, group: null, pool: [] };
	if (!group || lc(group.type || '') != 'selector' || type(group.all) != 'array' || !safeTag(group.now))
		die('invalid_runtime');
	let pool = [], seen = {};
	for (let tag in group.all) {
		if (!safeTag(tag) || seen[tag]) continue;
		let proxy = proxies[tag];
		if (!proxy || type(proxy.type) != 'string' || !length(proxy.type) ||
			index(['direct', 'block', 'reject', 'dns', 'selector', 'urltest', 'fallback', 'loadbalance', 'pass', 'compatible'], lc(proxy.type)) >= 0 ||
			type(proxy.all) == 'array' || exists(proxy, 'now')) continue;
		push(pool, tag);
		seen[tag] = true;
	}
	return { proxies, group, pool };
}

function leaf(snap) {
	let tag = snap.group.now, seen = {};
	for (let step = 0; step < 8; step++) {
		if (!safeTag(tag) || seen[tag]) return null;
		if (index(snap.pool, tag) >= 0) return tag;
		seen[tag] = true;
		let proxy = snap.proxies[tag];
		if (!proxy || index(['urltest', 'selector'], lc(proxy.type || '')) < 0) return null;
		tag = proxy.now;
	}
	return null;
}

function select(tag, expected) {
	let before = snapshot();
	if (before.group.now != expected) die('selection_changed');
	if (!safeTag(tag) || index(before.group.all, tag) < 0) die('selection_failed');
	writePrivate(work + '/select.json', sprintf('%J', { name: tag }));
	if (system([helper, 'select', work], 5000) != 0) die('selection_failed');
	let after = snapshot();
	if (after.group.now != tag) die('selection_changed');
	return after;
}

function own(tag, expected) {
	// Незавершённый API-вызов сверяется с фактическим выбором перед следующим действием
	state.pending = { from: expected, to: tag };
	save();
	let after = expected == tag ? snapshot() : select(tag, expected);
	if (after.group.now != tag) die('selection_changed');
	state.owned = tag;
	state.pending = null;
	save();
	return after;
}

function reconcile(snap) {
	if (!state.pending) return;
	if (snap.group.now == state.pending.to) state.owned = state.pending.to;
	else if (snap.group.now != state.pending.from) die('selection_changed');
	state.pending = null;
	save();
}

function randomPort() {
	let source = fs.open('/dev/urandom', 'r');
	if (!source) die('io_failed');
	let bytes = source.read(2);
	source.close();
	if (length(bytes) != 2) die('io_failed');
	return 40000 + (ord(substr(bytes, 0, 1)) * 256 + ord(substr(bytes, 1, 1))) % 20001;
}

function probe(selected) {
	report('checking');
	if (system([helper, 'probe', work, '' + randomPort(), selected], 28000) != 0) die('io_failed');
	let after = snapshot();
	if (after.group.now != state.owned) die('selection_changed');
	let metrics = split(fs.readfile(work + '/probe-metrics') || '', '\n');
	let localIP = iptoarr(metrics[2] || '');
	if (!localIP || length(localIP) != 4) return 'route_unconfirmed';
	let confirmed = false, mismatch = false;
	for (let line in split(fs.readfile(work + '/proof') || '', '\n')) {
		let observation;
		try { observation = json(line); } catch (e) { continue; }
		let sourceIP = iptoarr(observation?.source || '');
		if (!sourceIP || arrtoip(sourceIP) != arrtoip(localIP)) continue;
		if (observation.confirmed === true) confirmed = true;
		else mismatch = true;
	}
	if (!confirmed || mismatch) return 'route_unconfirmed';
	let code = int(trim(fs.readfile(work + '/probe-exit') || '1'));
	let body = fs.readfile(work + '/probe-body') || '';
	let httpStatus = match(metrics[0] || '', /^[0-9]{3}$/) ? int(metrics[0]) : 0;
	if (length(body) > 16384 || code == 63 || code == 153) {
		let limited = classifyProbe(code || 63, httpStatus, '');
		return index(['rate_limited', 'service_error'], limited) >= 0 ? limited : 'unknown';
	}
	return classifyProbe(code, httpStatus, body);
}

function candidate(snap, selected, now) {
	let start = index(snap.pool, selected);
	for (let offset = 1; offset <= length(snap.pool); offset++) {
		let tag = snap.pool[(start + offset) % length(snap.pool)];
		if (tag != selected && (state.cooldowns[tag] || 0) <= now) return tag;
	}
	return null;
}

function noCandidates() {
	let next = time() + 180;
	for (let tag, until in state.cooldowns)
		if (until > time() && (next == 0 || until < next)) next = until;
	state.next_check = next;
	save();
	report('no_eligible_nodes');
}

function release(name) {
	if (!state.owned && !state.pending) { state = emptyState(); save(); report(name); return; }
	fingerprint = currentHash();
	if (state.fingerprint != fingerprint && state.previous != 'notUnderSanctions-urltest-out') {
		state = emptyState(); save(); report(name); return;
	}
	discover();
	let snap = snapshot(true);
	if (!snap.group) { state = emptyState(); save(); report(name); return; }
	if (state.fingerprint == fingerprint) reconcile(snap);
	else state.pending = null;
	if (snap.group.now == state.owned && state.previous != state.owned && index(snap.group.all, state.previous) >= 0)
		select(state.previous, state.owned);
	state = emptyState();
	save();
	report(name);
}

function relinquish() {
	let snap = snapshot();
	if (snap.group.now != state.owned) die('selection_changed');
	if (state.previous != state.owned && index(snap.group.all, state.previous) >= 0)
		select(state.previous, state.owned);
	state.owned = null;
	state.previous = null;
	state.pending = null;
}

try {
	state = load(base + '/health-state.json');
	if (type(state) != 'object' || state.version !== 1 || type(state.cooldowns) != 'object' ||
		(state.owned != null && !safeTag(state.owned)) || (state.previous != null && !safeTag(state.previous)) ||
		(state.pending != null && (!safeTag(state.pending.from) || !safeTag(state.pending.to)))) state = emptyState();
	if (type(state.next_check) != 'int' || state.next_check > time() + 600) state.next_check = 0;
	if (state.plan && (!safeTag(state.plan.selected) || type(state.plan.failures) != 'int' ||
		state.plan.failures < 0 || state.plan.failures > 3)) state.plan = null;
	for (let tag, until in state.cooldowns)
		if (!safeTag(tag) || type(until) != 'int' || until <= time() || until > time() + 3600) delete state.cooldowns[tag];
	if (mode != 'tick' && mode != 'release') die('io_failed');
	if (mode == 'release' || config.enabled != '1' || config.openai_check_enabled == '0') {
		release('disabled');
		exit(0);
	}
	let links = section.urltest_proxy_links || [];
	if (section['.type'] != 'section' || section.connection_type != 'proxy' || section.proxy_config_type != 'urltest' || !length(links)) {
		state.next_check = 0;
		report('not_configured');
		exit(0);
	}
	fingerprint = currentHash();
	let priorOwner = null;
	if (state.fingerprint != fingerprint) {
		if (state.previous == 'notUnderSanctions-urltest-out' && state.owned) priorOwner = state;
		state = emptyState();
	}
	if (state.next_check > time()) exit(0);
	discover();
	let snap = snapshot();
	if (priorOwner && snap.group.now == priorOwner.owned && index(snap.group.all, priorOwner.previous) >= 0) {
		state.previous = priorOwner.previous;
		state.owned = priorOwner.owned;
	}
	reconcile(snap);
	if (state.owned && snap.group.now != state.owned) die('selection_changed');
	if (!length(snap.pool)) { noCandidates(); exit(0); }
	let selected = leaf(snap);
	if (!selected) { noCandidates(); exit(0); }
	if (!state.owned) {
		state.previous = snap.group.now;
		snap = own(selected, snap.group.now);
	}
	for (let count = 0; count < 2; count++) {
		if ((state.cooldowns[selected] || 0) > time()) {
			let next = candidate(snap, selected, time());
			if (!next) { noCandidates(); exit(0); }
			snap = own(next, selected);
			selected = next;
		}
		let result = probe(selected);
		let now = time();
		state.checked_at = now;
		state.plan = planProbe(state.plan, selected, result, now);
		state.next_check = state.plan.next_check;
		if (state.plan.action != 'rotate') {
			// Неподтверждённый маршрут не должен отключать прежний автоматический выбор навсегда
			if (result == 'route_unconfirmed') relinquish();
			save();
			report(result == 'reachable' ? 'healthy' : result);
			exit(0);
		}
		state.cooldowns[selected] = now + (result == 'region_blocked' ? 3600 : 300);
		save();
		snap = snapshot();
		if (snap.group.now != state.owned) die('selection_changed');
		let next = candidate(snap, selected, now);
		if (!next) { noCandidates(); exit(0); }
		if (count == 1) {
			state.next_check = now + 30;
			save();
			report(result);
			exit(0);
		}
		snap = own(next, selected);
		selected = next;
	}
}
catch (error) {
	let code = split(error.message || '', '\n')[0];
	if (code == 'selection_changed') {
		state = emptyState();
		state.next_check = time() + 180;
		save();
		report('selection_changed');
		exit(0);
	}
	if (index(['api_unavailable', 'invalid_runtime', 'selection_failed', 'io_failed'], code) < 0) code = 'io_failed';
	state.next_check = time() + 180;
	save();
	report('error', code);
	exit(1);
}
