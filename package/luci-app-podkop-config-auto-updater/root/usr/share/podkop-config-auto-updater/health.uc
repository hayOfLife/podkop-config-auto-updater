export function classifyProbe(curlExit, httpStatus, body) {
	if (index([51, 60, 77], curlExit) >= 0) return 'unknown';
	if (curlExit !== 0) {
		if (httpStatus === 429) return 'rate_limited';
		if (httpStatus >= 500 && httpStatus <= 599) return 'service_error';
		return httpStatus > 0 ? 'unknown' : 'network_error';
	}
	if (httpStatus === 0) return 'network_error';
	let response = null;
	if (type(body) == 'string' && length(body) <= 65536) {
		try { response = json(body); } catch (e) {}
	}
	let error = type(response) == 'object' && type(response.error) == 'object' ? response.error : null;
	if (error?.code === 'unsupported_country_region_territory') return 'region_blocked';
	if (httpStatus === 429) return 'rate_limited';
	if (httpStatus >= 500 && httpStatus <= 599) return 'service_error';
	if (httpStatus !== 401 || error?.type !== 'invalid_request_error' || error.code != null || type(error.message) != 'string')
		return 'unknown';
	if (index(error.message, '\u0000') >= 0) return 'unknown';
	// Только ответ об отсутствующем ключе подтверждает достижение обычной проверки авторизации
	if (match(error.message, /^Missing bearer authentication( in header)?\.?$/) || error.message === 'Missing bearer or basic authentication in header' ||
		error.message === "You didn't provide an API key." ||
		index(error.message, "You didn't provide an API key. You need to provide your API key in an Authorization header using Bearer auth") === 0)
		return 'reachable';
	return 'unknown';
};

export function planProbe(previous, selected, result, now) {
	if (index(['reachable', 'region_blocked', 'network_error', 'rate_limited', 'service_error', 'unknown', 'route_unconfirmed'], result) < 0)
		die('invalid_probe_result');
	let failures = result == 'network_error' ? (previous?.selected == selected ? previous.failures || 0 : 0) + 1 : 0;
	let rotate = result == 'region_blocked' || failures >= 3;
	return { selected, result, failures: failures > 3 ? 3 : failures,
		action: rotate ? 'rotate' : 'keep', next_check: now + (rotate ? 0 : result == 'rate_limited' ? 600 : result == 'network_error' ? 30 : 180) };
};
