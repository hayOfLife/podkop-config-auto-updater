import * as fs from 'fs';
import { cursor } from 'uci';
import { validateNativeCursor } from 'experimental';

export function writePrivate(path, data) {
	if (fs.writefile(path, data) !== length(data) || !fs.chmod(path, 0600)) die('write_failed');
};

export function atomicWrite(path, data) {
	writePrivate(path + '.new', data);
	if (!fs.rename(path + '.new', path)) die('write_failed');
};

function replaceFile(paths, original, updated, pending, restart) {
	if (pending()) die('pending_changes');
	if (fs.readfile(paths.config) != original) die('concurrent_change');
	if (updated == original) return false;
	atomicWrite(paths.backup, original);
	writePrivate(paths.config + '.sattelite-new', updated);
	// Повторная проверка перед заменой не позволяет затереть уже сохранённую ручную правку
	if (pending() || fs.readfile(paths.config) != original) {
		fs.unlink(paths.config + '.sattelite-new');
		die('concurrent_change');
	}
	if (!fs.rename(paths.config + '.sattelite-new', paths.config)) die('write_failed');
	if (restart()) return true;

	// Откат допустим только пока никто не изменил установленную нами версию
	if (fs.readfile(paths.config) != updated || pending()) die('restart_failed_manual_recovery');
	atomicWrite(paths.config, original);
	if (!restart()) die('rollback_restart_failed');
	die('restart_failed_restored');
}

function stopSnapshot(paths, text) {
	writePrivate(paths.work + '/podkop', text);
	let stored = cursor(paths.work, paths.work + '/delta');
	if (!stored.load('podkop')) die('invalid_podkop');
	let sections = [];
	stored.foreach('podkop', null, section => {
		let options = {};
		for (let key in sort(keys(section))) if (substr(key, 0, 1) != '.') options[key] = section[key];
		push(sections, { name: section['.name'], type: section['.type'], options });
	});
	return sections;
}

function expectedStopChange(paths, before, after) {
	if (after == before) return true;
	try {
		let first = stopSnapshot(paths, before), second = stopSnapshot(paths, after);
		if (length(first) != length(second)) return false;
		for (let i = 0; i < length(first); i++) {
			if (first[i].name != second[i].name || first[i].type != second[i].type) return false;
			if (first[i].name != 'settings') continue;
			let old = first[i].options.shutdown_correctly, value = second[i].options.shutdown_correctly;
			if (old != value && value == '1' && (old == null || old == '0')) {
				delete first[i].options.shutdown_correctly;
				delete second[i].options.shutdown_correctly;
			}
		}
		return sprintf('%J', first) == sprintf('%J', second);
	}
	catch (e) { return false; }
}

export function resetConfig(paths, original, stock, native, pending, service) {
	if (type(stock) != 'string' || !length(stock) || length(stock) > 1048576 || index(stock, '\u0000') >= 0) die('invalid_stock_config');
	if (pending()) die('pending_changes');
	writePrivate(paths.work + '/podkop', stock);
	let staged = cursor(paths.work, paths.work + '/delta');
	try { if (!staged.load('podkop')) die('invalid_stock_config'); } catch (e) { die('invalid_stock_config'); }
	if (staged.get('podkop', 'settings') != 'settings' || staged.get('podkop', 'main') != 'section') die('invalid_stock_config');
	let settings = staged.get_all('podkop', 'settings'), main = staged.get_all('podkop', 'main');
	if (native ? settings.config_version != '2' : settings.config_version == '2') die('invalid_stock_config');
	let sources = {}, members = [], other = false, count = 0;
	staged.foreach('podkop', null, section => {
		count++;
		if (section['.name'] == 'settings' || section['.name'] == 'main') return;
		if (native && section['.type'] == 'source') sources[section['.name']] = section;
		else if (native && section['.type'] == 'member') push(members, section);
		else other = true;
	});
	if (other || (native ? count != 4 || length(keys(sources)) != 1 || length(members) != 1 : count != 2)) die('invalid_stock_config');
	for (let key in ['proxy_string', 'urltest_proxy_links', 'selector_proxy_links', 'user_domains', 'user_domains_text',
		'user_subnets', 'user_subnets_text', 'remote_domain_lists', 'remote_subnet_lists', 'fully_routed_ips'])
		if (length(main[key] || '')) die('invalid_stock_config');
	if (native) {
		let member = members[0], source = sources[member.source];
		if (member.section != 'main' || member.role != 'server' || !source) die('invalid_stock_config');
		for (let key in ['type', 'url', 'link', 'outbound_json', 'interface', 'routing_mark'])
			if (length(source[key] || '')) die('invalid_stock_config');
	}
	else if (main.connection_type != 'proxy' || main.proxy_config_type != 'url') die('invalid_stock_config');
	if (pending()) die('pending_changes');
	if (fs.readfile(paths.config) != original) die('concurrent_change');
	atomicWrite(paths.backup, original);
	try { writePrivate(paths.config + '.sattelite-new', stock); }
	catch (e) { fs.unlink(paths.config + '.sattelite-new'); die('write_failed'); }
	let running = false, stopped = false;
	try {
		running = service.running();
		stopped = true;
		if (!service.stop()) die('reset_stop_failed');
		let after = fs.readfile(paths.config);
		if (pending() || !expectedStopChange(paths, original, after)) die('concurrent_change');
		if (pending() || fs.readfile(paths.config) != after) die('concurrent_change');
		if (!fs.rename(paths.config + '.sattelite-new', paths.config)) die('write_failed');
		return stock != original;
	}
	catch (error) {
		fs.unlink(paths.config + '.sattelite-new');
		let code = split(error.message || '', '\n')[0];
		if (!match(code, /^[a-z_]+$/)) code = 'write_failed';
		if (!stopped) die(code);
		let current = fs.readfile(paths.config);
		// Конкурирующая правка после остановки требует ручного решения без перезаписи чужого файла
		if ((current != original && current != stock && !expectedStopChange(paths, original, current)) || pending())
			die('reset_failed_manual_recovery');
		if (current != original) atomicWrite(paths.config, original);
		if (running && !service.start()) die('reset_restore_failed');
		die(code);
	}
};

export function applyPatch(paths, patches, original, pending, restart, order, native) {
	let changed = length(native?.delete_sections || []) > 0;
	for (let section, patch in patches)
		if (length(keys(patch))) changed = true;
	if (!changed && !order) return false;
	if (pending()) die('pending_changes');
	writePrivate(paths.work + '/podkop', original);
	let staged = cursor(paths.work, paths.work + '/delta');
	if (!staged.load('podkop')) die('invalid_podkop');
	if (!native && staged.get('podkop', 'settings', 'config_version') == '2') die('experimental_config_required');
	if (native) {
		if (staged.get('podkop', 'settings', 'config_version') != '2') die('experimental_version_required');
		for (let name in native.delete_sections) {
			if (staged.get('podkop', name) != 'member' || index(native.replace_members, staged.get('podkop', name, 'section')) < 0)
				die('invalid_native_membership');
			if (!staged.delete('podkop', name)) die('write_failed');
		}
	}
	for (let section in keys(patches)) {
		if (!length(keys(patches[section]))) continue;
		let expectedType = native?.types[section] || (section == 'settings' ? 'settings' : 'section');
		if (native && expectedType == 'member' && staged.get('podkop', section) == 'member' &&
			index(['main', 'notUnderSanctions'], staged.get('podkop', section, 'section')) < 0) die('native_section_collision');
		if (!staged.get('podkop', section)) staged.set('podkop', section, expectedType);
		if (staged.get('podkop', section) != expectedType) die('incompatible_section');
		for (let key, value in patches[section]) {
			if (value == null || (type(value) == 'array' && !length(value))) staged.delete('podkop', section, key);
			else if (!staged.set('podkop', section, key, value)) die('write_failed');
		}
	}
	if (order) {
		let positions = {}, position = 0;
		staged.foreach('podkop', null, section => { positions[section['.name']] = position++; });
		for (let name in order)
			if (exists(positions, name) && staged.get('podkop', name) != 'section') die('incompatible_section');
		if (exists(positions, order[0]) && exists(positions, order[1]) && positions[order[0]] > positions[order[1]] &&
			!staged.reorder('podkop', order[0], positions[order[1]])) die('write_failed');
	}
	if (native) validateNativeCursor(staged, native);
	else {
		let route = staged.get('podkop', 'settings', 'download_lists_via_proxy_section');
		if (staged.get('podkop', 'settings', 'download_lists_via_proxy') == '1' &&
			(!route || staged.get('podkop', route) != 'section' ||
			index(['proxy', 'vpn'], staged.get('podkop', route, 'connection_type')) < 0)) die('invalid_proxy_section');
	}
	if (!staged.commit('podkop')) die('write_failed');
	let updated = fs.readfile(paths.work + '/podkop');
	return replaceFile(paths, original, updated, pending, restart);
};
