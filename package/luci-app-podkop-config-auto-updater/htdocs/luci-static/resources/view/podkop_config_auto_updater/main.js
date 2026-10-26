'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';
'require uci';

var runner = '/usr/libexec/podkop-config-auto-updater/run';
var softwareRunner = '/usr/libexec/podkop-config-auto-updater/software';
var errors = {
	missing_token: 'Укажите токен GitHub с правом чтения содержимого репозитория.',
	invalid_token: 'Проверьте токен GitHub: в нём не должно быть пробелов или переносов строк.',
	invalid_source: 'Проверьте HTTPS-ссылку на файл конфигурации.',
	invalid_github_url: 'Скопируйте ссылку на файл из GitHub. Пример есть в инструкции под полем токена.',
	token_host_mismatch: 'Для ссылки на личный сервер очистите поле токена GitHub.',
	download_failed: 'Файл не загружен. Проверьте ссылку, срок действия токена и доступ к репозиторию.',
	download_proxy_dns_failed: 'Не удалось определить IP-адрес прокси для загрузки. Проверьте его адрес и DNS роутера.',
	download_dns_failed: 'Не удалось определить IP-адрес сервера конфига. Проверьте DNS роутера.',
	download_connect_failed: 'Не удалось установить соединение с сервером конфига. Проверьте маршрут и доступность сервера.',
	download_timeout: 'Истёк срок ожидания соединения или загрузки конфига. Повторите тест позднее.',
	download_tls_failed: 'Не удалось установить защищённое TLS-соединение с сервером конфига.',
	download_certificate_failed: 'Сертификат HTTPS-сервера не прошёл проверку. Проверьте дату роутера и сертификат сервера.',
	download_ca_failed: 'Не удалось прочитать доверенные сертификаты на роутере. Проверьте пакет ca-bundle.',
	download_too_large: 'Размер файла превышает допустимый предел 1 МиБ.',
	download_http_unauthorized: 'Сервер отклонил авторизацию (HTTP 401). Проверьте правильность и срок действия токена GitHub.',
	download_http_forbidden: 'Сервер запретил доступ (HTTP 403). Проверьте права токена и ограничения GitHub API.',
	download_http_not_found: 'Файл не найден или недоступен (HTTP 404). Проверьте путь и ветку. Для приватного GitHub такой ответ также означает отсутствие доступа у токена.',
	download_http_rate_limited: 'Слишком много запросов (HTTP 429). Повторите тест позднее.',
	download_http_server_error: 'Сервер конфига вернул ошибку HTTP 5xx. Повторите тест позднее.',
	download_http_redirect: 'Ссылка возвращает перенаправление. Укажите прямой HTTPS-адрес файла или ссылку GitHub вида /blob/ветка/файл.',
	download_http_error: 'Сервер вернул неожиданный HTTP-ответ вместо файла конфига. Проверьте ссылку.',
	invalid_json: 'Файл скачан, но содержит некорректный JSON или незакрытый комментарий.',
	invalid_comment: 'В заголовке группы доменов или подсетей есть недопустимые символы. Исправьте комментарий в файле конфига.',
	comments_require_text: 'Для заголовков групп выберите текстовый тип списка доменов или подсетей в Podkop и разрешите применение этого параметра.',
	section_move_blocked: 'Перенос между main и notUnderSanctions заблокирован локальными настройками. Разрешите применение участвующих списков и автоматические удаления, затем повторите обновление.',
	invalid_size: 'Скачанный файл пуст или превышает допустимый размер 1 МиБ.',
	invalid_ignored_options: 'Повреждён локальный список параметров, запрещённых к применению. Пересохраните галочки применения настроек.',
	protected_option_required: 'Для применения списка требуется изменить защищённый тип списка или подключения. Разрешите применение соответствующего параметра либо заранее настройте его в Podkop.',
	runtime_incompatible: 'Обработчик теста не запустился: ошибка компиляции ucode. Обновите Podkop config auto updater до совместимой версии.',
	worker_failed: 'Обработчик теста завершился без результата. Выполните в SSH: /usr/libexec/podkop-config-auto-updater/run test.',
	rpc_access_denied: 'LuCI отказал в запуске теста. Выйдите из LuCI и войдите снова, чтобы обновить права сессии.',
	rpc_timeout: 'LuCI не дождался результата теста. Проверьте источник командой в SSH: /usr/libexec/podkop-config-auto-updater/run test.',
	rpc_unavailable: 'Не удалось связаться с обработчиком LuCI. Обновите страницу и повторите тест.',
	pending_changes: 'В Podkop есть несохранённые изменения. Сохраните или отмените их и повторите обновление.',
	concurrent_change: 'Настройки Podkop изменились во время обновления. Повторите обновление.',
	empty_proxy_pool: 'Секция main или notUnderSanctions осталась бы без серверов URLTest. Настройки сохранены без изменений.',
	incompatible_section: 'Одна из секций main или notUnderSanctions использует другой тип подключения. Выберите для неё в Podkop Proxy и URLTest.',
	podkop_missing: 'Сначала установите и настройте Podkop.',
	restart_failed_restored: 'Podkop не принял изменения. Предыдущая конфигурация восстановлена.',
	restart_failed_manual_recovery: 'Podkop не запустился, а конфигурация уже изменена вручную. Нужна проверка администратора.',
	rollback_restart_failed: 'Конфигурация восстановлена, но Podkop не запустился. Нужна проверка администратора.',
	clock_not_ready: 'Проверьте дату и время роутера.',
	busy: 'Уже выполняется другая операция. Дождитесь её окончания.',
	update_interrupted: 'Обновление конфига прервалось. Применение не подтверждено; проверьте настройки Podkop перед повторным запуском.',
	unsupported_platform: 'Обновление поддерживается на OpenWrt 24.10 и 25.12.',
	podkop_package_missing: 'Не найден установленный пакет Podkop или Podkop Experimental. Сначала установите нужную ветку Podkop.',
	podkop_variant_conflict: 'Одновременно установлены podkop и podkop-exp. Устраните конфликт пакетов вручную; программа не меняет ветку и не удаляет пакеты автоматически.',
	unsupported_architecture: 'Не удалось определить подходящую архитектуру пакета Podkop Experimental. Установка не запускалась.',
	podkop_migration_required: 'Для Podkop версии ниже 0.7.0 требуется отдельная миграция настроек. Используйте официальную инструкцию Podkop.',
	invalid_release: 'Не удалось прочитать сведения об официальном релизе.',
	missing_package: 'В релизе нет подходящего пакета для этой версии OpenWrt и архитектуры роутера.',
	invalid_package: 'Не удалось подтвердить адрес или контрольную сумму пакета.',
	checksum_mismatch: 'Контрольная сумма скачанного пакета не совпала. Установка не запускалась.',
	backup_failed: 'Не удалось сохранить резервную копию настроек. Установка не запускалась.',
	package_index_failed: 'Не удалось обновить список доступных пакетов OpenWrt. Установка не запускалась.',
	package_compare_failed: 'Не удалось сравнить версии пакетов. Установка не запускалась.',
	package_install_failed: 'Пакетный менеджер сообщил об ошибке. Проверьте состояние пакетов на роутере; резервная копия настроек сохранена.',
	installed_version_mismatch: 'Установленная версия отличается от ожидаемой. Проверьте состояние пакетов на роутере.',
	interrupted: 'Обновление прервалось. Проверьте установленные версии перед повторной попыткой.'
};

function showTestResult(result, successful) {
	var content = [E('p', {}, successful ? 'Тест соединения пройден.' : 'Тест соединения не пройден.')];
	if (typeof result.downloaded === 'boolean') {
		content.push(E('p', {}, 'Файл скачан: ' + (result.downloaded ? 'да.' : 'нет.')));
		content.push(E('p', {}, 'JSON разобран: ' + (result.parsed ? 'да.' : (result.downloaded ? 'нет.' : 'не проверялся.'))));
		content.push(E('p', {}, 'Формат конфига: ' + (result.valid ? 'подходит.' : (result.parsed ? 'не подходит.' : 'не проверялся.'))));
	}
	if (!successful)
		content.push(E('p', {}, errors[result.error] || (result.parsed ?
			'Проверьте файл по инструкции о формате конфига.' : 'Не удалось выполнить тест. Проверьте доступ к роутеру и повторите попытку.')));
	content.push(E('p', {}, 'Настройки Podkop не изменялись.'));
	if (successful) content.push(E('p', {}, 'Список параметров конфига прочитан. Обновите страницу, чтобы увидеть галочки для новых параметров.'));
	content.push(E('div', {class: 'right'}, E('button', {class: 'cbi-button', type: 'button', click: ui.hideModal}, 'Закрыть')));
	ui.showModal('Тест соединения', content);
}

function readStatus() {
	return fs.exec(runner, ['status']).then(function(result) {
		var status = JSON.parse(result.stdout || 'null');
		if (result.code || !status || typeof status !== 'object' || Array.isArray(status)) throw new Error('status_unavailable');
		return status;
	});
}

function readSoftwareStatus() {
	return fs.exec(softwareRunner, ['status']).then(function(result) {
		try { return JSON.parse(result.stdout || '{}') || {}; }
		catch (error) { return {state: 'unavailable'}; }
	}).catch(function() { return {state: 'unavailable'}; });
}

function softwareText(status) {
	var name = 'Podkop config auto updater';
	if (status.target === 'podkop') name = status.variant === 'experimental' ? 'Podkop Experimental' : 'Podkop';
	var versions = status.installed_version && status.available_version ?
		' Установлена: ' + status.installed_version + '; доступна: ' + status.available_version + '.' : '';
	var stages = {checking: 'проверка версии', downloading: 'скачивание пакетов', index: 'подготовка установки', installing: 'установка пакетов'};
	if (status.state === 'running') return name + ': ' + (stages[status.stage] || 'обновление выполняется') + '.';
	if (status.state === 'updated') return name + ' обновлён.' + (status.config_changed ? ' Установщик изменил настройки; проверьте их. Резервная копия сохранена.' : '');
	if (status.state === 'up_to_date') return name + ': обновлений нет.' + versions;
	if (status.state === 'error') return errors[status.error] || 'Обновить программу не удалось. Проверьте состояние пакетов на роутере.';
	if (status.state === 'unavailable') return 'Связь с роутером временно недоступна. Проверка результата продолжится.';
	return 'Обновление программ ещё не запускалось.';
}

function showSoftwareResult(status) {
	ui.showModal('Обновление программы', [E('p', {class: status.state === 'running' ? 'spinning' : ''}, softwareText(status)),
		E('p', {}, status.state === 'running' ? 'Окно можно закрыть: обновление продолжится в фоне.' :
			(status.state === 'updated' && status.target === 'self' ? 'Обновите страницу браузера, чтобы загрузить новый интерфейс.' : '')),
		E('div', {class: 'right'}, E('button', {class: 'cbi-button', type: 'button', click: ui.hideModal}, 'Закрыть'))]);
}

function statusText(status) {
	var text = '';
	if (status.state === 'running') {
		var stages = {starting: 'запуск', downloading: 'скачивание и проверка файла',
			preparing: 'подготовка настроек', restarting: 'перезапуск Podkop'};
		return 'Обновление выполняется: ' + (stages[status.stage] || 'ожидание завершения') +
			'. Итог ещё не получен. Страницу можно закрыть; операция продолжится на роутере.';
	}
	if (status.next_run && status.enabled)
		text += ' Следующее обновление: ' + new Date(status.next_run * 1000).toLocaleString() + ' (время вашего браузера).';
	if (status.state === 'applied') text += ' Последние изменения применены.';
	if (status.state === 'unchanged') text += ' Последняя проверка: новых изменений нет.';
	if (status.state === 'error') text += ' ' + (errors[status.error] || 'Файл конфигурации не принят. Проверьте его по инструкции о формате файла.');
	if (status.ipv6_error) text += ' Не удалось применить настройку IPv6. Проверьте системный журнал роутера.';
	if (status.revision) text += ' Версия: ' + status.revision + '.';
	if (status.counts) {
		var added = 0, removed = 0, pending = 0;
		Object.keys(status.counts).forEach(function(key) {
			added += status.counts[key].added;
			removed += status.counts[key].removed;
			pending += status.counts[key].pending;
		});
		text += ' Добавлено: ' + added + ', удалено: ' + removed + ', удалений пропущено: ' + pending + '.';
	}
	if ((status.state === 'applied' || status.state === 'unchanged') && Number.isFinite(status.time) && status.time > 0)
		text += '\nОбновление произошло: ' + new Date(status.time * 1000).toLocaleString('ru-RU') + ' (время вашего браузера).';
	return text;
}

function healthText(status) {
	var health = status.health || {};
	var disabled = status.enabled === false ? 'Контроль OpenAI выключен вместе с программой.' :
		status.openai_check_enabled === false ? 'Контроль OpenAI выключен.' : '';
	if (disabled && health.state !== 'error') return disabled;
	var messages = {
		healthy: 'Запрос OpenAI дошёл до проверки авторизации через выбранный узел.',
		checking: 'Проверяется соединение с OpenAI через notUnderSanctions.',
		region_blocked: 'OpenAI отклонил запрос из-за региона выбранного узла.',
		network_error: 'Сетевая ошибка при проверке OpenAI. Проверка будет повторена.',
		rate_limited: 'OpenAI ограничил частоту запросов (HTTP 429). Проверки отложены.',
		service_error: 'OpenAI вернул ошибку сервиса. Проверка будет повторена.',
		unknown: 'Получен неожиданный ответ OpenAI; доступность не подтверждена.',
		route_unconfirmed: 'Маршрут проверки не подтверждён. Другой узел по результату запроса не выбирается.',
		not_configured: 'Секция notUnderSanctions ещё не настроена для контроля OpenAI.',
		disabled: 'Выключен.',
		error: 'Не удалось выполнить контроль OpenAI. Проверьте настройки Podkop.',
		no_eligible_nodes: 'Не найден узел, подходящий для контроля OpenAI.',
		switched: 'Для notUnderSanctions выбран другой узел.',
		selection_changed: 'Выбранный узел изменён вне программы. Контроль возобновится позже.'
	};
	var details = {
		api_unavailable: 'Не удалось связаться с API Podkop.',
		invalid_runtime: 'Текущая конфигурация Podkop не подходит для контроля OpenAI.',
		selection_failed: 'Podkop не подтвердил переключение узла.',
		io_failed: 'Не удалось обработать временные данные контроля OpenAI.'
	};
	var text = disabled ? disabled + ' Не удалось завершить последнее действие контроля. Возврат прежнего выбора не подтверждён.' :
		'Контроль OpenAI: ' + (Object.prototype.hasOwnProperty.call(messages, health.state) ? messages[health.state] : 'Проверка ещё не выполнялась.');
	if (health.state === 'error' && Object.prototype.hasOwnProperty.call(details, health.error)) text += ' ' + details[health.error];
	if (typeof health.selected === 'string' && /^notUnderSanctions-[0-9]+-out$/.test(health.selected))
		text += ' Узел: ' + health.selected + '.';
	if (Number.isFinite(health.checked_at) && health.checked_at > 0)
		text += '\nПоследняя проверка: ' + new Date(health.checked_at * 1000).toLocaleString('ru-RU') + ' (время вашего браузера).';
	if (Number.isFinite(health.next_check) && health.next_check > 0)
		text += (disabled ? '\nСледующая попытка: ' : '\nСледующая проверка: ') + new Date(health.next_check * 1000).toLocaleString('ru-RU') + ' (время вашего браузера).';
	return text;
}

return view.extend({
	load: function() {
		return Promise.all([readStatus(), readSoftwareStatus(), uci.load('podkop_config_auto_updater')]).then(function(results) {
			results[0].software = results[1];
			return results[0];
		});
	},
	render: function(status) {
		var map = new form.Map('podkop_config_auto_updater', 'Podkop config auto updater',
			'Обновляет секции main, notUnderSanctions и указанные в файле общие настройки Podkop. ' +
			'В main используется общий пул серверов, в notUnderSanctions — серверы, отобранные для сервисов с региональными ограничениями. ' +
			'URLTest проверяет соединение по своему адресу; доступность всех этих сервисов он не проверяет.');
		var section = map.section(form.NamedSection, 'main', 'settings');
		section.addremove = false;
		var option = section.option(form.Flag, 'enabled', 'Работать');
		option.default = '1';
		option.rmempty = false;
		var enabledNode;
		function refreshEnabled(current) {
			if (!enabledNode) return;
			enabledNode.textContent = current.enabled ? 'Программа "Podkop config auto updater" работает' : 'Программа "Podkop config auto updater" выключена';
			enabledNode.style.color = current.enabled ? '#22863a' : '#b94a48';
		}
		option.description = '<span id="podkop-updater-enabled" role="status"></span>';
		option = section.option(form.ListValue, 'interval_days', 'Обновлять раз в:');
		option.value('1', 'День');
		option.value('3', '3 дня');
		option.value('7', 'Неделю');
		option.value('30', '30 дней');
		option.default = '1';
		option.rmempty = false;
		option.description = 'В случайную минуту от 03:00 до 03:30 по времени роутера. Для каждого запуска минута выбирается заново.';
		option = section.option(form.Flag, 'allow_deletes', 'Автоматически применять пришедшие настройки удаления конфига');
		option.default = '1';
		option.rmempty = false;
		option.description = 'Удаляются только записи с пометкой delete. Остальные существующие записи сохраняются.';
		option = section.option(form.Flag, 'openai_check_enabled', 'Контролировать доступ к OpenAI');
		option.default = '1';
		option.rmempty = false;
		option.description = 'При включённой программе проверяет OpenAI раз в 3 минуты без API-ключа и управляет выбором узла только в notUnderSanctions. ' +
			'Сетевые ошибки перепроверяются; при ограничении частоты запросов делается пауза. ' +
			'В этой секции контроллер выбирает узел вместо URLTest. Доступность Claude, Gemini и других сервисов проверка не подтверждает.';
		option = section.option(form.Flag, 'disable_ipv6', 'Выключить ip v6');
		option.default = '0';
		option.rmempty = false;
		option.description = 'Отключает IPv6 на роутере после сохранения. При снятии галочки возвращает прежнее состояние. Не зависит от галочки «Работать».';
		option = section.option(form.Value, 'config_url', 'Ссылка на файл конфига');
		option.placeholder = 'https://github.com/OWNER/REPO/blob/main/config/main.json';
		option.rmempty = false;
		option.validate = function(sectionId, value) {
			return !value || /^https:\/\/[^\s]+$/.test(value) ? true : 'Укажите полную HTTPS-ссылку.';
		};
		option = section.option(form.Value, 'github_token', 'Токен GitHub');
		option.password = true;
		option.rmempty = false;
		option.description = 'Для закрытого репозитория нужен токен с правом Contents: Read-only. ' +
			'<a href="https://github.com/hayOfLife/podkop-config-auto-updater/blob/main/docs/github-setup.ru.md" target="_blank" rel="noopener noreferrer">Как создать закрытый репозиторий и получить токен</a>';

		var labels = {
			'main.urltest_proxy_links': 'Ссылки прокси для URLTest',
			'main.user_domains': 'Список пользовательских доменов',
			'main.user_subnets': 'Список пользовательских подсетей',
			'main.connection_type': 'Тип подключения',
			'main.proxy_config_type': 'Тип конфигурации прокси',
			'main.enable_udp_over_tcp': 'UDP через TCP',
			'main.urltest_check_interval': 'Интервал проверки URLTest',
			'main.urltest_tolerance': 'Допуск URLTest',
			'main.urltest_testing_url': 'URLTest ссылка для проверки',
			'main.urltest_download_check': 'Проверка загрузки URLTest',
			'main.user_domain_list_type': 'Тип списка пользовательских доменов',
			'main.user_subnet_list_type': 'Тип списка пользовательских подсетей',
			'main.resolve_real_ip_for_routing': 'Определять реальный IP для маршрутизации',
			'main.community_lists': 'Списки сообщества',
			'main.remote_domain_lists': 'Удалённые списки доменов',
			'main.remote_subnet_lists': 'Удалённые списки подсетей',
			'settings.dns_type': 'Тип протокола DNS',
			'settings.dns_server': 'DNS-сервер',
			'settings.bootstrap_dns_server': 'Bootstrap DNS-сервер',
			'settings.download_lists_via_proxy': 'Скачивать списки через Proxy/VPN',
			'settings.update_interval': 'Частота обновления списков',
			'settings.download_lists_via_proxy_section': 'Скачивать списки через выбранную секцию'
		};
		Object.keys(labels).filter(function(field) { return field.indexOf('main.') === 0; }).forEach(function(field) {
			labels[field.replace(/^main\./, 'notUnderSanctions.')] = labels[field];
		});
		function canonicalField(field) {
			return typeof field === 'string' ? field.replace(/^(main|notUnderSanctions)\.(user_domains|user_subnets)_text$/, '$1.$2') : field;
		}
		function ignoredOptions(sectionId) {
			var value = uci.get('podkop_config_auto_updater', sectionId, 'ignored_options');
			return (Array.isArray(value) ? value.slice() : (value ? [value] : [])).map(canonicalField);
		}
		var discovered = Array.isArray(status.fields) ? status.fields : [];
		var fields = Array.from(new Set(Object.keys(labels).concat(discovered, ignoredOptions('main')).map(canonicalField)))
			.filter(function(field) { return /^(main|notUnderSanctions|settings)\.[a-z][a-z0-9_]{0,63}$/.test(field); });
		var heading = section.option(form.DummyValue, '_apply_heading', 'Какие настройки применять из конфига');
		heading.cfgvalue = function() {
			return 'Все галочки включены по умолчанию. Выключенная галочка сохраняет локальное значение: добавления, замены и удаления этого параметра пропускаются. Отсутствующий в файле параметр ничего не меняет. Новые параметры появятся после успешного теста и обновления страницы.';
		};
		function addField(field) {
			var control = section.option(form.Flag, '_apply_' + field.replace('.', '_'), labels[field] || field);
			control.default = '1';
			control.rmempty = false;
			control.cfgvalue = function(sectionId) { return ignoredOptions(sectionId).indexOf(field) < 0 ? '1' : '0'; };
			control.write = function(sectionId, value) {
				var ignored = ignoredOptions(sectionId).filter(function(item) { return item !== field; });
				if (value === '0') ignored.push(field);
				if (ignored.length) uci.set('podkop_config_auto_updater', sectionId, 'ignored_options', ignored);
				else uci.unset('podkop_config_auto_updater', sectionId, 'ignored_options');
			};
			control.remove = function(sectionId) { this.write(sectionId, '1'); };
		}
		[['main.', 'Секция MAIN'], ['notUnderSanctions.', 'Секция notUnderSanctions'], ['settings.', 'Общие настройки Podkop']].forEach(function(group) {
			var title = section.option(form.DummyValue, '_heading_' + group[0].replace('.', ''), '');
			title.rawhtml = true;
			title.cfgvalue = function() { return '<h3>' + group[1] + '</h3>'; };
			fields.filter(function(field) { return field.indexOf(group[0]) === 0; }).forEach(addField);
		});

		var statusNode = E('p', {role: 'status', style: 'white-space: pre-line'}, statusText(status));
		var healthNode = E('p', {id: 'podkop-updater-openai-status', role: 'status', style: 'white-space: pre-line'}, healthText(status));
		var updateOperation = status.state === 'running' ? status.operation : null;
		function refreshConfig(current) {
			healthNode.textContent = healthText(current);
			refreshEnabled(current);
			if (updateOperation && current.operation !== updateOperation) {
				statusNode.textContent = 'Ожидается результат запущенного обновления. Полученный статус относится к другой операции.';
				return;
			}
			statusNode.textContent = statusText(current);
			button.disabled = current.state === 'running';
			if (updateOperation && current.operation === updateOperation &&
				['applied', 'unchanged', 'error'].indexOf(current.state) >= 0) {
				updateOperation = null;
				ui.addNotification(null, E('p', {}, statusText(current)), current.state === 'error' ? 'error' : 'info');
			}
		}
		var button = E('button', {class: 'cbi-button cbi-button-action', type: 'button',
			disabled: status.state === 'running' ? true : null,
			click: ui.createHandlerFn(this, function() {
				return fs.exec(runner, ['update-start']).then(function(result) {
					var report;
					try { report = JSON.parse(result.stdout || '{}'); } catch (error) { report = {}; }
					if (result.code !== 0 || report.state !== 'running' || typeof report.operation !== 'string') {
						ui.addNotification(null, E('p', {}, errors[report.error] || 'Не удалось запустить обновление конфига.'), 'error');
						return;
					}
					updateOperation = report.operation;
					statusNode.textContent = statusText(report);
					return readStatus().then(refreshConfig);
				}).catch(function() {
					statusNode.textContent = 'Связь с роутером временно недоступна. Результат обновления пока не подтверждён; проверка состояния продолжится.';
				});
			})}, 'Обновить сейчас');
		var testButton = E('button', {class: 'cbi-button cbi-button-neutral', type: 'button',
			click: ui.createHandlerFn(this, function() {
				return fs.exec(runner, ['test']).then(function(result) {
					var report;
					try { report = JSON.parse(result.stdout || '{}'); }
					catch (error) { report = null; }
					if (!report || typeof report !== 'object' || !report.state) {
						report = {error: /Syntax error|Unable to compile module/.test(result.stderr || '') ? 'runtime_incompatible' : 'worker_failed'};
					}
					showTestResult(report, result.code === 0 && report.state === 'tested' && report.valid === true);
				}).catch(function(error) {
					var message = error.message || '';
					showTestResult({error: /Access denied|Permission denied/i.test(message) ? 'rpc_access_denied' :
						(/timeout|timed out/i.test(message) ? 'rpc_timeout' : 'rpc_unavailable')}, false);
				});
			})}, 'Тест соединения');
		var softwareStatus = status.software || {state: 'idle'};
		var softwareNode = E('p', {role: 'status'}, softwareText(softwareStatus));
		var softwareActive = softwareStatus.state === 'running';
		function refreshSoftware() {
			return readSoftwareStatus().then(function(current) {
				softwareNode.textContent = softwareText(current);
				if (softwareActive && current.state !== 'running' && current.state !== 'unavailable') {
					softwareActive = false;
					poll.remove(refreshSoftware);
					showSoftwareResult(current.state === 'idle' ? {state: 'error', error: 'interrupted'} : current);
				}
			});
		}
		function startSoftware(target) {
			return fs.exec(softwareRunner, [target]).then(function(result) {
				var report;
				try { report = JSON.parse(result.stdout || '{}') || {}; }
				catch (error) { report = {}; }
				if (result.code !== 0 || report.state !== 'running') {
					showSoftwareResult({state: 'error', error: report.error});
					return;
				}
				softwareActive = true;
				showSoftwareResult(report);
				poll.add(refreshSoftware, 3);
				return refreshSoftware();
			}).catch(function() { showSoftwareResult({state: 'error'}); });
		}
		var podkopButton = E('button', {class: 'cbi-button cbi-button-action', type: 'button',
			click: ui.createHandlerFn(this, function() { return startSoftware('podkop'); })}, 'Обновить подкоп');
		var selfButton = E('button', {class: 'cbi-button cbi-button-action', type: 'button',
			click: ui.createHandlerFn(this, function() { return startSoftware('self'); })}, 'Обновить себя');
		if (softwareActive) poll.add(refreshSoftware, 3);
		poll.add(function() { return readStatus().then(refreshConfig).catch(function() {
			statusNode.textContent = 'Не удалось получить состояние обновления с роутера. Проверка состояния продолжится.';
			healthNode.textContent = 'Контроль OpenAI: не удалось получить состояние с роутера.';
		}); }, 10);
		return map.render().then(function(formNode) {
			enabledNode = formNode.querySelector('#podkop-updater-enabled');
			refreshEnabled(status);
			return E('div', {}, [formNode, statusNode, healthNode, E('div', {class: 'cbi-page-actions'}, [testButton, ' ', button]),
				E('p', {class: 'cbi-section-descr'}, 'Обе кнопки используют сохранённые настройки. После изменения полей нажмите «Сохранить и применить». Тест соединения только скачивает и проверяет файл.'),
				E('h3', {}, 'Обновление программ'), softwareNode,
				E('div', {class: 'cbi-page-actions'}, [podkopButton, ' ', selfButton]),
				E('p', {class: 'cbi-section-descr'}, 'Эти кнопки устанавливают пакеты из официальных релизов. Перед установкой сохраняется резервная копия настроек. Во время обновления возможен краткий перерыв в работе служб.')]);
		});
	}
});
