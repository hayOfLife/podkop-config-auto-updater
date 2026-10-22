import * as fs from 'fs';
import { cursor } from 'uci';

export function writePrivate(path, data) {
	if (fs.writefile(path, data) !== length(data) || !fs.chmod(path, 0600)) die('write_failed');
}

export function atomicWrite(path, data) {
	writePrivate(path + '.new', data);
	if (!fs.rename(path + '.new', path)) die('write_failed');
}

export function applyPatch(paths, patch, original, pending, restart) {
	if (!length(keys(patch))) return false;
	if (pending()) die('pending_changes');
	writePrivate(paths.work + '/podkop', original);
	let staged = cursor(paths.work, paths.work + '/delta');
	if (!staged.load('podkop')) die('invalid_podkop');
	if (!staged.get('podkop', 'main')) staged.set('podkop', 'main', 'section');
	if (staged.get('podkop', 'main') != 'section') die('incompatible_section');
	for (let key, value in patch) {
		if (type(value) == 'array' && !length(value)) staged.delete('podkop', 'main', key);
		else if (!staged.set('podkop', 'main', key, value)) die('write_failed');
	}
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
}
