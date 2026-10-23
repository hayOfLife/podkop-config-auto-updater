import { parseConfig, validateConfig, selectConfig, configFields, mergeConfig } from 'config';
import { readfile } from 'fs';
let passed = 0;
function check(value, label) { if (!value) die(label); passed++; }
function rejects(fn, label) { let failed = false; try { fn(); } catch (e) { failed = true; } check(failed, label); }
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
check(!length(selectConfig(textInput, ['main.user_domains']).lists.user_domains), 'list checkbox covers text alias');
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
check(!length(selectConfig(legacy, ['main.user_domains']).lists.user_domains), 'legacy feeds respect local selection');
printf('config: %d checks passed\n', passed);
