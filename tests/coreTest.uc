import * as core from 'core';
let passed = 0;
function check(value, title) { if (!value) die(title); passed++; }
function rejects(fn, title) { let failed = false; try { fn(); } catch (e) { failed = true; } check(failed, title); }
function feed(domains, subnets, proxies) {
	return core.validateFeed({ schema_version: 1, section: 'main', revision: 'test-1',
		user_domains: domains || [], user_subnets: subnets || [], urltest_proxy_links: proxies || [] });
}

check(core.normalize('user_subnets', '192.0.2.7/24') == '192.0.2.0/24', 'IPv4 network mask');
check(core.normalize('user_subnets', '2001:db8::1/64') == '2001:db8::/64', 'IPv6 network mask');
check(core.normalize('user_domains', 'EXAMPLE.com.') == 'example.com', 'domain normalization');
rejects(() => feed(['https://example.com']), 'reject URL as domain');
rejects(() => feed([], ['192.0.2.1/33']), 'reject invalid prefix');
rejects(() => feed(['example.com', { value: 'EXAMPLE.com', delete: true }]), 'reject add/delete conflict');
rejects(() => feed([{ value: 'example.com', delete: false }]), 'reject ambiguous delete flag');
rejects(() => feed([], [], ['https://example.com/sub']), 'reject subscription URL');
let section = { user_domain_list_type: 'text', user_domains_text: '// manual\nexample.com\nkeep.test',
	connection_type: 'proxy', proxy_config_type: 'urltest', urltest_proxy_links: ['vless://test@example.com:443'] };
let update = feed(['EXAMPLE.com.', 'new.test', { value: 'keep.test', delete: true }]);
let merged = core.mergeSection(section, update, false);
check(merged.patch.user_domains_text == 'example.com\nkeep.test\nnew.test', 'keep manual entries and ignore delete');
check(merged.counts.user_domains.pending == 1, 'count disabled deletions');
merged = core.mergeSection(section, update, true);
check(merged.patch.user_domains_text == 'example.com\nnew.test', 'apply exact delete');
let repeated = core.mergeSection({ ...section, ...merged.patch }, update, true);
check(length(keys(repeated.patch)) == 0, 'idempotent repeated update');
check(length(keys(core.mergeSection(section, feed(['example.com']), true).patch)) == 0, 'keep unchanged comments');
rejects(() => core.mergeSection(section, feed([], [], [{ value: section.urltest_proxy_links[0], delete: true }]), true), 'retain at least one proxy');
rejects(() => core.mergeSection({ connection_type: 'vpn' }, feed([], [], ['ss://abc@test:443']), true), 'do not convert VPN section');
let first = timelocal({ year: 2026, mon: 10, mday: 31, hour: 12, min: 0, sec: 0, isdst: -1 });
for (let minute = 0; minute <= 30; minute++) {
	let scheduled = localtime(core.nextRun(first, 1, minute));
	check(scheduled.hour == 3 && scheduled.min == minute && scheduled.mday == 1, '03:00..03:30 across month boundary');
}
printf('core: %d checks passed\n', passed);
