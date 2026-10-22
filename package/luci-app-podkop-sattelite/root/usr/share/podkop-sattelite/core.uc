const fields = ['urltest_proxy_links', 'user_domains', 'user_subnets'];

export function normalize(kind, value) {
	if (type(value) != 'string' || !length(value) || length(value) > 8192 || match(value, /[\x00-\x20\x7f]/))
		die('invalid_value');

	if (kind == 'urltest_proxy_links') {
		if (!match(value, /^(vless|ss|trojan|socks4|socks5|hy2|hysteria2):\/\/[^\s]+$/))
			die('unsupported_proxy');
		return value;
	}

	if (kind == 'user_domains') {
		value = lc(replace(value, /\.$/, ''));
		if (length(value) > 253 || index(value, '.') < 0)
			die('invalid_domain');
		for (let label in split(value, '.'))
			if (!match(label, /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/))
				die('invalid_domain');
		return value;
	}

	let parts = split(value, '/');
	let bytes = iptoarr(parts[0]);
	if (!bytes || length(parts) > 2 || (length(parts) == 2 && !match(parts[1], /^(0|[1-9][0-9]*)$/)))
		die('invalid_subnet');
	let prefix = length(parts) == 2 ? int(parts[1]) : length(bytes) * 8;
	if (prefix > length(bytes) * 8)
		die('invalid_subnet');
	for (let i = 0; i < length(bytes); i++) {
		let bits = max(0, min(8, prefix - i * 8));
		bytes[i] &= (255 << (8 - bits)) & 255;
	}
	return arrtoip(bytes) + '/' + prefix;
}

export function validateFeed(feed) {
	if (type(feed) != 'object' || feed.schema_version !== 1 || feed.section !== 'main' ||
		type(feed.revision) != 'string' || !match(feed.revision, /^[a-zA-Z0-9._-]{1,80}$/))
		die('invalid_schema');
	for (let key in keys(feed))
		if (index(['schema_version', 'section', 'revision', ...fields], key) < 0)
			die('unknown_field');

	let result = { revision: feed.revision };
	for (let field in fields) {
		if (type(feed[field]) != 'array' || length(feed[field]) > 10000)
			die('invalid_list');
		let seen = {};
		result[field] = [];
		for (let entry in feed[field]) {
			let remove = false;
			let value = entry;
			if (type(entry) == 'object') {
				if (length(keys(entry)) != 2 || entry.delete !== true || type(entry.value) != 'string')
					die('invalid_delete');
				remove = true;
				value = entry.value;
			}
			value = normalize(field, value);
			if (exists(seen, value)) {
				if (seen[value] != remove)
					die('conflicting_operations');
				continue;
			}
			seen[value] = remove;
			push(result[field], { value, remove });
		}
	}
	return result;
}

export function tokens(text) {
	return filter(split(replace(text || '', /\/\/[^\n]*/g, ''), /[\s,]+/), v => length(v));
}

function storedKey(kind, value) {
	try { return normalize(kind, value); }
	catch (e) { return value; }
}

export function mergeList(kind, oldValues, operations, allowDeletes) {
	let remove = {};
	let pending = 0;
	for (let operation in operations) {
		if (!operation.remove) continue;
		if (allowDeletes) remove[operation.value] = true;
		else pending++;
	}

	let values = [];
	let seen = {};
	let removed = 0;
	let added = 0;
	for (let value in oldValues) {
		let key = storedKey(kind, value);
		if (remove[key]) { removed++; continue; }
		push(values, value);
		seen[key] = true;
	}
	for (let operation in operations) {
		if (operation.remove || seen[operation.value]) continue;
		push(values, operation.value);
		seen[operation.value] = true;
		added++;
	}
	return { values, added, removed, pending };
}

export function mergeSection(section, feed, allowDeletes) {
	let patch = {};
	let counts = {};
	let oldProxies = section.urltest_proxy_links || [];
	if (type(oldProxies) == 'string') oldProxies = [oldProxies];
	let proxyOps = feed.urltest_proxy_links;
	if (length(proxyOps)) {
		if (section.connection_type && section.connection_type != 'proxy') die('incompatible_section');
		let mode = section.proxy_config_type || 'url';
		if (mode == 'url' && length(section.proxy_string || ''))
			push(oldProxies, normalize('urltest_proxy_links', section.proxy_string));
		else if (mode != 'url' && mode != 'urltest') die('incompatible_section');
		let merged = mergeList('urltest_proxy_links', oldProxies, proxyOps, allowDeletes);
		if (!length(merged.values)) die('empty_proxy_pool');
		counts.urltest_proxy_links = { added: merged.added, removed: merged.removed, pending: merged.pending };
		if (merged.added || merged.removed || mode != 'urltest') {
			patch.urltest_proxy_links = merged.values;
			patch.connection_type = 'proxy';
			patch.proxy_config_type = 'urltest';
		}
	}

	for (let kind in ['user_domains', 'user_subnets']) {
		let typeKey = kind == 'user_domains' ? 'user_domain_list_type' : 'user_subnet_list_type';
		let mode = section[typeKey] || 'disabled';
		if (index(['disabled', 'text', 'dynamic'], mode) < 0) die('incompatible_list');
		let dynamic = section[kind] || [];
		if (type(dynamic) == 'string') dynamic = [dynamic];
		let textValues = tokens(section[kind + '_text']);
		let current = mode == 'dynamic' ? dynamic : textValues;
		let merged = mergeList(kind, current, feed[kind], allowDeletes);
		counts[kind] = { added: merged.added, removed: merged.removed, pending: merged.pending };
		if (merged.added || merged.removed || (mode == 'disabled' && length(merged.values) && length(feed[kind]))) {
			if (mode == 'dynamic') patch[kind] = merged.values;
			else patch[kind + '_text'] = join('\n', merged.values);
			patch[typeKey] = length(merged.values) ? (mode == 'dynamic' ? 'dynamic' : 'text') : 'disabled';
		}
		// Удаление из скрытого представления предотвращает возврат записи при переключении типа списка
		let hidden = mergeList(kind, mode == 'dynamic' ? textValues : dynamic,
			filter(feed[kind], op => op.remove), allowDeletes);
		if (hidden.removed)
			patch[mode == 'dynamic' ? kind + '_text' : kind] = mode == 'dynamic' ? join('\n', hidden.values) : hidden.values;
	}
	return { patch, counts };
}

export function nextRun(now, days, minute) {
	let date = localtime(now);
	date.hour = 3;
	date.min = minute;
	date.sec = 0;
	date.isdst = -1;
	date.mday += days;
	return timelocal(date);
}
