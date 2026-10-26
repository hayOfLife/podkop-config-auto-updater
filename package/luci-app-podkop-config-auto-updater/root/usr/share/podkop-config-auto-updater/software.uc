import * as fs from 'fs';

const target = ARGV[0];
const work = ARGV[1];
const helper = work + '/software-io';
const statusPath = '/tmp/podkop-config-auto-updater/software.json';
let repository = target == 'self' ? 'hayOfLife/podkop-config-auto-updater' : 'itdoginfo/podkop';
let variant;
let stage = 'checking';
let releaseVersion;
let installedVersion;
let availableVersion;

function writePrivate(path, data) {
	if (fs.writefile(path, data) !== length(data) || !fs.chmod(path, 0600)) die('write_failed');
}

function status(state, extra) {
	writePrivate(statusPath + '.new', sprintf('%J', {
		state, target, stage, variant, version: releaseVersion,
		installed_version: installedVersion, available_version: availableVersion, ...extra
	}));
	if (!fs.rename(statusPath + '.new', statusPath)) die('write_failed');
}

function run(args, timeout) {
	return system([helper, ...args], timeout || 130000);
}

function version(name) {
	if (run(['version', name, work]) != 0) die('package_query_failed');
	let value = trim(fs.readfile(work + '/version') || '');
	if (value && (!match(value, /^v?[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/) || match(value, /[[:space:][:cntrl:]]/))) die('invalid_installed_version');
	return value;
}

function newer(candidate, current) {
	let result = run(['newer', replace(candidate, /^v/, ''), replace(current, /^v/, '')]);
	if (result != 0 && result != 1) die('package_compare_failed');
	return result == 0;
}

function pending() {
	for (let name in ['podkop', 'podkop_config_auto_updater'])
		for (let path in ['/tmp/.uci/' + name, ...(fs.glob('/var/run/rpcd/uci-*/' + name) || [])])
			if (length(fs.readfile(path) || '')) return true;
	return false;
}

function download(url, path, limit) {
	if (run(['fetch', url, path, '' + limit]) != 0) die('download_failed');
	let size = fs.stat(path)?.size;
	if (!size || size > limit) die('invalid_size');
}

function backup(configs) {
	let directory = '/tmp/podkop-config-auto-updater/before-software-' + target;
	fs.mkdir('/tmp/podkop-config-auto-updater', 0700);
	fs.chmod('/tmp/podkop-config-auto-updater', 0700);
	fs.mkdir(directory, 0700);
	if (!fs.chmod(directory, 0700)) die('backup_failed');
	for (let name, text in configs) writePrivate(directory + '/' + name, text);
}

try {
	if (index(['self', 'podkop'], target) < 0) die('invalid_target');
	if (pending()) die('pending_changes');
	if (run(['platform', work]) != 0) die('unsupported_platform');
	let platform = split(trim(fs.readfile(work + '/platform')), ' ');
	let series = platform[0], format = platform[1];
	let names = ['luci-app-podkop-config-auto-updater'];
	let installed = {};
	let architecture;
	if (target == 'podkop') {
		installed.podkop = version('podkop');
		installed['podkop-exp'] = version('podkop-exp');
		if (installed.podkop && installed['podkop-exp']) die('podkop_variant_conflict');
		if (!installed.podkop && !installed['podkop-exp']) die('podkop_package_missing');
		variant = installed['podkop-exp'] ? 'experimental' : 'stable';
		names = variant == 'experimental' ? ['podkop-exp', 'luci-app-podkop-exp'] : ['podkop', 'luci-app-podkop'];
		installedVersion = installed[names[0]];
		if (variant == 'experimental') {
			repository = 'podkop-net/podkop-experimental';
			if (run(['architecture', work]) != 0) die('unsupported_architecture');
			architecture = trim(fs.readfile(work + '/architecture') || '');
			if (!match(architecture, /^[a-z0-9][a-z0-9_-]{0,63}$/) || index(['all', 'noarch'], architecture) >= 0)
				die('unsupported_architecture');
			architecture = join('-', split(architecture, '_'));
		}
		else {
			let parts = split(replace(installedVersion, /^v/, ''), '.');
			if (int(parts[0]) == 0 && int(parts[1]) < 7) die('podkop_migration_required');
		}
		installed[names[1]] = version(names[1]);
		let translation = variant == 'experimental' ? 'luci-i18n-podkop-exp-ru' : 'luci-i18n-podkop-ru';
		let russian = version(translation);
		if (russian) { push(names, translation); installed[translation] = russian; }
	}
	else { installed[names[0]] = version(names[0]); installedVersion = installed[names[0]]; }

	download('https://api.github.com/repos/' + repository + '/releases/latest', work + '/release.json', 1048576);
	let release;
	try { release = json(fs.readfile(work + '/release.json')); } catch (e) { die('invalid_release'); }
	let tag = release?.tag_name;
	if (type(tag) != 'string' || match(tag, /[[:space:][:cntrl:]]/) || !match(tag, /^v?[0-9]+\.[0-9]+\.[0-9]+$/) ||
		release.draft !== false || release.prerelease !== false || type(release.assets) != 'array') die('invalid_release');
	releaseVersion = replace(tag, /^v/, '');
	let base = 'https://github.com/' + repository + '/releases/download/' + tag + '/';
	let updates = [];
	for (let name in names) {
		let candidates = [];
		for (let asset in release.assets) {
			if (type(asset?.name) != 'string') continue;
			let expected;
			if (target == 'self') {
				if (asset.name != name + '-openwrt-' + series + '.' + format) continue;
				expected = releaseVersion + '-r1';
			}
			else {
				if (index(asset.name, name + '-') != 0 || substr(asset.name, -4) != '.' + format) continue;
				expected = substr(asset.name, length(name) + 1, length(asset.name) - length(name) - 5);
				if (name == 'podkop-exp') {
					let suffix = '-' + architecture;
					if (substr(expected, -length(suffix)) != suffix) continue;
					expected = substr(expected, 0, length(expected) - length(suffix));
				}
				else expected = replace(expected, /-all$/, '');
				if (match(expected, /[[:space:][:cntrl:]]/) || !match(expected, /^v?[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$/) ||
					replace(replace(expected, /^v/, ''), /-r[0-9]+$/, '') != releaseVersion) continue;
			}
			push(candidates, { asset, expected });
		}
		if (length(candidates) != 1) die('missing_package');
		let asset = candidates[0].asset, expected = candidates[0].expected;
		if (asset.browser_download_url != base + asset.name || type(asset.digest) != 'string' ||
			match(asset.digest, /[[:space:][:cntrl:]]/) || !match(asset.digest, /^sha256:[a-f0-9]{64}$/) ||
			type(asset.size) != 'int' || asset.size < 1 || asset.size > 67108864) die('invalid_package');
		let current = installed[name];

		// Версия перевода Experimental задаётся временем сборки и не совпадает с номером в имени файла
		let exactVersion = name != 'luci-i18n-podkop-exp-ru';
		if (name == names[0]) availableVersion = expected;
		if (current && exactVersion && !newer(expected, current)) {
			// Актуальное ядро Podkop исключает установку остальных пакетов из этого релиза
			if (target == 'podkop' && name == names[0]) { status('up_to_date', {}); exit(0); }
			continue;
		}
		push(updates, { name, asset, expected: exactVersion ? expected : null, path: work + '/' + asset.name });
	}
	if (!length(updates)) { status('up_to_date', {}); exit(0); }

	stage = 'downloading';
	status('running', {});
	for (let update in updates) {
		download(update.asset.browser_download_url, update.path, 67108864);
		if (fs.stat(update.path).size != update.asset.size || run(['verify', update.path, substr(update.asset.digest, 7)]) != 0) die('checksum_mismatch');
	}
	if (pending()) die('pending_changes');
	let configs = {};
	for (let name in ['podkop', 'podkop_config_auto_updater']) {
		let text = fs.readfile('/etc/config/' + name);
		if (text != null) configs[name] = text;
	}
	backup(configs);

	stage = 'index';
	status('running', {});
	if (run(['index'], 180000) != 0) die('package_index_failed');
	if (pending()) die('pending_changes');
	for (let name, text in configs)
		if (fs.readfile('/etc/config/' + name) != text) die('concurrent_change');

	stage = 'installing';
	status('running', {});
	if (run(['install', ...map(updates, (update) => update.path)], 900000) != 0) die('package_install_failed');
	for (let update in updates) {
		let current = version(update.name);
		if (!current || (update.expected != null && current != update.expected)) die('installed_version_mismatch');
		if (update.name == names[0]) installedVersion = current;
	}
	let changed = false;
	for (let name, text in configs)
		if (fs.readfile('/etc/config/' + name) != text) changed = true;
	status('updated', { config_changed: changed });
}
catch (error) {
	let code = split(error.message || '', '\n')[0];
	if (!match(code, /^[a-z_]+$/)) code = 'internal_error';
	status('error', { error: code });
	exit(1);
}
