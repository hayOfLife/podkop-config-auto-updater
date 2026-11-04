export function validateDnsServers(rows) {
	if (type(rows) != 'array' || !length(rows) || length(rows) > 32) die('invalid_dns_servers');
	let seen = {};
	for (let row in rows) {
		if (type(row) != 'object' || type(row.name) != 'string' ||
			!match(row.name, /^[A-Za-z_][A-Za-z0-9_]{0,63}$/) ||
			index(['settings', 'main', 'notUnderSanctions', 'direct', 'block'], row.name) >= 0 || seen[row.name])
			die('invalid_dns_servers');
		seen[row.name] = true;
		for (let key in keys(row)) if (index(['name', 'type', 'server'], key) < 0) die('invalid_dns_servers');
		if (index(['doh', 'dot', 'udp', 'provider'], row.type) < 0) die('invalid_dns_servers');
		if (row.type == 'provider') {
			if (exists(row, 'server')) die('invalid_dns_servers');
			continue;
		}
		if (type(row.server) != 'string' || length(row.server) > 2048 || index(row.server, '\u0000') >= 0 ||
			!match(row.server, /^[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~%/?=&+-]*)?$/)) die('invalid_dns_servers');
		let address = match(row.server, /^([A-Za-z0-9.-]+)(:([0-9]{1,5}))?(\/.*)?$/);
		if ((address[3] && (int(address[3]) < 1 || int(address[3]) > 65535)) ||
			(row.type != 'doh' && address[4])) die('invalid_dns_servers');
	}
	return rows;
};

export function requireDnsVersion(runtime) {
	let version = runtime?.experimental;
	let parts = type(version) == 'string' ? match(version, /^v?([0-9]+)\.([0-9]+)\.([0-9]+)(-r[0-9]+)?$/) : null;
	if (runtime?.stable || !parts || (int(parts[1]) == 0 &&
		(int(parts[2]) < 8 || (int(parts[2]) == 8 && int(parts[3]) < 9)))) die('experimental_dns_version_required');
	return runtime;
};

export function mergeDnsServers(rows, current, allowDeletes, runtime) {
	requireDnsVersion(runtime);
	let patches = {}, types = {}, removed = [], names = map(rows || [], row => row.name);
	let counts = { added: 0, removed: 0, pending: 0 };
	if (rows) {
		for (let row in rows) {
			let old = current[row.name] || {};
			if (old['.type'] && old['.type'] != 'dns_server') die('native_section_collision');
			let patch = {};
			if (old.type !== row.type) { patch.type = row.type; counts.added++; }
			if (row.type == 'provider') {
				if (exists(old, 'server')) { patch.server = null; counts.removed++; }
			}
			else if (old.server !== row.server) { patch.server = row.server; counts.added++; }
			if (length(keys(patch))) { patches[row.name] = patch; types[row.name] = 'dns_server'; }
		}
		for (let name, values in current) {
			if (values['.type'] != 'dns_server' || index(names, name) >= 0) continue;
			if (!allowDeletes) die('dns_delete_disabled');
			push(removed, name);
			counts.removed++;
		}
		if (!allowDeletes && counts.removed) die('dns_delete_disabled');
	}
	return { patches, types, counts, metadata: { runtime, rows, order: names, delete_sections: removed } };
};

export function validateDnsCursor(staged, dns) {
	requireDnsVersion(dns.runtime);
	if (staged.get('podkop', 'settings', 'config_version') != '2') die('experimental_dns_version_required');
	if (dns.rows) {
		let names = [];
		staged.foreach('podkop', 'dns_server', row => { push(names, row['.name']); });
		if (sprintf('%J', names) != sprintf('%J', dns.order)) die('invalid_dns_servers');
		for (let row in dns.rows) {
			let stored = staged.get_all('podkop', row.name);
			if (stored?.['.type'] != 'dns_server' || stored.type != row.type ||
				(row.type == 'provider' ? exists(stored, 'server') : stored.server != row.server)) die('invalid_dns_servers');
		}
	}
	let mode = staged.get('podkop', 'settings', 'dns_mode');
	if (mode != null && index(['order', 'fastest'], mode) < 0) die('invalid_dns_mode');
};

export function orderDnsCursor(staged, dns) {
	if (!dns.rows) return;
	let position = 0, anchor = null;
	staged.foreach('podkop', null, row => {
		if (row['.type'] == 'dns_server' && anchor == null) anchor = position;
		position++;
	});
	for (let i = 0; i < length(dns.order); i++) {
		let name = dns.order[i];
		if (staged.get('podkop', name) != 'dns_server') die('invalid_dns_servers');
		// Перемещаем только DNS-строки, сохраняя взаимный порядок остальных секций
		if (!staged.reorder('podkop', name, anchor + i)) die('write_failed');
	}
};
