import { escapeURI } from 'providers';

const countries = {
	bg: 'Болгария', es: 'Испания', fr: 'Франция', hk: 'Гонконг', in: 'Индия', it: 'Италия',
	no: 'Норвегия', sg: 'Сингапур', au: 'Австралия', nl: 'Нидерланды', us: 'Соединенные Штаты',
	br: 'Бразилия', jp: 'Япония', kr: 'Южная Корея', mx: 'Мексика', se: 'Швеция', ch: 'Швейцария',
	cy: 'Кипр', fi: 'Финляндия', tr: 'Турция', ie: 'Ирландия', gr: 'Греция', pl: 'Польша',
	lt: 'Литва', hu: 'Венгрия', ca: 'Канада', be: 'Бельгия', hr: 'Хорватия', lv: 'Латвия',
	dk: 'Дания', za: 'ЮАР', il: 'Израиль', at: 'Австрия', si: 'Словения', usw: 'Соединенные Штаты (запад)',
	ru: 'Россия', uk: 'Великобритания', de: 'Германия', ua: 'Украина', rs: 'Сербия', ro: 'Румыния',
	cz: 'Чехия', cl: 'Чили', is: 'Исландия'
};

function fail(code) { die(code); }

function template(link) {
	if (type(link) != 'string') fail('browsec_invalid_template');
	let parts = match(link, /^vless:\/\/([0-9a-fA-F-]{36})@([^?]+)\?([^#]+)#(.+)$/);
	if (!parts || !match(parts[1], /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) ||
		index(parts[4], 'Browsec') < 0) fail('browsec_invalid_template');
	let address = match(parts[2], /:([0-9]{1,5})$/);
	if (!address || int(address[1]) < 1 || int(address[1]) > 65535) fail('browsec_invalid_template');
	let query = [], sni = 0;
	for (let entry in split(parts[3], '&')) {
		if (match(entry, /^sni=/)) sni++;
		else push(query, entry);
	}
	if (sni != 1 || index(query, 'security=reality') < 0 || index(query, 'type=tcp') < 0 ||
		!filter(query, entry => match(entry, /^pbk=[A-Za-z0-9_-]+$/))[0] ||
		!filter(query, entry => match(entry, /^sid=[A-Za-z0-9]+$/))[0]) fail('browsec_invalid_template');
	return { uuid: parts[1], port: address[1], query: join('&', query) };
}

function ipv4(value) {
	if (type(value) != 'string' || !match(value, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) return false;
	for (let part in split(value, '.')) if (int(part) > 255 || length(part) > 3) return false;
	return true;
}

export function buildBrowsec(data, first, second, accountUuid) {
	if (!first && !second && accountUuid) {
		let seed = 'vless://' + accountUuid + '@192.0.2.1:63821?encryption=none&security=reality&type=tcp' +
			'&flow=xtls-rprx-vision&fp=firefox&pbk=koKaMgyyxUFwSa28okVxBsicQqXgkSi_sa-KblM2MUM' +
			'&sid=bbb43890f4d92fd5&sni=example.com#Browsec';
		first = [seed];
		second = [seed];
	}
	if (type(first) != 'array' || type(second) != 'array' || !length(first) || !length(second)) fail('browsec_sources_empty');
	let base = template(first[0]);
	for (let link in [...first, ...second]) {
		let current = template(link);
		if (current.uuid != base.uuid || current.port != base.port || current.query != base.query) fail('browsec_sources_mixed');
	}
	if (accountUuid) {
		if (!match(accountUuid, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/)) fail('browsec_invalid_account');
		base.uuid = accountUuid;
	}
	if (type(data) != 'object' || type(data.countries) != 'object') fail('browsec_invalid_response');
	let result = [], seen = {};
	for (let code in sort(keys(data.countries))) {
		if (!match(code, /^[a-z]{2,3}$/)) fail('browsec_invalid_response');
		let groups = data.countries[code]?.premium_servers;
		if (type(groups) != 'array') fail('browsec_invalid_response');
		for (let group in groups) {
			if (type(group.ip) != 'array' || type(group.xsni) != 'array' || length(group.ip) != length(group.xsni)) fail('browsec_invalid_response');
			for (let i = 0; i < length(group.ip); i++) {
				let ip = group.ip[i], sni = group.xsni[i];
				if (!ipv4(ip) || type(sni) != 'string' || length(sni) > 253 || !match(sni, /^[A-Za-z0-9.-]+$/)) fail('browsec_invalid_response');
				let key = code + '|' + ip + '|' + sni;
				if (!seen[key]) seen[key] = { code, ip, sni };
			}
		}
	}
	for (let key in sort(keys(seen))) {
		let server = seen[key];
		let label = (countries[server.code] || ('Страна ' + server.code)) + ' · Browsec ' + sprintf('%03d', length(result) + 1);
		push(result, 'vless://' + base.uuid + '@' + server.ip + ':' + base.port + '?' + base.query + '&sni=' + escapeURI(server.sni) + '#' + escapeURI(label));
	}
	if (length(result) < 20 || length(result) * 10 < (length(first) + length(second)) * 7) fail('browsec_incomplete_response');
	let midpoint = int((length(result) + 1) / 2);
	return { first: slice(result, 0, midpoint), second: slice(result, midpoint), count: length(result) };
};
