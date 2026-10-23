export function sourceRequest(url, token) {
	if (type(url) != 'string' || length(url) > 2048 || match(url, /[[:space:][:cntrl:]]/)) die('invalid_source');
	let github = match(url, /^https:\/\/github\.com\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_.-]+)\/blob\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_./-]+)$/);
	if (github)
		url = 'https://api.github.com/repos/' + github[1] + '/' + github[2] + '/contents/' + github[4] + '?ref=' + github[3];
	let api = match(url, /^https:\/\/api\.github\.com\/repos\/[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+\/contents\/[A-Za-z0-9_./-]+\?ref=[A-Za-z0-9_.-]+$/);
	if (match(url, /^https:\/\/(github\.com|api\.github\.com)\//) && !api) die('invalid_github_url');
	if (!match(url, /^https:\/\/[A-Za-z0-9.-]+(:[0-9]+)?\/[^#]*$/) || index(url, '/../') >= 0) die('invalid_source');
	let headers = 'Accept: application/json\n';
	if (api) {
		if (type(token) != 'string' || length(token) > 4096 || index(token, '\u0000') >= 0 ||
			match(token, /[[:space:][:cntrl:]]/) || !match(token, /^[A-Za-z0-9_]+$/)) die('missing_token');
		headers = 'Accept: application/vnd.github.raw+json\nAuthorization: Bearer ' + token + '\nX-GitHub-Api-Version: 2022-11-28\n';
	}
	else if (length(token || '')) die('token_host_mismatch');
	return { url, headers };
};
