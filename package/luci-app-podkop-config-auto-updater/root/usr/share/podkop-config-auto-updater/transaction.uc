import * as fs from 'fs';
import { cursor } from 'uci';

export function writePrivate(path, data) {
	if (fs.writefile(path, data) !== length(data) || !fs.chmod(path, 0600)) die('write_failed');
};

export function atomicWrite(path, data) {
	writePrivate(path + '.new', data);
	if (!fs.rename(path + '.new', path)) die('write_failed');
};

export function applyPatch(paths, patches, original, pending, restart, order) {
	let changed = false;
	for (let section, patch in patches)
		if (length(keys(patch))) changed = true;
	if (!changed && !order) return false;
	if (pending()) die('pending_changes');
	writePrivate(paths.work + '/podkop', original);
	let staged = cursor(paths.work, paths.work + '/delta');
	if (!staged.load('podkop')) die('invalid_podkop');
	for (let section in keys(patches)) {
		if (!length(keys(patches[section]))) continue;
		let expectedType = section == 'settings' ? 'settings' : 'section';
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
	let route = staged.get('podkop', 'settings', 'download_lists_via_proxy_section');
	if (staged.get('podkop', 'settings', 'download_lists_via_proxy') == '1' &&
		(!route || staged.get('podkop', route) != 'section' ||
		index(['proxy', 'vpn'], staged.get('podkop', route, 'connection_type')) < 0)) die('invalid_proxy_section');
	if (!staged.commit('podkop')) die('write_failed');
	let updated = fs.readfile(paths.work + '/podkop');
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
};
