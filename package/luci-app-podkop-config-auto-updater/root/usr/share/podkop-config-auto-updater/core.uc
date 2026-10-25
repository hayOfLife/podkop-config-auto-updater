const fields = ['urltest_proxy_links', 'user_domains', 'user_subnets'];

export function normalize(kind, value) {
	if (kind == 'literal') return value;
	if (type(value) != 'string' || !length(value) || length(value) > 8192 || index(value, '\u0000') >= 0 || match(value, /[[:space:][:cntrl:]]/))
		die('invalid_value');

	if (kind == 'urltest_proxy_links') {
		if (!match(value, /^(vless|ss|trojan|socks4|socks5|hy2|hysteria2):\/\/[^[:space:]]+$/))
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
		let bits = prefix - i * 8;
		bits = bits < 0 ? 0 : (bits > 8 ? 8 : bits);
		bytes[i] &= (255 << (8 - bits)) & 255;
	}
	return arrtoip(bytes) + '/' + prefix;
};

export function validateFeed(feed, allowComments) {
	if (type(feed) != 'object' || feed.schema_version !== 1 || feed.section !== 'main' ||
		type(feed.revision) != 'string' || index(feed.revision, '\u0000') >= 0 || match(feed.revision, /[[:space:][:cntrl:]]/) ||
		!match(feed.revision, /^[a-zA-Z0-9._-]{1,80}$/))
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
			if (type(entry) == 'object' && exists(entry, 'comment')) {
				if (!allowComments || field == 'urltest_proxy_links' || length(keys(entry)) != 1 ||
					type(entry.comment) != 'string' || !length(trim(entry.comment)) || length(entry.comment) > 512 ||
					index(entry.comment, '\u0000') >= 0 || match(entry.comment, /[[:cntrl:]]/)) die('invalid_comment');
				push(result[field], { comment: entry.comment });
				continue;
			}
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
};

export function tokens(text) {
	return filter(split(replace(text || '', /\/\/[^\n]*/g, ''), /[[:space:],]+/), v => length(v));
};

function storedKey(kind, value) {
	try { return normalize(kind, value); }
	catch (e) { return value; }
}

export function mergeList(kind, oldValues, operations, allowDeletes) {
	let remove = {};
	let pending = 0;
	for (let operation in operations) {
		if (exists(operation, 'comment')) continue;
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
		if (exists(operation, 'comment')) continue;
		if (operation.remove || seen[operation.value]) continue;
		push(values, operation.value);
		seen[operation.value] = true;
		added++;
	}
	return { values, added, removed, pending };
};

function renderText(kind, original, values, operations) {
	if (!length(values)) return '';
	let managed = {}, titles = {}, groups = [], group = null;
	let indexed = {};
	for (let value in values) {
		let key = storedKey(kind, value);
		if (!indexed[key]) indexed[key] = [];
		push(indexed[key], value);
	}
	for (let op in operations) {
		if (exists(op, 'comment')) {
			group = { title: op.comment, values: [] };
			push(groups, group);
			titles[trim('// ' + op.comment)] = true;
		}
		else if (!op.remove && group) {
			managed[op.value] = true;
			for (let value in indexed[op.value] || []) push(group.values, value);
		}
	}
	let remaining = {}, seen = {}, lines = [];
	for (let value in values) remaining[storedKey(kind, value)] = true;
	for (let line in split(original || '', '\n')) {
		let marker = index(line, '//');
		let comment = marker < 0 ? '' : trim(substr(line, marker));
		let old = tokens(line);
		let kept = filter(old, value => remaining[storedKey(kind, value)] && !managed[storedKey(kind, value)]);
		for (let value in kept) seen[storedKey(kind, value)] = true;
		if (length(kept)) {
			push(lines, length(kept) == length(old) ? line : join(' ', kept) + (comment ? ' ' + comment : ''));
		}
		else if (comment && !titles[comment]) push(lines, comment);
	}
	for (let value in values) {
		let key = storedKey(kind, value);
		if (!managed[key] && !seen[key]) { push(lines, value); seen[key] = true; }
	}
	for (let entry in groups) {
		if (!length(entry.values)) continue;
		push(lines, '// ' + entry.title);
		for (let value in entry.values) push(lines, value);
	}
	return join('\n', lines);
}

export function mergeSection(section, feed, allowDeletes, options) {
	let patch = {};
	let counts = {};
	let oldProxies = section.urltest_proxy_links || [];
	if (type(oldProxies) == 'string') oldProxies = [oldProxies];
	else oldProxies = [...oldProxies];
	let proxyOps = feed.urltest_proxy_links;
	counts.urltest_proxy_links = { added: 0, removed: 0, pending: length(filter(proxyOps, op => op.remove && !allowDeletes)) };
	if (length(filter(proxyOps, op => !op.remove || allowDeletes))) {
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
		let requested = options ? options[typeKey] : null;
		let toText = requested?.kind == 'scalar' && !requested.entry.remove && requested.entry.value == 'text';
		let comments = length(filter(feed[kind], op => exists(op, 'comment'))) > 0 &&
			length(filter(feed[kind], op => !op.remove && !exists(op, 'comment'))) > 0;
		if (comments && mode == 'dynamic' && !toText) die('comments_require_text');
		let dynamic = section[kind] || [];
		if (type(dynamic) == 'string') dynamic = [dynamic];
		let textValues = tokens(section[kind + '_text']);
		let current = mode == 'dynamic' ? dynamic : textValues;
		if (toText && mode == 'dynamic') {
			current = [...textValues];
			let known = {};
			for (let value in current) known[storedKey(kind, value)] = true;
			for (let value in dynamic)
				if (!known[storedKey(kind, value)]) { push(current, value); known[storedKey(kind, value)] = true; }
		}
		let merged = mergeList(kind, current, feed[kind], allowDeletes);
		counts[kind] = { added: merged.added, removed: merged.removed, pending: merged.pending };
		let textMode = mode != 'dynamic' || toText;
		let rendered = textMode ? renderText(kind, section[kind + '_text'], merged.values, feed[kind]) : null;
		if (merged.added || merged.removed || (comments && rendered != (section[kind + '_text'] || '')) ||
			(toText && mode == 'dynamic') ||
			(mode == 'disabled' && length(merged.values) && length(filter(feed[kind], op => !op.remove && !exists(op, 'comment'))))) {
			if (!textMode) patch[kind] = merged.values;
			else patch[kind + '_text'] = rendered;
			patch[typeKey] = length(merged.values) ? (textMode ? 'text' : 'dynamic') : 'disabled';
		}
		// Удаление из скрытого представления предотвращает возврат записи при переключении типа списка
		let hidden = mergeList(kind, mode == 'dynamic' && !toText ? textValues : dynamic,
			filter(feed[kind], op => op.remove), allowDeletes);
		if (toText && mode == 'dynamic')
			counts[kind].removed = mergeList(kind, textValues, filter(feed[kind], op => op.remove), allowDeletes).removed;
		if (hidden.removed) {
			if (mode != 'dynamic') patch[kind] = hidden.values;
			else if (!toText) patch[kind + '_text'] = renderText(kind, section[kind + '_text'], hidden.values, []);
			counts[kind].removed += hidden.removed;
		}
		if (toText && mode == 'dynamic' && hidden.removed) patch[kind] = hidden.values;
	}
	return { patch, counts };
};

export function nextRun(now, days, minute) {
	let date = localtime(now);
	date.hour = 3;
	date.min = minute;
	date.sec = 0;
	date.isdst = -1;
	date.mday += days;
	return timelocal(date);
};

export function planSchedule(now, previous, interval, timezone, minute) {
	if (index([1, 3, 7, 30], interval) < 0) die('invalid_interval');
	if (!previous || previous.interval != interval || previous.timezone != timezone || type(previous.next) != 'int') {
		let next = nextRun(now, now < nextRun(now, 0, 0) ? 0 : 1, minute);
		return { state: { next, interval, timezone }, due: false, changed: true };
	}
	if (now < previous.next) return { state: previous, due: false, changed: false };
	let date = localtime(now);
	let due = date.hour == 3 && date.min <= 30;
	let next = due ? nextRun(now, interval, minute) : nextRun(now, date.hour < 3 ? 0 : 1, minute);
	return { state: { next, interval, timezone }, due, changed: true };
};
