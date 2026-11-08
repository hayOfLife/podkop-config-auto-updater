import { escapeURI } from 'providers';
import { buildBrowsec } from 'browsec';
import { buildSubix } from 'subix';
import { subscriptionPatches } from 'subscriptions';

let passed = 0;
function check(value, title) { if (!value) die(title); passed++; }
function rejects(fn, title) { let failed = false; try { fn(); } catch (error) { failed = true; } check(failed, title); }

let oldUuid = '00000000-0000-4000-8000-000000000001';
let newUuid = '00000000-0000-4000-8000-000000000002';
let seed = 'vless://' + oldUuid + '@192.0.2.1:63821?encryption=none&security=reality&type=tcp' +
	'&flow=xtls-rprx-vision&fp=firefox&pbk=TEST_KEY&sid=0123456789abcdef&sni=example.com#Browsec';
let group = { ip: [], xsni: [] };
for (let i = 1; i <= 24; i++) { push(group.ip, '192.0.2.' + i); push(group.xsni, 'edge' + i + '.example.com'); }
let feed = { countries: { de: { premium_servers: [group] } } };
check(escapeURI('Германия') == '%D0%93%D0%B5%D1%80%D0%BC%D0%B0%D0%BD%D0%B8%D1%8F', 'encode UTF-8 as URI bytes');
let updated = buildBrowsec(feed, [seed], [seed], newUuid);
check(updated.count == 24 && length(updated.first) == 12 && length(updated.second) == 12, 'split Browsec nodes');
check(index(updated.first[0], newUuid) >= 0 && index(updated.first[0], oldUuid) < 0, 'rotate account UUID');
check(length(filter([...updated.first, ...updated.second], link =>
	index(link, '@192.0.2.1:') >= 0 && index(link, 'sni=edge1.example.com') >= 0)) == 1, 'pair server and SNI');
rejects(() => buildBrowsec({ countries: {} }, [seed], [seed], newUuid), 'retain previous links on empty feed');
rejects(() => buildBrowsec({ countries: { de: { premium_servers: [{ ip: ['192.0.2.1'], xsni: [] }] } } }, [seed], [seed]), 'reject mismatched SNI');
rejects(() => buildBrowsec(feed, [seed], [replace(seed, oldUuid, newUuid)]), 'reject mixed account sources');

function outbound(index) {
	return { protocol: 'vless', settings: { vnext: [{ address: '192.0.2.' + index, port: 443,
		users: [{ id: oldUuid, encryption: 'none', flow: 'xtls-rprx-vision' }] }] },
		streamSettings: { network: 'tcp', security: 'reality', realitySettings: { serverName: 'edge.example.com', publicKey: 'TEST_KEY' } } };
}
let subix = [
	{ remarks: 'ГЕРМАНИЯ', outbounds: [outbound(1)] },
	{ remarks: 'ОБхОд LTE', outbounds: [outbound(2)] },
	{ remarks: 'AUTO', outbounds: [outbound(3), outbound(4)] },
	{ remarks: 'НЕДОСТУПНЫЙ', outbounds: [{ ...outbound(5), mux: { enabled: true } }] },
	{ remarks: 'WS REALITY', outbounds: [{ ...outbound(6), streamSettings: { network: 'ws', security: 'reality' } }] },
	{ remarks: 'FRAGMENT', outbounds: [{ ...outbound(7), streamSettings: { ...outbound(7).streamSettings, finalmask: { tcp: [] } } }] },
	{ remarks: 'UNKNOWN', outbounds: [{ ...outbound(8), streamSettings: { ...outbound(8).streamSettings, unrecognized: true } }] }
];
let converted = buildSubix(subix);
check(length(converted.links) == 3 && converted.excluded == 1 && converted.skipped == 4, 'exclude blocked nodes and report unsupported nodes');
check(index(converted.links[0], 'security=reality') >= 0 && index(converted.links[0], 'sni=edge.example.com') >= 0, 'preserve reality parameters');
rejects(() => buildSubix([{ remarks: 'ОБХОД', outbounds: [outbound(1)] }]), 'reject empty usable subscription');

let current = {
	src4: { '.type': 'source', type: 'links', label: 'Browsec Premium · 1', link: [seed] },
	src5: { '.type': 'source', type: 'links', label: 'Browsec Premium · 2', link: [seed] },
	m1: { '.type': 'member', source: 'src4', section: 'main' },
	n1: { '.type': 'member', source: 'src4', section: 'notUnderSanctions' },
	m2: { '.type': 'member', source: 'src5', section: 'main' },
	n2: { '.type': 'member', source: 'src5', section: 'notUnderSanctions' }
};
let browsec = subscriptionPatches(current, { '.name': 'cfg001', provider: 'browsec' }, feed, newUuid, true);
check(length(keys(browsec.patches)) == 2 && join(',', sort(browsec.native.member_names)) == 'm1,m2,n1,n2', 'reuse existing sources and retain memberships');
let fresh = subscriptionPatches({}, { '.name': 'cfg002', provider: 'subix' }, subix, null, true);
check(fresh.count == 3 && fresh.native.types.pca_cfg002_s1 == 'source', 'create source for Subix');
check(fresh.patches.pca_cfg002_n1.section == 'notUnderSanctions' && length(fresh.patches.pca_cfg002_n1.include) > 0, 'create positive country filter');
check(index(fresh.patches.pca_cfg002_n1.exclude, 'AUTO') >= 0 && index(fresh.patches.pca_cfg002_m1.exclude, 'LTE') >= 0, 'exclude unknown and limited nodes');
let existingSubix = { pca_cfg002_s1: { '.type': 'source', type: 'links', link: fresh.patches.pca_cfg002_s1.link },
	user_main: { '.type': 'member', source: 'pca_cfg002_s1', section: 'main', exclude: ['custom'] } };
let preserved = subscriptionPatches(existingSubix, { '.name': 'cfg002', provider: 'subix' }, subix, null, true);
check(!preserved.patches.pca_cfg002_n1 && !preserved.patches.user_main &&
	join(',', preserved.native.member_names) == 'user_main', 'preserve changed or removed memberships');
rejects(() => subscriptionPatches({ pca_cfg002_s1: { '.type': 'settings' } }, { '.name': 'cfg002', provider: 'subix' }, subix), 'avoid UCI section collisions');
printf('subscriptions: %d checks passed\n', passed);
