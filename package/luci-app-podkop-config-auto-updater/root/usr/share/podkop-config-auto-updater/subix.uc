import { escapeURI } from 'providers';

function excluded(name) {
	name = replace(replace(replace(replace(name, /О/g, 'о'), /Б/g, 'б'), /Х/g, 'х'), /Д/g, 'д');
	return index(name, 'обход') >= 0 || index(lc(name), 'lte') >= 0;
}

function parameter(values, name, value) {
	if (value == null || value == '') return;
	if (type(value) != 'string') die('subix_invalid_value');
	push(values, name + '=' + escapeURI(value));
}

function onlyKeys(value, allowed) {
	if (type(value) != 'object') return false;
	for (let key in keys(value)) if (index(allowed, key) < 0) return false;
	return true;
}

function convert(outbound, label) {
	if (outbound.protocol != 'vless' || !onlyKeys(outbound, ['protocol', 'settings', 'streamSettings', 'tag', 'mux']) ||
		(outbound.mux && (!onlyKeys(outbound.mux, ['enabled']) || outbound.mux.enabled))) return null;
	let servers = outbound.settings?.vnext;
	if (!onlyKeys(outbound.settings, ['vnext']) || type(servers) != 'array' || length(servers) != 1 ||
		!onlyKeys(servers[0], ['address', 'port', 'users']) || type(servers[0].users) != 'array' || length(servers[0].users) != 1) return null;
	let server = servers[0], user = server.users[0], stream = outbound.streamSettings || {};
	if (!onlyKeys(user, ['id', 'encryption', 'flow']) || !onlyKeys(stream, ['network', 'security', 'tlsSettings', 'realitySettings',
		'tcpSettings', 'wsSettings', 'xhttpSettings', 'splithttpSettings', 'grpcSettings']) ||
		type(server.address) != 'string' || !match(server.address, /^[A-Za-z0-9.-]+$/) ||
		int(server.port) < 1 || int(server.port) > 65535 || type(user.id) != 'string' ||
		!match(user.id, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) ||
		index(['', 'none'], user.encryption || '') < 0 || index(['', 'xtls-rprx-vision'], user.flow || '') < 0 ||
		stream.sockopt || stream.finalmask) return null;
	let network = stream.network || 'tcp', security = stream.security || 'none';
	if (index(['tcp', 'ws', 'xhttp', 'grpc'], network) < 0 || index(['tls', 'reality'], security) < 0) return null;
	if ((security == 'reality' && index(['ws', 'grpc'], network) >= 0) ||
		(user.flow == 'xtls-rprx-vision' && network != 'tcp')) return null;
	let tls = security == 'reality' ? stream.realitySettings || {} : stream.tlsSettings || {};
	if (!onlyKeys(tls, security == 'reality' ? ['serverName', 'fingerprint', 'publicKey', 'shortId', 'spiderX'] :
		['serverName', 'fingerprint', 'alpn', 'allowInsecure']) || tls.allowInsecure || !tls.serverName ||
		(security == 'reality' && !tls.publicKey)) return null;
	let options = [];
	parameter(options, 'type', network);
	parameter(options, 'security', security);
	parameter(options, 'encryption', user.encryption || 'none');
	parameter(options, 'flow', user.flow);
	parameter(options, 'sni', tls.serverName);
	parameter(options, 'fp', tls.fingerprint);
	if (type(tls.alpn) == 'array') parameter(options, 'alpn', join(',', tls.alpn));
	if (security == 'reality') {
		parameter(options, 'pbk', tls.publicKey);
		parameter(options, 'sid', tls.shortId);
		parameter(options, 'spx', tls.spiderX);
	}
	if (network == 'tcp' && stream.tcpSettings && (!onlyKeys(stream.tcpSettings, ['header']) ||
		(stream.tcpSettings.header && (!onlyKeys(stream.tcpSettings.header, ['type']) || stream.tcpSettings.header.type != 'none')))) return null;
	if (network == 'ws') {
		let ws = stream.wsSettings || {};
		if (!onlyKeys(ws, ['path', 'headers', 'heartbeatPeriod'])) return null;
		for (let key in keys(ws.headers || {})) if (lc(key) != 'host') return null;
		parameter(options, 'path', ws.path);
		parameter(options, 'host', ws.headers?.Host || ws.headers?.host);
		if (ws.heartbeatPeriod) parameter(options, 'heartbeatPeriod', '' + ws.heartbeatPeriod);
	}
	if (network == 'xhttp') {
		let x = stream.xhttpSettings || stream.splithttpSettings || {};
		if (!onlyKeys(x, ['mode', 'path', 'host', 'extra'])) return null;
		parameter(options, 'mode', x.mode);
		parameter(options, 'path', x.path);
		parameter(options, 'host', x.host);
		if (x.extra) {
			if (type(x.extra) != 'object') return null;
			parameter(options, 'extra', sprintf('%J', x.extra));
		}
	}
	if (network == 'grpc') {
		let g = stream.grpcSettings || {};
		if (!onlyKeys(g, ['mode', 'serviceName', 'authority']) || (g.mode && g.mode != 'gun')) return null;
		parameter(options, 'serviceName', g.serviceName);
		parameter(options, 'authority', g.authority);
		parameter(options, 'mode', g.mode);
	}
	return 'vless://' + user.id + '@' + server.address + ':' + int(server.port) + '?' + join('&', options) + '#' + escapeURI(label);
}

export function buildSubix(data) {
	if (type(data) != 'array' || !length(data) || length(data) > 1000) die('subix_invalid_response');
	let links = [], skipped = 0, excludedCount = 0;
	for (let config in data) {
		if (type(config) != 'object' || type(config.remarks) != 'string' || !length(config.remarks) ||
			length(config.remarks) > 512 || match(config.remarks, /[[:cntrl:]]/)) die('subix_invalid_response');
		if (excluded(config.remarks)) { excludedCount++; continue; }
		let outbounds = filter(config.outbounds || [], outbound => outbound.protocol == 'vless');
		if (!length(outbounds)) { skipped++; continue; }
		for (let i = 0; i < length(outbounds); i++) {
			let label = config.remarks + (length(outbounds) > 1 ? ' · ' + (i + 1) : '');
			let link = convert(outbounds[i], label);
			if (link) push(links, link); else skipped++;
		}
	}
	if (!length(links)) die('subix_no_servers');
	return { links: sort(links), skipped, excluded: excludedCount };
};

export function buildNeoVps(data) {
	if (type(data) != 'array' || !length(data) || length(data) > 1000) die('neovps_invalid_response');
	let individual = [];
	for (let config in data) {
		if (type(config) != 'object' || type(config.outbounds) != 'array') die('neovps_invalid_response');
		// Общий профиль содержит несколько выходов и не задаёт страну каждого сервера
		if (length(filter(config.outbounds, outbound => outbound.protocol == 'vless')) != 1) continue;
		push(individual, config);
	}
	if (!length(individual)) die('neovps_no_servers');
	try { return buildSubix(individual); }
	catch (error) {
		let code = split(error.message || '', '\n')[0];
		if (code == 'subix_no_servers') die('neovps_no_servers');
		if (code == 'subix_invalid_response' || code == 'subix_invalid_value') die('neovps_invalid_response');
		die('subscription_internal_error');
	}
};
