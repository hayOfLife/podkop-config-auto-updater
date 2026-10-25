import { parseConfig, validateConfig, selectConfig, configFields, mergeConfig } from 'config';
import { readfile } from 'fs';
let passed = 0;
function check(value, label) { if (!value) die(label); passed++; }
function rejects(fn, label) { let failed = false; try { fn(); } catch (e) { failed = true; } check(failed, label); }
function rejectsCode(fn, code, label) { let actual = ''; try { fn(); } catch (e) { actual = split(e.message || '', '\n')[0]; } check(actual == code, label); }
check(parseConfig('// Заголовок\n{"x": [/* Группа */1, 2]} // Конец').x[1] == 2, 'line and block comments including EOF');
check(parseConfig('{"url":"https://example.com/a/*b*/", "text":"// keep"}').text == '// keep', 'preserve comment markers inside strings');
let escaped = { text: 'quote " slash \\ // /* */', url: 'vless://demo@example.com' };
check(parseConfig(sprintf('%J', escaped)).text == escaped.text, 'preserve escaped quotes and backslashes');
check(parseConfig('{// heading\r"x":1}').x == 1, 'CR line ending');
rejects(() => parseConfig('{"x":1/* unfinished}'), 'reject unfinished block comment');
rejects(() => parseConfig('{"x":1/* gap */2}'), 'comments must not concatenate number tokens');
rejects(() => parseConfig('{"x":tr/* gap */ue}'), 'comments must not concatenate literal tokens');
check(parseConfig('{"x":[1,]}').x[0] == 1, 'preserve native parser trailing comma compatibility');
rejects(() => parseConfig('{"x":"unterminated // text}'), 'unterminated string remains invalid');
let input = { schema_version: 2, revision: 'extended-1', main: {
	urltest_check_interval: '5m', future_option: 'value', community_lists: ['telegram', 'google_play'],
	user_domains: ['example.com']
}, settings: { dns_type: 'doh', dns_server: 'dns.example.com/dns-query', bootstrap_dns_server: '192.0.2.1',
	download_lists_via_proxy: '1', update_interval: '3h', download_lists_via_proxy_section: 'main' } };
let feed = validateConfig(input);
let result = mergeConfig({ community_lists: ['russia_inside'], user_domain_list_type: 'text' }, { dns_server: '192.0.2.5' }, feed, true);
check(result.patches.main.future_option == 'value', 'accept future MAIN options');
check(length(result.patches.main.community_lists) == 3, 'append generic UCI lists');
check(result.patches.settings.dns_type == 'doh' && result.patches.settings.dns_server == 'dns.example.com/dns-query', 'explicit DNS settings');
check(result.patches.main.user_domains_text == 'example.com', 'preserve domain merge contract');
let repeated = mergeConfig(result.patches.main, result.patches.settings, feed, true);
check(!length(keys(repeated.patches.main)) && !length(keys(repeated.patches.settings)), 'extended configuration idempotent');
rejects(() => validateConfig({ ...input, settings: { arbitrary_global: 'value' } }), 'reject unrelated global setting');
rejects(() => validateConfig({ ...input, main: { '.type': 'settings' } }), 'reject UCI metadata key');
rejects(() => validateConfig({ ...input, main: { 'valid\ninjected': 'value' } }), 'reject newline in option name');
rejects(() => validateConfig({ ...input, revision: 'good\ninjected' }), 'reject newline in revision');
rejects(() => validateConfig({ ...input, settings: { dns_server: 'example.com\ninjected' } }), 'reject newline in DNS');
rejects(() => validateConfig({ ...input, main: { user_domains: [], user_domains_text: 'example.com' } }), 'reject ambiguous representations');
rejects(() => validateConfig({ ...input, settings: { dns_type: 'invalid' } }), 'reject unknown DNS protocol');
rejects(() => validateConfig({ ...input, settings: { download_lists_via_proxy: true } }), 'UCI flags must be explicit strings');
let deletion = validateConfig({ schema_version: 2, revision: 'delete-1', main: {
	future_option: { value: 'old', delete: true }, community_lists: [{ value: 'telegram', delete: true }]
}, settings: {} });
let deleted = mergeConfig({ future_option: 'old', community_lists: ['telegram', 'google_play'] }, {}, deletion, true);
check(exists(deleted.patches.main, 'future_option') && deleted.patches.main.future_option == null, 'exact scalar delete');
check(join(',', deleted.patches.main.community_lists) == 'google_play', 'generic list delete');
check(!length(keys(mergeConfig({ future_option: 'new' }, {}, deletion, true).patches.main)), 'keep changed scalar on deletion mismatch');
check(!length(keys(mergeConfig({ future_option: 'old' }, {}, deletion, false).patches.main)), 'respect deletion switch for all options');
let example = validateConfig(json(readfile('examples/main.json')));
let demo = mergeConfig({}, {}, example, true);
check(length(demo.patches.main.urltest_proxy_links) == 1, 'synthetic example produces one demonstration proxy');
check(demo.patches.settings.dns_type == 'doh', 'synthetic example settings use supported format');
let ignored = ['main.user_domains', 'settings.dns_server', 'main.future_option'];
let chosen = selectConfig(input, ignored);
let limited = mergeConfig({}, { dns_server: '192.0.2.8' }, chosen, true, ignored);
check(!exists(limited.patches.main, 'user_domains_text') && !exists(limited.patches.settings, 'dns_server'), 'disabled lists and scalar do not apply');
check(!exists(limited.patches.main, 'future_option') && limited.patches.settings.dns_type == 'doh', 'independent fields continue applying');
check(index(configFields(input), 'main.future_option') >= 0, 'discover future fields without values');
let textInput = { schema_version: 2, revision: 'text-1', main: { user_domains_text: 'example.com' }, settings: {} };
check(!length(selectConfig(textInput, ['main.user_domains']).sections.main.lists.user_domains), 'list checkbox covers text alias');
check(configFields(textInput)[0] == 'main.user_domains', 'text alias displayed as one checkbox');
let ignoredDelete = selectConfig({ schema_version: 2, revision: 'delete-2', main: {
	user_domains: [{value: 'example.com', delete: true}] }, settings: {} }, ['main.user_domains']);
let preserved = mergeConfig({ user_domain_list_type: 'text', user_domains_text: 'example.com' }, {}, ignoredDelete, true, ['main.user_domains']);
check(!length(keys(preserved.patches.main)), 'disabled field also skips deletion');
let required = selectConfig(textInput, ['main.user_domain_list_type']);
rejects(() => mergeConfig({user_domain_list_type: 'disabled'}, {}, required, true, ['main.user_domain_list_type']), 'cannot implicitly enable protected list');
check(mergeConfig({user_domain_list_type: 'text'}, {}, required, true, ['main.user_domain_list_type']).patches.main.user_domains_text == 'example.com', 'existing enabled list can be filled without changing its protected type');
rejects(() => selectConfig({...input, settings: {dns_type: 'invalid'}}, ['settings.dns_type']), 'disabled fields still undergo validation');
rejects(() => selectConfig(input, ['settings.dns_server\ninjected']), 'invalid local selector rejected');
let legacy = { schema_version: 1, section: 'main', revision: 'legacy', urltest_proxy_links: [], user_domains: ['example.com'], user_subnets: [] };
check(!length(selectConfig(legacy, ['main.user_domains']).sections.main.lists.user_domains), 'legacy feeds respect local selection');

let splitInput = { schema_version: 3, revision: 'split-1', main: {
	user_domains: ['ordinary.example', { value: 'ai.example', delete: true }],
	community_lists: ['telegram', { value: 'google_ai', delete: true }]
}, notUnderSanctions: {
	connection_type: 'proxy', proxy_config_type: 'urltest', urltest_proxy_links: ['vless://second@example.com:443'],
	user_domains: [{ comment: 'AI services' }, 'ai.example'], community_lists: ['google_ai']
}, settings: {} };
let oldMain = { user_domain_list_type: 'text', user_domains_text: '// My devices\nmanual.example\nai.example', community_lists: ['google_ai'] };
let splitFeed = selectConfig(splitInput, []);
let splitResult = mergeConfig(oldMain, {}, splitFeed, true);
check(splitResult.patches.main.user_domains_text == '// My devices\nmanual.example\nordinary.example', 'move keeps unrelated manual values and comments');
check(splitResult.patches.notUnderSanctions.user_domains_text == '// AI services\nai.example', 'group title reaches Podkop text');
check(join(',', splitResult.patches.notUnderSanctions.community_lists) == 'google_ai', 'second section community lists');
check(join(',', splitResult.order) == 'notUnderSanctions,main', 'schema3 requires regional section priority');
check(index(configFields(splitInput), 'notUnderSanctions.user_domains') >= 0, 'second section checkboxes discovered');
let splitAgain = mergeConfig({ ...oldMain, ...splitResult.patches.main }, {}, splitFeed, true, [], splitResult.patches.notUnderSanctions);
check(!length(keys(splitAgain.patches.main)) && !length(keys(splitAgain.patches.notUnderSanctions)), 'two section merge and comments idempotent');
rejects(() => mergeConfig(oldMain, {}, splitFeed, false), 'cannot partly migrate with deletes disabled');
rejects(() => mergeConfig(oldMain, {}, selectConfig(splitInput, ['notUnderSanctions.user_domains']), true, ['notUnderSanctions.user_domains']), 'cannot delete source while target checkbox is disabled');
rejects(() => mergeConfig(oldMain, {}, selectConfig(splitInput, ['main.user_domains']), true, ['main.user_domains']), 'cannot leave source while migrating target');
let switchedOff = ['main.user_domains', 'notUnderSanctions.user_domains'];
rejects(() => mergeConfig(oldMain, {}, selectConfig(splitInput, switchedOff), true, switchedOff), 'both disabled fields keep migration atomic');
let cleanMain = { user_domain_list_type: 'text', user_domains_text: 'manual.example', community_lists: [] };
check(mergeConfig(cleanMain, {}, splitFeed, false).patches.notUnderSanctions.user_domains_text == '// AI services\nai.example', 'fresh router does not require unrelated deletion permission');
rejects(() => validateConfig({ ...splitInput, anotherSection: {} }), 'unapproved third section rejected');
rejects(() => validateConfig({ ...splitInput, notUnderSanctions: null }), 'schema3 requires explicit second section');
rejects(() => validateConfig({ ...input, main: { user_domains: [{ comment: 'heading' }, 'example.com'] } }), 'old schema does not accept new comment entries');
rejects(() => validateConfig({ ...splitInput, main: { urltest_proxy_links: [{ comment: 'heading' }] } }), 'comments forbidden in proxies');
rejects(() => validateConfig({ ...splitInput, main: { user_domains: [{ comment: 'line\ninjection' }] } }), 'multiline title rejected');
rejects(() => validateConfig({ ...splitInput, main: { user_domains: [{ comment: 'title\u0000hidden' }] } }), 'NUL title rejected explicitly');
rejects(() => validateConfig({ ...splitInput, main: { user_domains: [{ comment: 'heading', value: 'example.com' }] } }), 'ambiguous title entry rejected');
let textAliases = { ...splitInput, main: {}, notUnderSanctions: { user_domains_text: 'ai.example' } };
check(configFields(textAliases)[0] == 'notUnderSanctions.user_domains', 'second section text alias canonical');
check(!length(selectConfig(textAliases, ['notUnderSanctions.user_domains']).sections.notUnderSanctions.lists.user_domains), 'second section text alias filter');
let headers = validateConfig({ ...splitInput, main: {}, notUnderSanctions: {
	user_domains: [{ comment: 'AI' }, 'ai.example', { value: 'remove.example', delete: true }], user_domain_list_type: 'text'
} });
let dynamic = { user_domain_list_type: 'dynamic', user_domains: ['local.example', 'remove.example'], user_domains_text: '// Local\nhidden.example' };
let converted = mergeConfig({}, {}, headers, true, [], dynamic);
check(converted.patches.notUnderSanctions.user_domain_list_type == 'text' &&
	converted.patches.notUnderSanctions.user_domains_text == '// Local\nhidden.example\nlocal.example\n// AI\nai.example', 'explicit dynamic to text preserves active and hidden manual data');
check(join(',', converted.patches.notUnderSanctions.user_domains) == 'local.example', 'conversion removes deleted entry from hidden dynamic representation');
check(converted.counts['notUnderSanctions.user_domains'].removed == 1, 'conversion counts physical removals once');
let noType = selectConfig({ ...splitInput, main: {}, notUnderSanctions: { user_domains: [{ comment: 'AI' }, 'ai.example'] } }, []);
rejects(() => mergeConfig({}, {}, noType, true, [], dynamic), 'comments do not silently convert dynamic lists');
let protectedType = selectConfig({ ...splitInput, main: {}, notUnderSanctions: { user_domains: [{ comment: 'AI' }, 'ai.example'], user_domain_list_type: 'text' } }, ['notUnderSanctions.user_domain_list_type']);
rejects(() => mergeConfig({}, {}, protectedType, true, ['notUnderSanctions.user_domain_list_type'], dynamic), 'disabled type checkbox cannot be bypassed by comment conversion');
let noPool = validateConfig({ ...splitInput, main: {}, notUnderSanctions: { connection_type: 'proxy', proxy_config_type: 'urltest' } });
rejects(() => mergeConfig({}, {}, noPool, true), 'empty second URLTest rejected after scalar settings');
let gone = validateConfig({ ...splitInput, main: {}, notUnderSanctions: { user_domains: [{ comment: 'AI' }, { value: 'ai.example', delete: true }] } });
let cleared = mergeConfig({}, {}, gone, true, [], { user_domain_list_type: 'text', user_domains_text: '// AI\nai.example' });
check(cleared.patches.notUnderSanctions.user_domains_text == '', 'never write comments-only text fields');
let noProxyOptions = ['notUnderSanctions.connection_type', 'notUnderSanctions.proxy_config_type', 'notUnderSanctions.urltest_proxy_links'];
rejects(() => mergeConfig(oldMain, {}, selectConfig(splitInput, noProxyOptions), true, noProxyOptions), 'migration cannot remove source while target proxy options are disabled');
let inactive = { ...splitInput, notUnderSanctions: { ...splitInput.notUnderSanctions, user_domains: ['ai.example'], user_domain_list_type: 'disabled' } };
rejects(() => mergeConfig(oldMain, {}, validateConfig(inactive), true), 'migration cannot move rules into disabled target list');
let standaloneTitle = validateConfig({ ...splitInput, main: {}, notUnderSanctions: { user_domains: [{ comment: 'No values' }] } });
check(!length(keys(mergeConfig({}, {}, standaloneTitle, true).patches.notUnderSanctions)), 'heading without addresses does not create a section');
let spacedTitle = validateConfig({ ...splitInput, main: {}, notUnderSanctions: { user_domains: [{ comment: ' AI  ' }, 'ai.example'] } });
let spacedFirst = mergeConfig({}, {}, spacedTitle, true);
check(!length(keys(mergeConfig({}, {}, spacedTitle, true, [], spacedFirst.patches.notUnderSanctions).patches.notUnderSanctions)), 'title whitespace does not accumulate duplicate headers');
for (let name in ['main', 'notUnderSanctions']) {
	let typeOnly = { schema_version: 3, revision: 'protected-conversion', main: {}, notUnderSanctions: {}, settings: {} };
	typeOnly[name] = { user_domain_list_type: 'text', user_subnet_list_type: 'text' };
	let old = { ...dynamic, user_subnet_list_type: 'dynamic', user_subnets: ['192.0.2.0/24'], user_subnets_text: '198.51.100.0/24' };
	for (let field in ['user_domains', 'user_subnets']) {
		let blocked = [name + '.' + field];
		let filtered = selectConfig(typeOnly, blocked);
		rejectsCode(() => mergeConfig(name == 'main' ? old : {}, {}, filtered, true, blocked, name == 'main' ? {} : old),
			'protected_option_required', 'implicit text alias cannot bypass ' + name + '.' + field);
	}
}
let activeProxy = 'vless://active@example.test:443';
let oldUrl = { connection_type: 'proxy', proxy_config_type: 'url', proxy_string: activeProxy, urltest_proxy_links: ['vless://hidden@example.test:443'] };
let targetPool = { connection_type: 'proxy', proxy_config_type: 'urltest', urltest_proxy_links: ['vless://target@example.test:443'] };
let proxyMove = { schema_version: 3, revision: 'move-active-url', main: { urltest_proxy_links: [{ value: activeProxy, delete: true }] },
	notUnderSanctions: { urltest_proxy_links: [activeProxy] }, settings: {} };
let blockedProxy = ['notUnderSanctions.urltest_proxy_links'];
rejectsCode(() => mergeConfig(oldUrl, {}, selectConfig(proxyMove, blockedProxy), true, blockedProxy, targetPool),
	'section_move_blocked', 'active URL cannot be deleted while target proxy list is disabled');
rejectsCode(() => mergeConfig(oldUrl, {}, selectConfig(proxyMove, []), false, [], targetPool),
	'section_move_blocked', 'active URL move requires deletion permission');
printf('config: %d checks passed\n', passed);
