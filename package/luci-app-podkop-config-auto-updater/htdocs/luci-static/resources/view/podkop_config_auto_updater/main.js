'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';

var runner = '/usr/libexec/podkop-config-auto-updater/run';
var errors = {
	missing_token: 'Укажите токен GitHub с правом чтения содержимого репозитория.',
	invalid_source: 'Проверьте HTTPS-ссылку на файл конфигурации.',
	invalid_github_url: 'Скопируйте ссылку на файл из GitHub. Пример есть в инструкции под полем токена.',
	token_host_mismatch: 'Для ссылки на личный сервер очистите поле токена GitHub.',
	download_failed: 'Файл не загружен. Проверьте ссылку, срок действия токена и доступ к репозиторию.',
	pending_changes: 'В Podkop есть несохранённые изменения. Сохраните или отмените их и повторите обновление.',
	concurrent_change: 'Настройки Podkop изменились во время обновления. Повторите обновление.',
	empty_proxy_pool: 'Удаление оставило бы секцию без серверов. Настройки сохранены без изменений.',
	incompatible_section: 'Секция main использует другой тип подключения. Выберите в Podkop Proxy и URLTest.',
	podkop_missing: 'Сначала установите и настройте Podkop.',
	restart_failed_restored: 'Podkop не принял изменения. Предыдущая конфигурация восстановлена.',
	restart_failed_manual_recovery: 'Podkop не запустился, а конфигурация уже изменена вручную. Нужна проверка администратора.',
	rollback_restart_failed: 'Конфигурация восстановлена, но Podkop не запустился. Нужна проверка администратора.',
	clock_not_ready: 'Проверьте дату и время роутера.',
	busy: 'Обновление уже выполняется.'
};

function readStatus() {
	return fs.exec(runner, ['status']).then(function(result) {
		try { return JSON.parse(result.stdout || '{}'); }
		catch (error) { return {}; }
	});
}

function statusText(status) {
	var text = status.enabled ? 'Работает.' : 'Автоматическое обновление выключено.';
	if (status.next_run && status.enabled)
		text += ' Следующее обновление: ' + new Date(status.next_run * 1000).toLocaleString() + ' (время вашего браузера).';
	if (status.state === 'applied') text += ' Последние изменения применены.';
	if (status.state === 'unchanged') text += ' Последняя проверка: новых изменений нет.';
	if (status.state === 'error') text += ' ' + (errors[status.error] || 'Конфигурация не принята: ' + status.error + '.');
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
	load: function() { return readStatus(); },
	render: function(status) {
		var map = new form.Map('podkop_config_auto_updater', 'Podkop config auto updater',
			'Добавляет серверы URLTest, пользовательские домены и подсети в секцию main программы Podkop.');
		var section = map.section(form.NamedSection, 'main', 'settings');
		section.addremove = false;
		var option = section.option(form.Flag, 'enabled', 'Работать');
		option.default = '1';
		option.rmempty = false;
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
		option = section.option(form.Value, 'config_url', 'Ссылка на файл конфига');
		option.placeholder = 'https://github.com/OWNER/REPO/blob/main/config/main.json';
		option.rmempty = false;
		option.validate = function(sectionId, value) {
			return !value || /^https:\/\/[^\s]+$/.test(value) ? true : 'Укажите полную HTTPS-ссылку.';
		};
		option = section.option(form.Value, 'github_token', 'Токен GitHub');
		option.password = true;
		option.rmempty = false;
		option.description = E('span', {}, [
			'Для закрытого репозитория нужен токен с правом Contents: Read-only. ',
			E('a', {
				href: 'https://github.com/hayOfLife/podkop-config-auto-updater/blob/main/docs/github-setup.ru.md',
				target: '_blank', rel: 'noopener noreferrer'
			}, 'Как создать закрытый репозиторий и получить токен')
		]);

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
		poll.add(function() { return readStatus().then(function(current) { statusNode.textContent = statusText(current); }); }, 30);
		return map.render().then(function(formNode) {
			return E('div', {}, [formNode, statusNode, button,
				E('p', {class: 'cbi-section-descr'}, 'Кнопка использует сохранённые настройки. После изменения полей нажмите «Сохранить и применить».')]);
		});
	}
});
