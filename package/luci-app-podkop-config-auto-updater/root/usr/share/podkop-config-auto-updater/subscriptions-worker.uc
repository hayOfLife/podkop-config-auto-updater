import * as fs from 'fs';
import { cursor } from 'uci';
import * as core from 'core';
import { subscriptionPatches } from 'subscriptions';
import { applyPatch, atomicWrite, writePrivate } from 'transaction';

const runtime = '/tmp/podkop-config-auto-updater';
const work = ARGV[1];
const testing = ARGV[0] == 'test';
const schedulePath = runtime + '/subscriptions-schedule.json';
const statusPath = runtime + '/subscriptions-status.json';
const helper = testing && fs.stat(work + '/fixture-io') ? work + '/fixture-io' : '/usr/libexec/podkop-config-auto-updater/io';
let accountCursor = testing && fs.stat(work + '/fixture-config/podkop_config_auto_updater') ?
	cursor(work + '/fixture-config', work + '/fixture-delta') : cursor();
let settings = accountCursor.get_all('podkop_config_auto_updater', 'main') || {};
let schedule = null;

function load(path) {
	try { return json(fs.readfile(path)) || {}; } catch (error) { return {}; }
}

function pending() {
	for (let path in ['/tmp/.uci/podkop', ...(fs.glob('/var/run/rpcd/uci-*/podkop') || [])])
		if (length(fs.readfile(path) || '')) return true;
	return false;
}

function accountUnchanged(account) {
	let check = testing && fs.stat(work + '/fixture-config/podkop_config_auto_updater') ?
		cursor(work + '/fixture-config', work + '/fixture-delta') : cursor();
	let latest = check.get_all('podkop_config_auto_updater', account['.name']) || {};
	let active = check.get_all('podkop_config_auto_updater', 'main') || {};
	if (active.enabled != '1' || active.subscriptions_enabled == '0') return false;
	for (let key in ['provider', 'login', 'password', 'url'])
		if ((latest[key] || '') != (account[key] || '')) return false;
	return true;
}

function randomMinute() {
	let source = fs.open('/dev/urandom', 'r');
	if (!source) die('random_failed');
	let byte = 255;
	while (byte >= 248) byte = ord(source.read(1));
	source.close();
	return byte % 31;
}

function getFeed(account, taskWork) {
	let url, uuid = null;
	if (account.provider == 'browsec') {
		if (type(account.login) != 'string' || !length(account.login) || length(account.login) > 320 ||
			type(account.password) != 'string' || !length(account.password) || length(account.password) > 4096 ||
			match(account.login, /[[:cntrl:]]/) || match(account.password, /[[:cntrl:]]/)) die('browsec_credentials_missing');
		writePrivate(taskWork + '/headers', 'Content-Type: application/json\nX-Browsec-Desktop-Version: 1.5.3\n' +
			'X-Browsec-Desktop-Os: linux\nX-Browsec-Desktop-Arch: x64\nX-Browsec-Channel: prod\nX-Browsec-Lang: ru\n');
		writePrivate(taskWork + '/auth-request', sprintf('%J', { email: account.login, password: account.password }));
		let ok = system([helper, 'browsec-auth', taskWork], 75000) == 0;
		fs.unlink(taskWork + '/auth-request');
		if (!ok) die('browsec_auth_failed');
		let response;
		try { response = json(fs.readfile(taskWork + '/auth-response.json')); } catch (error) { die('browsec_auth_failed'); }
		fs.unlink(taskWork + '/auth-response.json');
		if (response?.premium != true || type(response?.credentials?.access_token) != 'string' ||
			!length(response.credentials.access_token) || length(response.credentials.access_token) > 4096 ||
			match(response.credentials.access_token, /[[:space:][:cntrl:]]/) || type(response?.credentials?.xray_uuid) != 'string' ||
			!match(response.credentials.xray_uuid, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/))
			die('browsec_auth_failed');
		uuid = response.credentials.xray_uuid;
		url = 'https://browsec.com/api/desktop/v1/servers?uc=ru';
		writePrivate(taskWork + '/headers', 'Accept: application/json\nAuthorization: Bearer ' + response.credentials.access_token + '\n');
	}
	else if (account.provider == 'subix') {
		if (type(account.url) != 'string' || !match(account.url, /^https:\/\/subix\.ru\/[A-Za-z0-9_-]+\/?$/)) die('subix_invalid_url');
		url = account.url;
		writePrivate(taskWork + '/headers', 'Accept: */*\nUser-Agent: podkop/0.8.12\n');
	}
	else if (account.provider == 'neovps') {
		if (type(account.url) != 'string' || !match(account.url, /^https:\/\/neovps\.app\/s\/[A-Za-z0-9_-]+\/?$/)) die('neovps_invalid_url');
		url = account.url;
		writePrivate(taskWork + '/headers', 'Accept: */*\nUser-Agent: podkop/0.8.12\n');
	}
	else die('subscription_unknown_provider');
	writePrivate(taskWork + '/subscription-curl', 'url = "' + url + '"\n');
	if (system([helper, 'subscription-download', taskWork], 75000) != 0) {
		let reason = trim(fs.readfile(taskWork + '/download-error') || '');
		if (index(['download_proxy_dns_failed', 'download_dns_failed', 'download_connect_failed', 'download_timeout',
			'download_tls_failed', 'download_certificate_failed', 'download_ca_failed', 'download_too_large',
			'download_http_unauthorized', 'download_http_forbidden', 'download_http_not_found', 'download_http_rate_limited',
			'download_http_server_error', 'download_http_redirect', 'download_http_error'], reason) < 0) reason = 'subscription_download_failed';
		die(reason);
	}
	let data;
	try { data = json(fs.readfile(taskWork + '/feed.json')); } catch (error) { die('subscription_invalid_response'); }
	return { data, uuid };
}

function applyAccount(account, reuseExisting, taskWork) {
	if (pending()) die('pending_changes');
	let feed = getFeed(account, taskWork);
	if (!accountUnchanged(account)) die('subscription_changed');
	let original = fs.readfile('/etc/config/podkop');
	if (!original) die('invalid_podkop');
	let podkop = cursor();
	if (!podkop.load('podkop') || fs.readfile('/etc/config/podkop') != original) die('concurrent_change');
	let current = {};
	podkop.foreach('podkop', null, entry => { current[entry['.name']] = entry; });
	let result = subscriptionPatches(current, account, feed.data, feed.uuid, reuseExisting);
	let path = testing ? taskWork + '/test-live' : '/etc/config/podkop';
	if (testing) writePrivate(path, original);
	let changed = applyPatch({ work: taskWork, config: path, backup: taskWork + '/previous' }, result.patches, original,
		() => (!testing && pending()) || !accountUnchanged(account),
		testing ? () => true : () => system([helper, 'restart'], 180000) == 0, null, result.native);
	return { changed, count: result.count, skipped: result.skipped, excluded: result.excluded };
}

try {
	if (settings.enabled != '1' || settings.subscriptions_enabled == '0') exit(0);
	let permissions = fs.stat('/etc/config/podkop_config_auto_updater');
	if (!permissions || permissions.uid != 0 || (permissions.mode & 077) != 0) die('subscription_insecure_permissions');
	let accounts = [];
	accountCursor.foreach('podkop_config_auto_updater', 'subscription', account => { push(accounts, account); });
	if (!length(accounts)) { if (testing) print('{"state":"tested","accounts":0}\n'); exit(0); }
	let now = time(), schedules = load(schedulePath), previous = load(statusPath);
	if (now < 1735689600) die('clock_not_ready');
	let results = {}, errors = 0, changed = false, attempted = 0, reuseExisting = true, lastSuccess = previous.last_success || 0;
	for (let account in accounts) {
		let id = account['.name'], prior = previous.accounts?.[id] || {};
		if (type(id) != 'string' || !match(id, /^[A-Za-z_][A-Za-z0-9_]{0,39}$/)) die('subscription_invalid_id');
		let mayReuse = reuseExisting;
		if (account.provider == 'browsec') reuseExisting = false;
		let plan = core.planSchedule(now, schedules[id] || null, int(settings.interval_days || '1'),
			fs.readfile('/etc/TZ') || '', randomMinute());
		if (!testing && ARGV[0] == 'tick' && ((prior.next_retry && now < prior.next_retry) || (prior.last_success && !plan.due))) {
			results[id] = prior;
			if (prior.state == 'error') errors++;
			if (plan.changed) schedules[id] = plan.state;
			continue;
		}
		attempted++;
		try {
			let taskWork = work + '/account.' + id;
			if (!fs.mkdir(taskWork, 0700) || !fs.mkdir(taskWork + '/delta', 0700)) die('write_failed');
			let applied = applyAccount(account, mayReuse, taskWork);
			results[id] = { provider: account.provider, state: applied.changed ? 'applied' : 'unchanged',
				count: applied.count, skipped: applied.skipped, excluded: applied.excluded, last_success: now };
			changed = changed || applied.changed;
			lastSuccess = now;
			schedules[id] = plan.state;
		}
		catch (error) {
			let code = split(error.message || '', '\n')[0];
			if (!match(code, /^[a-z_]+$/)) code = 'subscription_internal_error';
			results[id] = { provider: account.provider, state: 'error', error: code,
				last_success: prior.last_success || 0, next_retry: now + 900 };
			errors++;
		}
	}
	let result = { state: errors ? 'error' : (changed ? 'applied' : 'unchanged'), time: now,
		last_success: lastSuccess, accounts: results, attempted };
	if (testing) { print(sprintf('%J\n', { ...result, state: errors ? 'error' : 'tested' })); exit(errors ? 1 : 0); }
	atomicWrite(schedulePath, sprintf('%J', schedules));
	atomicWrite(statusPath, sprintf('%J', result));
	print(sprintf('%J\n', result));
}
catch (error) {
	let code = split(error.message || '', '\n')[0];
	if (!match(code, /^[a-z_]+$/)) code = 'subscription_internal_error';
	let result = { state: 'error', time: time(), error: code };
	if (!testing) atomicWrite(statusPath, sprintf('%J', result));
	print(sprintf('%J\n', result));
	exit(1);
}
