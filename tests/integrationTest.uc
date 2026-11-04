import * as fs from 'fs';
import { cursor } from 'uci';
import { applyPatch, writePrivate } from 'transaction';
import { sourceRequest } from 'source';
import { selectConfig, mergeConfig } from 'config';

let passed = 0;
function check(value, label) { if (!value) die(label); passed++; }
function rejects(fn, label) { let failed = false; try { fn(); } catch (e) { failed = true; } check(failed, label); }
let root = ARGV[0];
fs.mkdir(root + '/work');
fs.mkdir(root + '/work/delta');
let paths = { config: root + '/podkop', backup: root + '/previous', work: root + '/work' };
let original = "config settings 'settings'\n option dns_server '192.0.2.1'\nconfig section 'main'\n option connection_type 'proxy'\nconfig section 'other'\n option connection_type 'vpn'\n";
writePrivate(paths.config, original);
let patch = { main: { proxy_config_type: 'urltest', urltest_proxy_links: ['vless://test@example.test:443'], user_domains_text: 'example.test' }, settings: {} };
let restarts = 0;
check(applyPatch(paths, patch, original, () => false, () => { restarts++; return true; }), 'applies transaction');
check(restarts == 1, 'restart only after change');
let config = cursor(root, root + '/work/delta');
check(config.get('podkop', 'settings', 'dns_server') == '192.0.2.1', 'preserve global settings');
check(config.get('podkop', 'other', 'connection_type') == 'vpn', 'preserve other section');
check(config.get('podkop', 'main', 'proxy_config_type') == 'urltest', 'persist target field');
check(fs.readfile(paths.backup) == original, 'exact backup');
let current = fs.readfile(paths.config);
check(!applyPatch(paths, { main: {}, settings: {} }, current, () => false, () => { die('unexpected restart'); }), 'no restart on empty patch');
rejects(() => applyPatch(paths, patch, current, () => true, () => true), 'reject pending edits');
check(fs.readfile(paths.config) == current, 'pending edit preserves configuration');
writePrivate(paths.config, original);
restarts = 0;
rejects(() => applyPatch(paths, patch, original, () => false, () => { restarts++; return restarts == 2; }), 'failed restart triggers rollback');
check(restarts == 2 && fs.readfile(paths.config) == original, 'rollback restores exact file');
let checks = 0;
rejects(() => applyPatch(paths, patch, original, () => {
	if (++checks == 2) writePrivate(paths.config, original + '# concurrent edit\n');
	return false;
}, () => true), 'reject concurrent edit');
check(index(fs.readfile(paths.config), 'concurrent edit') >= 0, 'keep concurrent edit');
writePrivate(paths.config, original);
let paired = { main: { user_domains_text: 'ordinary.example' }, settings: {}, notUnderSanctions: {
	connection_type: 'proxy', proxy_config_type: 'urltest', urltest_proxy_links: ['vless://regional@example.test:443'],
	user_domains_text: '// AI\nai.example', user_domain_list_type: 'text'
} };
restarts = 0;
check(applyPatch(paths, paired, original, () => false, () => { restarts++; return true; }, ['notUnderSanctions', 'main']), 'two sections apply atomically');
check(restarts == 1, 'two sections require one restart');
let pairedText = fs.readfile(paths.config);
let pairedCursor = cursor(root, root + '/work/delta');
let names = [];
pairedCursor.foreach('podkop', null, section => { push(names, section['.name']); });
check(join(',', names) == 'settings,notUnderSanctions,main,other', 'regional section before main preserves other section order');
check(pairedCursor.get('podkop', 'notUnderSanctions', 'user_domains_text') == '// AI\nai.example', 'UCI stores multiline comments literally');
check(!applyPatch(paths, { main: {}, notUnderSanctions: {}, settings: {} }, pairedText, () => false, () => { die('unexpected restart'); }, ['notUnderSanctions', 'main']), 'ordered repeat does not restart');
writePrivate(paths.config, original);
restarts = 0;
rejects(() => applyPatch(paths, paired, original, () => false, () => { restarts++; return restarts == 2; }, ['notUnderSanctions', 'main']), 'two section restart failure rolls back');
check(fs.readfile(paths.config) == original && restarts == 2, 'two section rollback restores original sections and order');
let collided = original + "config settings 'notUnderSanctions'\n option existing 'keep'\n";
writePrivate(paths.config, collided);
rejects(() => applyPatch(paths, paired, collided, () => false, () => true, ['notUnderSanctions', 'main']), 'reject existing name with another UCI type');
check(fs.readfile(paths.config) == collided, 'section name collision does not change router config');

let nativeOriginal = "config settings 'settings'\n option config_version '2'\n option dns_server '192.0.2.1'\nconfig source 'old_source'\n option type 'subscription'\n option url 'https://old.example/sub'\nconfig section 'main'\nconfig member 'old_main'\n option section 'main'\n option role 'server'\n option source 'old_source'\nconfig section 'other'\nconfig member 'other_member'\n option section 'other'\n option role 'server'\n option source 'old_source'\n";
let nativeInput = { schema_version: 4, revision: 'native-integration', main: { user_domain_list_type: 'text', user_domains: ['ordinary.example'] },
	notUnderSanctions: { user_domain_list_type: 'text', user_domains: [{ comment: 'AI' }, 'ai.example'] },
	settings: { download_lists_via_proxy: '1', download_lists_via_proxy_section: 'main', urltest_testing_url: 'https://check.example/204' },
	sources: { provider: { type: 'subscription', url: 'https://provider.example/sub', update_interval: '1d' } },
	members: { main_provider: { section: 'main', source: 'provider', role: 'server', exclude: ['ОБХОД'] },
		nas_provider: { section: 'notUnderSanctions', source: 'provider', role: 'server', include: ['Germany'], exclude: ['ОБХОД'] } },
	replace_members: ['main', 'notUnderSanctions'] };
function nativeMerge() {
	let stored = cursor(root, root + '/work/delta'), current = {};
	stored.foreach('podkop', null, item => { current[item['.name']] = item; });
	return mergeConfig(current.main || {}, current.settings || {}, selectConfig(nativeInput, []), true, [], current.notUnderSanctions || {}, current);
}
writePrivate(paths.config, nativeOriginal);
let nativeMerged = nativeMerge();
restarts = 0;
check(applyPatch(paths, nativeMerged.patches, nativeOriginal, () => false, () => { restarts++; return true; }, nativeMerged.order, nativeMerged.native), 'native sources and members apply atomically');
let nativeCursor = cursor(root, root + '/work/delta');
check(nativeCursor.get('podkop', 'provider') == 'source' && nativeCursor.get('podkop', 'main_provider') == 'member', 'transaction writes correct native UCI types');
check(nativeCursor.get('podkop', 'main_provider', 'source') == 'provider' && !nativeCursor.get('podkop', 'old_main'), 'transaction replaces only declared old membership');
check(nativeCursor.get('podkop', 'old_source') == 'source' && nativeCursor.get('podkop', 'other_member') == 'member', 'native transaction preserves unrelated source and membership');
check(nativeCursor.get('podkop', 'settings', 'download_lists_via_proxy_section') == 'main' && !nativeCursor.get('podkop', 'main', 'connection_type'), 'native list download validates source membership without obsolete connection type');
check(restarts == 1 && fs.readfile(paths.backup) == nativeOriginal, 'native transaction uses one restart and exact rollback source');
let nativeText = fs.readfile(paths.config);
let nativeRepeat = nativeMerge();
check(!applyPatch(paths, nativeRepeat.patches, nativeText, () => false, () => { die('unexpected native restart'); }, nativeRepeat.order, nativeRepeat.native), 'native transaction repeat does not restart');
writePrivate(paths.config, nativeOriginal);
restarts = 0;
rejects(() => applyPatch(paths, nativeMerged.patches, nativeOriginal, () => false, () => { restarts++; return restarts == 2; }, nativeMerged.order, nativeMerged.native), 'native restart failure triggers rollback');
check(restarts == 2 && fs.readfile(paths.config) == nativeOriginal, 'native rollback restores source/member rows exactly');
writePrivate(paths.config, original);
rejects(() => applyPatch(paths, nativeMerged.patches, original, () => false, () => true, nativeMerged.order, nativeMerged.native), 'native transaction refuses stable or old configuration');
check(fs.readfile(paths.config) == original, 'native version refusal does not write configuration');
let nativeCollision = nativeOriginal + "config section 'provider'\n option manual 'keep'\n";
writePrivate(paths.config, nativeCollision);
rejects(() => applyPatch(paths, nativeMerged.patches, nativeCollision, () => false, () => true, nativeMerged.order, nativeMerged.native), 'native transaction refuses source name collision');
check(fs.readfile(paths.config) == nativeCollision, 'native type collision leaves config unchanged');
let request = sourceRequest('https://github.com/example/config/blob/main/config/main.json', 'test_token');
check(request.url == 'https://api.github.com/repos/example/config/contents/config/main.json?ref=main', 'convert GitHub file link');
check(index(request.headers, 'Bearer test_token') >= 0, 'GitHub authorization header');
rejects(() => sourceRequest('https://example.test/config.json', 'test_token'), 'never send GitHub token to custom host');
rejects(() => sourceRequest('https://api.github.com.evil.test/config.json', 'test_token'), 'reject lookalike host token transfer');
rejects(() => sourceRequest('http://example.test/config.json', ''), 'require HTTPS');
rejects(() => sourceRequest('https://github.com/example/config/blob/main/config/main.json', 'bad\nInjected: true'), 'reject header injection');
for (let file in fs.glob(root + '/work/delta/*')) fs.unlink(file);
fs.rmdir(root + '/work/delta');
for (let file in fs.glob(root + '/work/*')) fs.unlink(file);
fs.rmdir(root + '/work');
for (let file in fs.glob(root + '/*')) fs.unlink(file);
fs.rmdir(root);
printf('integration: %d checks passed\n', passed);
