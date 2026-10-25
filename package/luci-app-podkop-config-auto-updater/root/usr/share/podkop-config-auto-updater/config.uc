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
	if (match(field, /^(main|notUnderSanctions)\.user_(domains|subnets)_text$/)) return replace(field, /_text$/, '');
	return field;
}

function configGroups(input) {
	return input.schema_version === 3 ? ['main', 'notUnderSanctions', 'settings'] : ['main', 'settings'];
}

export function configFields(input) {
	if (input.schema_version === 1) return map(listFields, key => 'main.' + key);
	let fields = [];
	for (let group in configGroups(input))
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
		return { sections: { main: { lists: core.validateFeed(input), options: {} } }, settings: {}, revision: input.revision };
	if (type(input) != 'object' || (input.schema_version !== 2 && input.schema_version !== 3) || type(input.main) != 'object' || type(input.settings) != 'object' ||
		(input.schema_version === 3 && type(input.notUnderSanctions) != 'object'))
		die('invalid_schema');
	let groups = configGroups(input);
	for (let key in keys(input))
		if (index(['schema_version', 'revision', ...groups], key) < 0) die('unknown_field');
	let result = { sections: {}, settings: {}, revision: input.revision, ordered: input.schema_version === 3 };
	for (let group in groups) {
		let lists = { schema_version: 1, section: 'main', revision: input.revision,
			urltest_proxy_links: [], user_domains: [], user_subnets: [] };
		let options = {};
		if (length(keys(input[group])) > 256) die('too_many_options');
		for (let key, value in input[group]) {
			if (index(key, '\u0000') >= 0 || match(key, /[[:space:][:cntrl:]]/) || !match(key, /^[a-z][a-z0-9_]{0,63}$/)) die('invalid_option_name');
			if (group == 'settings' && index(settingsFields, key) < 0) die('unsupported_setting');
			if (group != 'settings' && index(listFields, key) >= 0) { lists[key] = value; continue; }
			if (group != 'settings' && index(['user_domains_text', 'user_subnets_text'], key) >= 0) {
				let canonical = replace(key, /_text$/, '');
				if (exists(input[group], canonical) || type(value) != 'string') die('ambiguous_list');
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
				options[key] = { kind: 'list', entries };
			}
			else {
				let entry = operation(value);
				if (group == 'settings') validateSetting(key, entry.value);
				options[key] = { kind: 'scalar', entry };
			}
		}
		if (group == 'settings') result.settings = options;
		else result.sections[group] = { lists: core.validateFeed(lists, input.schema_version === 3), options };
	}
	return result;
};

function sectionMoves(feed) {
	let moves = [];
	if (!feed.ordered) return moves;
	for (let source in ['main', 'notUnderSanctions']) {
		let target = source == 'main' ? 'notUnderSanctions' : 'main';
		let sourceSection = feed.sections[source], targetSection = feed.sections[target];
		let listKeys = [...listFields];
		for (let key, option in sourceSection.options)
			if (option.kind == 'list') push(listKeys, key);
		for (let key in listKeys) {
			let generic = index(listFields, key) < 0;
			let sourceOps = generic ? sourceSection.options[key].entries : sourceSection.lists[key];
			let targetOps = generic ? targetSection.options[key]?.entries || [] : targetSection.lists[key];
			let additions = {};
			for (let op in targetOps)
				if (!op.remove && !exists(op, 'comment')) additions[op.value] = true;
			for (let op in sourceOps)
				if (op.remove && additions[op.value]) push(moves, { source, target, key, value: op.value });
		}
	}
	return moves;
}

export function selectConfig(input, ignored) {
	// Проверяем весь файл, даже когда локальная настройка запрещает применять часть полей
	let validated = validateConfig(input);
	if (type(ignored) != 'array') die('invalid_ignored_options');
	for (let field in ignored)
		if (type(field) != 'string' || !match(field, /^(main|notUnderSanctions|settings)\.[a-z][a-z0-9_]{0,63}$/) || match(field, /[[:space:][:cntrl:]]/))
			die('invalid_ignored_options');
	ignored = map(ignored, canonicalField);
	let selected = { ...input };
	if (input.schema_version === 1) {
		for (let key in listFields)
			if (index(ignored, 'main.' + key) >= 0) selected[key] = [];
	}
	else {
		for (let group in configGroups(input)) {
			selected[group] = {};
			for (let key, value in input[group])
				if (index(ignored, canonicalField(group + '.' + key)) < 0) selected[group][key] = value;
		}
	}
	let result = validateConfig(selected);
	result.moves = sectionMoves(validated);
	return result;
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

function currentValues(section, key) {
	let values = section[key] || [];
	if (type(values) == 'string') values = [values];
	if (key == 'user_domains' || key == 'user_subnets') values = [...values, ...core.tokens(section[key + '_text'])];
	if (key == 'urltest_proxy_links' && (!section.connection_type || section.connection_type == 'proxy') &&
		(section.proxy_config_type || 'url') == 'url' && length(section.proxy_string || '')) values = [...values, section.proxy_string];
	return values;
}

function valueIndex(key, values) {
	let indexed = {};
	for (let value in values) {
		try { value = core.normalize(index(listFields, key) < 0 ? 'literal' : key, value); } catch (e) {}
		indexed[value] = true;
	}
	return indexed;
}

export function mergeConfig(main, settings, feed, allowDeletes, ignored, restricted) {
	let current = { main, settings, notUnderSanctions: restricted || {} };
	ignored = map(ignored || [], canonicalField);
	let activeMoves = [], sourceIndexes = {};
	for (let move in feed.moves || sectionMoves(feed)) {
		let field = move.source + '.' + move.key;
		if (!exists(sourceIndexes, field)) sourceIndexes[field] = valueIndex(move.key, currentValues(current[move.source], move.key));
		let present = sourceIndexes[field][move.value];
		if (present && (!allowDeletes || index(ignored, move.source + '.' + move.key) >= 0 || index(ignored, move.target + '.' + move.key) >= 0))
			die('section_move_blocked');
		if (present) push(activeMoves, move);
	}
	let patches = {}, counts = {};
	for (let name, section in feed.sections) {
		let old = current[name];
		let lists = core.mergeSection(old, section.lists, allowDeletes, section.options);
		let extra = mergeOptions(old, section.options, allowDeletes);
		patches[name] = { ...lists.patch, ...extra.patch };
		for (let key, count in lists.counts) counts[name == 'main' ? key : name + '.' + key] = count;
		counts[name + '_options'] = extra.counts;
		let updated = { ...old, ...patches[name] };
		if (updated.connection_type == 'proxy' && updated.proxy_config_type == 'urltest' && !length(updated.urltest_proxy_links || [])) die('empty_proxy_pool');
		for (let kind in ['user_domains', 'user_subnets']) {
			let typeKey = kind == 'user_domains' ? 'user_domain_list_type' : 'user_subnet_list_type';
			if (length(filter(section.lists[kind], op => exists(op, 'comment'))) &&
				length(filter(section.lists[kind], op => !op.remove && !exists(op, 'comment'))) && updated[typeKey] != 'text') die('comments_require_text');
		}
	}
	// Перенос не должен удалить рабочий маршрут раньше появления включённого списка и пула в целевой секции
	let targetIndexes = {};
	for (let move in activeMoves) {
		let field = move.target + '.' + move.key;
		if (!exists(targetIndexes, field)) {
			let target = { ...current[move.target], ...patches[move.target] };
			if (target.connection_type != 'proxy' || target.proxy_config_type != 'urltest' || !length(target.urltest_proxy_links || []))
				die('section_move_blocked');
			let values = currentValues(target, move.key);
			if (move.key == 'user_domains' || move.key == 'user_subnets') {
				let typeKey = move.key == 'user_domains' ? 'user_domain_list_type' : 'user_subnet_list_type';
				if (target[typeKey] == 'text') values = core.tokens(target[move.key + '_text']);
				else if (target[typeKey] == 'dynamic') values = target[move.key] || [];
				else die('section_move_blocked');
				if (type(values) == 'string') values = [values];
			}
			targetIndexes[field] = valueIndex(move.key, values);
		}
		if (!targetIndexes[field][move.value]) die('section_move_blocked');
	}
	let global = mergeOptions(settings, feed.settings, allowDeletes);
	patches.settings = global.patch;
	counts.settings = global.counts;
	// Не меняем защищённые параметры неявно при включении списка или переходе на URLTest
	for (let group, patch in patches) {
		for (let key in keys(patch)) {
			if (index(ignored, canonicalField(group + '.' + key)) < 0) continue;
			if (sprintf('%J', patch[key]) != sprintf('%J', current[group][key])) die('protected_option_required');
			delete patch[key];
		}
	}
	return { patches, counts, order: feed.ordered ? ['notUnderSanctions', 'main'] : null };
};
