import { validateConfig, mergeConfig } from 'config';
let passed = 0;
function check(value, label) { if (!value) die(label); passed++; }
function rejects(fn, label) { let failed = false; try { fn(); } catch (e) { failed = true; } check(failed, label); }
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
printf('config: %d checks passed\n', passed);
