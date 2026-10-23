import * as core from 'core';

const listFields = ['urltest_proxy_links', 'user_domains', 'user_subnets'];
const settingsFields = ['dns_type', 'dns_server', 'bootstrap_dns_server', 'download_lists_via_proxy',
	'update_interval', 'download_lists_via_proxy_section'];

export function parseConfig(text) {
	let chunks = [], start = 0, quoted = false;
	for (let i = 0; i < length(text); i++) {
		let ch = substr(text, i, 1);
		if (quoted) {
			if (ch == '\\') i++;
			else if (ch == '"') quoted = false;
			continue;
		}
		if (ch == '"') { quoted = true; continue; }
		if (ch != '/') continue;
		let next = substr(text, i + 1, 1);
		if (next != '/' && next != '*') continue;
		push(chunks, substr(text, start, i - start));
		let end = i + 2;
		if (next == '/') {
			while (end < length(text) && substr(text, end, 1) != '\n' && substr(text, end, 1) != '\r') end++;
		}
		else {
			while (end < length(text) && substr(text, end, 2) != '*/') end++;
			if (end >= length(text)) die('invalid_json');
			end += 2;
		}
		// Пробел не позволяет комментарию склеить два недопустимых JSON-токена
		push(chunks, ' ');
		start = end;
		i = end - 1;
	}
	push(chunks, substr(text, start));
	return json(join('', chunks));
};

function canonicalField(field) {
	if (field == 'main.user_domains_text') return 'main.user_domains';
	if (field == 'main.user_subnets_text') return 'main.user_subnets';
	return field;
}

export function configFields(input) {
	if (input.schema_version === 1) return map(listFields, key => 'main.' + key);
	let fields = [];
	for (let group in ['main', 'settings'])
		for (let key in keys(input[group])) push(fields, canonicalField(group + '.' + key));
	return fields;
};

function operation(value) {
	let remove = false;
	if (type(value) == 'object') {
		if (length(keys(value)) != 2 || value.delete !== true) die('invalid_delete');
		remove = true;
		value = value.value;
	}
	if (type(value) != 'string' || length(value) > 262144 || index(value, '\u0000') >= 0) die('invalid_option');
	return { value, remove };
}

function validateSetting(key, value) {
	if (match(value, /[[:space:][:cntrl:]]/)) die('invalid_setting');
	if (key == 'dns_type' && index(['udp', 'doh', 'dot'], value) < 0) die('invalid_dns_type');
	if (key == 'download_lists_via_proxy' && index(['0', '1'], value) < 0) die('invalid_flag');
	if (key == 'update_interval' && index(['1h', '3h', '12h', '1d', '3d'], value) < 0) die('invalid_list_interval');
	if (key == 'download_lists_via_proxy_section' && !match(value, /^[A-Za-z0-9_]+$/)) die('invalid_proxy_section');
	if ((key == 'dns_server' || key == 'bootstrap_dns_server') &&
		!match(value, /^[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~%/?=&+-]*)?$/)) die('invalid_dns_server');
}

export function validateConfig(input) {
	if (input?.schema_version === 1)
		return { lists: core.validateFeed(input), main: {}, settings: {}, revision: input.revision };
	if (type(input) != 'object' || input.schema_version !== 2 || type(input.main) != 'object' || type(input.settings) != 'object')
		die('invalid_schema');
	for (let key in keys(input))
		if (index(['schema_version', 'revision', 'main', 'settings'], key) < 0) die('unknown_field');
	let lists = { schema_version: 1, section: 'main', revision: input.revision,
		urltest_proxy_links: [], user_domains: [], user_subnets: [] };
	let result = { main: {}, settings: {}, revision: input.revision };
	for (let group in ['main', 'settings']) {
		if (length(keys(input[group])) > 256) die('too_many_options');
		for (let key, value in input[group]) {
			if (index(key, '\u0000') >= 0 || match(key, /[[:space:][:cntrl:]]/) || !match(key, /^[a-z][a-z0-9_]{0,63}$/)) die('invalid_option_name');
			if (group == 'settings' && index(settingsFields, key) < 0) die('unsupported_setting');
			if (group == 'main' && index(listFields, key) >= 0) { lists[key] = value; continue; }
			if (group == 'main' && index(['user_domains_text', 'user_subnets_text'], key) >= 0) {
				let canonical = replace(key, /_text$/, '');
				if (exists(input.main, canonical) || type(value) != 'string') die('ambiguous_list');
				lists[canonical] = core.tokens(value);
				continue;
			}
			if (type(value) == 'array') {
				if (group == 'settings' || length(value) > 10000) die('invalid_list');
				let entries = map(value, operation);
				let seen = {};
				for (let entry in entries) {
					if (exists(seen, entry.value) && seen[entry.value] != entry.remove) die('conflicting_operations');
					seen[entry.value] = entry.remove;
				}
				result[group][key] = { kind: 'list', entries };
			}
			else {
				let entry = operation(value);
				if (group == 'settings') validateSetting(key, entry.value);
				result[group][key] = { kind: 'scalar', entry };
			}
		}
	}
	result.lists = core.validateFeed(lists);
	return result;
};

export function selectConfig(input, ignored) {
	// Проверяем весь файл, даже когда локальная настройка запрещает применять часть полей
	validateConfig(input);
	if (type(ignored) != 'array') die('invalid_ignored_options');
	for (let field in ignored)
		if (type(field) != 'string' || !match(field, /^(main|settings)\.[a-z][a-z0-9_]{0,63}$/) || match(field, /[[:space:][:cntrl:]]/))
			die('invalid_ignored_options');
	ignored = map(ignored, canonicalField);
	let selected = { ...input };
	if (input.schema_version === 1) {
		for (let key in listFields)
			if (index(ignored, 'main.' + key) >= 0) selected[key] = [];
	}
	else {
		for (let group in ['main', 'settings']) {
			selected[group] = {};
			for (let key, value in input[group])
				if (index(ignored, canonicalField(group + '.' + key)) < 0) selected[group][key] = value;
		}
	}
	return validateConfig(selected);
};

function mergeOptions(current, operations, allowDeletes) {
	let patch = {};
	let counts = { added: 0, removed: 0, pending: 0 };
	for (let key, op in operations) {
		let old = current[key];
		if (op.kind == 'scalar') {
			if (op.entry.remove) {
				if (!allowDeletes) counts.pending++;
				else if (old === op.entry.value) { patch[key] = null; counts.removed++; }
			}
			else if (old !== op.entry.value) {
				if (type(old) == 'array') die('option_type_conflict');
				patch[key] = op.entry.value;
				counts.added++;
			}
		}
		else {
			if (old != null && type(old) != 'array') die('option_type_conflict');
			// Неизвестные Podkop-списки сравниваются буквально, без предположений об их формате
			let merged = core.mergeList('literal', old || [], op.entries, allowDeletes);
			if (merged.added || merged.removed) patch[key] = merged.values;
			counts.added += merged.added;
			counts.removed += merged.removed;
			counts.pending += merged.pending;
		}
	}
	return { patch, counts };
}

export function mergeConfig(main, settings, feed, allowDeletes, ignored) {
	let lists = core.mergeSection(main, feed.lists, allowDeletes);
	let extra = mergeOptions(main, feed.main, allowDeletes);
	let global = mergeOptions(settings, feed.settings, allowDeletes);
	let patches = { main: { ...lists.patch, ...extra.patch }, settings: global.patch };
	// Не меняем защищённые параметры неявно при включении списка или переходе на URLTest
	for (let field in ignored || []) {
		let parts = split(canonicalField(field), '.');
		let group = parts[0], key = parts[1];
		if (!exists(patches[group], key)) continue;
		let current = group == 'main' ? main : settings;
		if (sprintf('%J', patches[group][key]) != sprintf('%J', current[key])) die('protected_option_required');
		delete patches[group][key];
	}
	return { patches,
		counts: { ...lists.counts, main_options: extra.counts, settings: global.counts } };
};
