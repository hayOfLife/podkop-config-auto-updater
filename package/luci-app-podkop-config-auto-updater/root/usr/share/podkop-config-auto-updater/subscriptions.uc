import { buildBrowsec } from 'browsec';
import { buildSubix, buildNeoVps } from 'subix';

const allowed = ['Германия', 'Germany', '🇩🇪', 'Казахстан', 'Kazakhstan', '🇰🇿',
	'Украина', 'Ukraine', '🇺🇦', 'Польша', 'Poland', '🇵🇱', 'Швеция', 'Sweden', '🇸🇪',
	'Турция', 'Turkey', '🇹🇷', 'США', 'Соединенные Штаты', 'United States', '🇺🇸',
	'Латвия', 'Latvia', '🇱🇻', 'Нидерланды', 'Netherlands', '🇳🇱', 'Эстония', 'Estonia', '🇪🇪',
	'Франция', 'France', '🇫🇷', 'Румыния', 'Romania', '🇷🇴', 'Финляндия', 'Finland', '🇫🇮'];
const blocked = ['Обход', 'LTE', 'Россия', 'Russia', 'Беларусь', 'Belarus', 'MIX', 'AUTO', 'АВТО',
	'Европа', 'Europe', 'test', 'тест', 'Китай', 'China', 'Гонконг', 'Hong Kong',
	'Макао', 'Macau', 'Иран', 'Iran', 'КНДР', 'Куба', 'Cuba', 'Сирия', 'Syria'];

function same(a, b) { return sprintf('%J', a) == sprintf('%J', b); }

export function subscriptionPatches(current, account, data, uuid, reuseExisting) {
	let id = account['.name'];
	if (type(id) != 'string' || !match(id, /^[A-Za-z_][A-Za-z0-9_]{0,39}$/)) die('subscription_invalid_id');
	if (index(['browsec', 'subix', 'neovps'], account.provider) < 0) die('subscription_unknown_provider');
	let prefix = 'pca_' + id, names = [prefix + '_s1', prefix + '_s2'];
	if (account.provider == 'browsec' && !current[names[0]] && !current[names[1]] && reuseExisting) {
		let found = [null, null];
		for (let name, source in current) {
			if (source['.type'] != 'source') continue;
			for (let i = 0; i < 2; i++) {
				if (source.label != 'Browsec Premium · ' + (i + 1)) continue;
				if (found[i]) die('browsec_sources_ambiguous');
				found[i] = name;
			}
		}
		if (found[0] && found[1]) {
			names = found;
		}
	}
	if (account.provider != 'browsec') names = [names[0]];
	let old = [];
	for (let name in names) {
		let source = current[name];
		if (source && (source['.type'] != 'source' || source.type != 'links')) die('subscription_source_collision');
		push(old, source?.link || null);
	}
	let values, count, skipped = 0, excluded = 0;
	if (account.provider == 'browsec') {
		let built = buildBrowsec(data, old[0], old[1], uuid);
		values = [built.first, built.second];
		count = built.count;
	}
	else {
		let built = account.provider == 'neovps' ? buildNeoVps(data) : buildSubix(data);
		if (old[0] && (type(old[0]) != 'array' || length(built.links) * 10 < length(old[0]) * 7))
			die(account.provider == 'neovps' ? 'neovps_incomplete_response' : 'subix_incomplete_response');
		values = [built.links];
		count = length(built.links);
		skipped = built.skipped;
		excluded = built.excluded;
	}
	let patches = {}, types = {}, members = [];
	for (let i = 0; i < length(names); i++) {
		let name = names[i], source = current[name];
		if (!source) {
			let label = (account.provider == 'browsec' ? 'Browsec Premium' : account.provider == 'neovps' ? 'NeoVPS' : 'Subix') + ' · ' + id + (length(names) > 1 ? ' · ' + (i + 1) : '');
			patches[name] = { type: 'links', label, link: values[i] };
		}
		else if (!same(source.link, values[i])) patches[name] = { link: values[i] };
		types[name] = 'source';
	}
	for (let i = 0; i < length(names); i++) {
		for (let rule in ['main', 'notUnderSanctions']) {
			let found = false;
			for (let name, member in current) {
				if (member['.type'] != 'member' || member.source != names[i] || member.section != rule ||
					(member.role && member.role != 'server')) continue;
				push(members, name);
				found = true;
			}
			if (!found && !current[names[i]]) {
				let memberName = prefix + (rule == 'main' ? '_m' : '_n') + (i + 1);
				let member = current[memberName];
				if (member && (member['.type'] != 'member' || member.source != names[i] || member.section != rule)) die('subscription_member_collision');
				if (!member) {
					patches[memberName] = { section: rule, source: names[i], role: 'server',
						exclude: rule == 'main' ? ['Обход', 'LTE'] : blocked };
					if (rule == 'notUnderSanctions') patches[memberName].include = allowed;
				}
				types[memberName] = 'member';
				push(members, memberName);
			}
		}
	}
	return { patches, native: { types, delete_sections: [], replace_members: [], member_names: members }, count, skipped, excluded };
};
