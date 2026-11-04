import * as fs from 'fs';
import { cursor } from 'uci';
import { resetConfig, atomicWrite, writePrivate } from 'transaction';

const work = ARGV[0];
const runtime = '/tmp/podkop-config-auto-updater';
const helper = '/usr/libexec/podkop-config-auto-updater/io';
const softwareHelper = '/usr/libexec/podkop-config-auto-updater/software-io';
let variant, installedVersion, stockURL;
let stage = 'reset_preparing';

function load(path) {
	try { return json(fs.readfile(path)) || {}; } catch (e) { return {}; }
}

function status(state, extra) {
	let config = cursor().get_all('podkop_config_auto_updater', 'main') || {};
	let parts = split(work, '/');
	let result = { state, action: 'reset', stage, operation: parts[length(parts) - 1], time: time(),
		variant, installed_version: installedVersion, enabled: config.enabled == '1',
		next_run: load(runtime + '/schedule.json').next || null, ...extra };
	atomicWrite(runtime + '/status.json', sprintf('%J', result));
	if (state != 'running') print(sprintf('%J\n', result));
}

function pending() {
	for (let path in ['/tmp/.uci/podkop', ...(fs.glob('/var/run/rpcd/uci-*/podkop') || [])])
		if (length(fs.readfile(path) || '')) return true;
	return false;
}

function version(name) {
	if (system([softwareHelper, 'version', name, work], 5000) != 0) die('package_query_failed');
	let value = trim(fs.readfile(work + '/version') || '');
	if (value && (match(value, /[[:space:][:cntrl:]]/) || !match(value, /^v?[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/)))
		die('invalid_installed_version');
	return value;
}

function running() {
	if (system([helper, 'service-state', variant, work], 10000) != 0) die('reset_service_state_failed');
	let value;
	try { value = json(fs.readfile(work + '/service-state.json')); } catch (e) { die('reset_service_state_failed'); }
	if (type(value) != 'object') die('reset_service_state_failed');
	let name = variant == 'stable' ? 'sing-box' : 'podkop';
	if (!exists(value, name)) return false;
	let service = value[name];
	if (type(service) != 'object' || type(service.instances) != 'object') die('reset_service_state_failed');
	let active = false;
	for (let key, instance in service.instances) {
		if (type(instance) != 'object' || type(instance.running) != 'bool') die('reset_service_state_failed');
		if (instance.running) active = true;
	}
	return active;
}

try {
	if (!fs.stat('/etc/init.d/podkop')) die('podkop_missing');
	if (pending()) die('pending_changes');
	let original = fs.readfile('/etc/config/podkop');
	if (original == null) die('podkop_missing');
	status('running', {});
	let stable = version('podkop'), experimental = version('podkop-exp');
	if (stable && experimental) die('podkop_variant_conflict');
	if (!stable && !experimental) die('podkop_package_missing');
	variant = experimental ? 'experimental' : 'stable';
	installedVersion = experimental || stable;
	let release = replace(replace(installedVersion, /^v/, ''), /-r[0-9]+$/, '');
	let parts = split(release, '.');
	if (int(parts[0]) != 0 || (variant == 'stable' ? int(parts[1]) != 7 : int(parts[1]) != 8)) die('reset_unsupported_version');
	let native = variant == 'experimental' && int(parts[2]) >= 8;
	let repository = experimental ? 'podkop-net/podkop-experimental' : 'itdoginfo/podkop';
	let tag = (experimental ? 'v' : '') + release;
	stockURL = 'https://raw.githubusercontent.com/' + repository + '/' + tag + '/podkop/files/etc/config/podkop';
	stage = 'reset_downloading';
	status('running', {});
	writePrivate(work + '/headers', '');
	if (system([helper, 'reset-default', work, stockURL], 75000) != 0) {
		let error = trim(fs.readfile(work + '/download-error') || '');
		if (!match(error, /^download_[a-z_]+$/)) error = 'download_failed';
		die(error);
	}
	let stock = fs.readfile(work + '/default-podkop');
	stage = 'reset_preparing';
	status('running', {});
	let changed = resetConfig({ work, config: '/etc/config/podkop', backup: runtime + '/previous-podkop' }, original, stock, native, pending, {
		running,
		stop: () => {
			stage = 'reset_stopping';
			status('running', {});
			return system([helper, 'stop'], 180000) == 0 && !running();
		},
		start: () => system([helper, 'start'], 180000) == 0
	});
	status('reset', { changed, service_stopped: true });
}
catch (error) {
	let code = split(error.message || '', '\n')[0];
	if (!match(code, /^[a-z_]+$/)) code = 'internal_error';
	status('error', { error: code });
	exit(1);
}
