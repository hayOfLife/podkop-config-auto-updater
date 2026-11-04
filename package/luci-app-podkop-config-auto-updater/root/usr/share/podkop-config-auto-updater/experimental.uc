const rules = ['main', 'notUnderSanctions'];
const sourceFields = ['type', 'label', 'url', 'update_interval'];
const memberFields = ['section', 'source', 'role', 'include', 'exclude', 'via'];

function safeName(name) {
	return type(name) == 'string' && match(name, /^[A-Za-z_][A-Za-z0-9_]{0,63}$/) &&
		index(['settings', 'main', 'notUnderSanctions', 'direct', 'block'], name) < 0;
}

function text(value, maximum) {
	if (type(value) != 'string' || length(value) > maximum || index(value, '\u0000') >= 0 || match(value, /[[:cntrl:]]/))
		die('invalid_native_option');
}

function words(value) {
	if (type(value) != 'array' || length(value) > 256) die('invalid_native_filter');
	let seen = {};
	for (let item in value) {
		text(item, 128);
		if (!length(trim(item)) || seen[item]) die('invalid_native_filter');
		seen[item] = true;
	}
}

function entries(input, fields, kind) {
	if (type(input) != 'object' || length(keys(input)) > 128) die('invalid_native_sections');
	for (let name, values in input) {
		if (!safeName(name) || type(values) != 'object' || !length(keys(values))) die('invalid_native_sections');
		for (let key, value in values) {
			if (index(fields, key) < 0) die('invalid_native_option');
			if (key == 'include' || key == 'exclude') words(value);
			else text(value, key == 'url' ? 8192 : key == 'label' ? 64 : 128);
		}
		if (kind == 'source') {
			if (values.type != 'subscription' || !match(values.url || '', /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[^[:space:]]*)?$/))
				die('invalid_native_source');
			if (exists(values, 'update_interval') && values.update_interval != 'auto' && !match(values.update_interval, /^[1-9][0-9]{0,5}[mhd]$/))
				die('invalid_native_source');
		}
		else if (index(rules, values.section) < 0 || !safeName(values.source) ||
			index(['server', 'fallback'], values.role) < 0 || (values.via && (!safeName(values.via) || values.via == values.source)))
			die('invalid_native_member');
	}
	return input;
}

export function validateNative(input) {
	let sources = entries(input.sources, sourceFields, 'source');
	let members = entries(input.members, memberFields, 'member');
	for (let name in keys(sources)) if (exists(members, name)) die('native_section_collision');
	let replace = exists(input, 'replace_members') ? input.replace_members : [];
	if (type(replace) != 'array' || length(replace) > 2) die('invalid_native_membership');
	let seen = {};
	for (let rule in replace) {
		if (index(rules, rule) < 0 || seen[rule] || !length(filter(keys(members), name => members[name].section == rule)))
			die('invalid_native_membership');
		seen[rule] = true;
	}
	return { sources, members, replace_members: replace };
};

export function nativeFields(input) {
	let fields = [];
	for (let group in ['sources', 'members'])
		for (let name, values in input[group])
			for (let key in keys(values)) push(fields, group + '.' + name + '.' + key);
	for (let rule in input.replace_members || []) push(fields, 'membership.' + rule);
	return fields;
};

export function selectNative(native, ignored) {
	let result = { sources: {}, members: {}, replace_members: native.replace_members, original: native };
	for (let group in ['sources', 'members']) {
		for (let name, values in native[group]) {
			result[group][name] = {};
			for (let key, value in values)
				if (index(ignored, group + '.' + name + '.' + key) < 0) result[group][name][key] = value;
		}
	}
	return result;
};

function equal(left, right) {
	return sprintf('%J', left) == sprintf('%J', right);
}

function sameOption(key, left, right) {
	if ((key == 'include' || key == 'exclude') && left == null && type(right) == 'array' && !length(right)) return true;
	return equal(left, right);
}

function filled(source) {
	if (source?.['.type'] != 'source') return false;
	if (source.type == 'subscription') return type(source.url) == 'string' && length(trim(source.url));
	if (source.type == 'links') return length(source.link || []);
	if (source.type == 'json') return length(trim(source.outbound_json || ''));
	return source.type == 'interface';
}

export function mergeNative(native, current, allowDeletes, ignored) {
	if (current?.settings?.['.type'] != 'settings' || current.settings.config_version != '2') die('experimental_version_required');
	let original = native.original || native;
	let patches = {}, types = {}, counts = { added: 0, removed: 0, pending: 0 }, removed = [];
	for (let group in ['sources', 'members']) {
		let expected = group == 'sources' ? 'source' : 'member';
		for (let name, values in native[group]) {
			let old = current[name] || {};
			if (old['.type'] && old['.type'] != expected) die('native_section_collision');
			let patch = {};
			for (let key, value in values) if (!sameOption(key, old[key], value)) { patch[key] = value; counts.added++; }
			if (length(keys(patch))) { patches[name] = patch; types[name] = expected; }
		}
	}
	let effective = {};
	for (let name, values in current) effective[name] = { ...values };
	for (let name, patch in patches) effective[name] = { ...(effective[name] || {}), ...patch, '.type': types[name] };
	for (let rule in native.replace_members) {
		let declared = filter(keys(original.members), name => original.members[name].section == rule);
		for (let name, values in current) {
			if (values['.type'] != 'member' || values.section != rule || index(declared, name) >= 0) continue;
			if (index(ignored, 'membership.' + rule) >= 0) die('protected_option_required');
			if (!allowDeletes) die('native_membership_delete_disabled');
			push(removed, name);
			delete effective[name];
			counts.removed++;
		}
		// Защищённое поле не должно подменить новый состав серверов при удалении прежних строк
		for (let name in declared) {
			for (let key, value in original.members[name])
				if (index(ignored, 'members.' + name + '.' + key) >= 0 && !sameOption(key, current[name]?.[key], value)) die('protected_option_required');
			for (let sourceName in [original.members[name].source, original.members[name].via]) {
				if (!sourceName || !original.sources[sourceName]) continue;
				for (let key, value in original.sources[sourceName])
					if (index(ignored, 'sources.' + sourceName + '.' + key) >= 0 && !equal(current[sourceName]?.[key], value)) die('protected_option_required');
			}
		}
	}
	let routable = {};
	for (let name, values in effective) {
		if (values['.type'] != 'member' || index(rules, values.section) < 0) continue;
		if (!exists(original.members, name) && index(native.replace_members, values.section) < 0) continue;
		if (!filled(effective[values.source]) || (values.via && (!filled(effective[values.via]) || values.via == values.source)))
			die('invalid_native_reference');
		if (index(['server', 'fallback'], values.role || 'server') < 0) die('invalid_native_member');
		routable[values.section] = true;
	}
	for (let name, values in original.members)
		if (!effective[name] || effective[name]['.type'] != 'member' || effective[name].section != values.section) die('protected_option_required');
	for (let rule in native.replace_members) if (!routable[rule]) die('native_empty_membership');
	return { patches, types, delete_sections: removed, replace_members: native.replace_members, counts, routable };
};

export function validateNativeCursor(staged) {
	if (staged.get('podkop', 'settings') != 'settings' || staged.get('podkop', 'settings', 'config_version') != '2')
		die('experimental_version_required');
	let route = staged.get('podkop', 'settings', 'download_lists_via_proxy_section');
	if (staged.get('podkop', 'settings', 'download_lists_via_proxy') != '1') return;
	if (!route || staged.get('podkop', route) != 'section') die('invalid_proxy_section');
	let valid = false;
	staged.foreach('podkop', 'member', member => {
		if (member.section != route) return;
		let source = staged.get_all('podkop', member.source);
		if (filled(source)) valid = true;
	});
	if (!valid) die('invalid_proxy_section');
};
