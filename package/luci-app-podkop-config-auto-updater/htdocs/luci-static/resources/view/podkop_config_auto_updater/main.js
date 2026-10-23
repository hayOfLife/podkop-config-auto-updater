'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';

var runner = '/usr/libexec/podkop-config-auto-updater/run';
var softwareRunner = '/usr/libexec/podkop-config-auto-updater/software';
var errors = {
	missing_token: 'Укажите токен GitHub с правом чтения содержимого репозитория.',
	invalid_token: 'Проверьте токен GitHub: в нём не должно быть пробелов или переносов строк.',
	invalid_source: 'Проверьте HTTPS-ссылку на файл конфигурации.',
	invalid_github_url: 'Скопируйте ссылку на файл из GitHub. Пример есть в инструкции под полем токена.',
	token_host_mismatch: 'Для ссылки на личный сервер очистите поле токена GitHub.',
	download_failed: 'Файл не загружен. Проверьте ссылку, срок действия токена и доступ к репозиторию.',
	invalid_json: 'Файл скачан, но содержит некорректный JSON.',
	invalid_size: 'Скачанный файл пуст или превышает допустимый размер 1 МиБ.',
	runtime_incompatible: 'Обработчик теста не запустился: ошибка компиляции ucode. Обновите Podkop config auto updater до совместимой версии.',
	worker_failed: 'Обработчик теста завершился без результата. Выполните в SSH: /usr/libexec/podkop-config-auto-updater/run test.',
	rpc_access_denied: 'LuCI отказал в запуске теста. Выйдите из LuCI и войдите снова, чтобы обновить права сессии.',
	rpc_timeout: 'LuCI не дождался результата теста. Проверьте источник командой в SSH: /usr/libexec/podkop-config-auto-updater/run test.',
	rpc_unavailable: 'Не удалось связаться с обработчиком LuCI. Обновите страницу и повторите тест.',
	pending_changes: 'В Podkop есть несохранённые изменения. Сохраните или отмените их и повторите обновление.',
	concurrent_change: 'Настройки Podkop изменились во время обновления. Повторите обновление.',
	empty_proxy_pool: 'Удаление оставило бы секцию без серверов. Настройки сохранены без изменений.',
	incompatible_section: 'Секция main использует другой тип подключения. Выберите в Podkop Proxy и URLTest.',
	podkop_missing: 'Сначала установите и настройте Podkop.',
	restart_failed_restored: 'Podkop не принял изменения. Предыдущая конфигурация восстановлена.',
	restart_failed_manual_recovery: 'Podkop не запустился, а конфигурация уже изменена вручную. Нужна проверка администратора.',
	rollback_restart_failed: 'Конфигурация восстановлена, но Podkop не запустился. Нужна проверка администратора.',
	clock_not_ready: 'Проверьте дату и время роутера.',
	busy: 'Уже выполняется другая операция. Дождитесь её окончания.',
	unsupported_platform: 'Обновление поддерживается на OpenWrt 24.10 и 25.12.',
	podkop_migration_required: 'Для Podkop версии ниже 0.7.0 требуется отдельная миграция настроек. Используйте официальную инструкцию Podkop.',
	invalid_release: 'Не удалось прочитать сведения об официальном релизе.',
	missing_package: 'В релизе нет подходящего пакета для этой версии OpenWrt.',
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
	content.push(E('div', {class: 'right'}, E('button', {class: 'cbi-button', type: 'button', click: ui.hideModal}, 'Закрыть')));
	ui.showModal('Тест соединения', content);
}

function readStatus() {
	return fs.exec(runner, ['status']).then(function(result) {
		try { return JSON.parse(result.stdout || '{}'); }
		catch (error) { return {}; }
	});
}

function readSoftwareStatus() {
	return fs.exec(softwareRunner, ['status']).then(function(result) {
		try { return JSON.parse(result.stdout || '{}') || {}; }
		catch (error) { return {state: 'unavailable'}; }
	}).catch(function() { return {state: 'unavailable'}; });
}

function softwareText(status) {
	var name = status.target === 'podkop' ? 'Podkop' : 'Podkop config auto updater';
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
	return text;
}

return view.extend({
	load: function() {
		return Promise.all([readStatus(), readSoftwareStatus()]).then(function(results) {
			results[0].software = results[1];
			return results[0];
		});
	},
	render: function(status) {
		var map = new form.Map('podkop_config_auto_updater', 'Podkop config auto updater',
			'Обновляет секцию main и указанные в файле настройки DNS и загрузки списков программы Podkop.');
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

		var statusNode = E('p', {role: 'status'}, statusText(status));
		var button = E('button', {class: 'cbi-button cbi-button-action', type: 'button',
			click: ui.createHandlerFn(this, function() {
				return fs.exec(runner, ['update']).then(function(result) {
					return readStatus().then(function(current) {
						statusNode.textContent = statusText(current);
						ui.addNotification(null, E('p', {}, statusText(current)), result.code ? 'error' : 'info');
					});
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
		poll.add(function() { return readStatus().then(function(current) {
			statusNode.textContent = statusText(current);
			refreshEnabled(current);
		}); }, 30);
		return map.render().then(function(formNode) {
			enabledNode = formNode.querySelector('#podkop-updater-enabled');
			refreshEnabled(status);
			return E('div', {}, [formNode, statusNode, E('div', {class: 'cbi-page-actions'}, [testButton, ' ', button]),
				E('p', {class: 'cbi-section-descr'}, 'Обе кнопки используют сохранённые настройки. После изменения полей нажмите «Сохранить и применить». Тест соединения только скачивает и проверяет файл.'),
				E('h3', {}, 'Обновление программ'), softwareNode,
				E('div', {class: 'cbi-page-actions'}, [podkopButton, ' ', selfButton]),
				E('p', {class: 'cbi-section-descr'}, 'Эти кнопки устанавливают пакеты из официальных релизов. Перед установкой сохраняется резервная копия настроек. Во время обновления возможен краткий перерыв в работе служб.')]);
		});
	}
});
