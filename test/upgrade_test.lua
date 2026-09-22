--- Тесты применения миграций на настоящем инстансе: проверяется работа
--- со спейсами, транзакционность шага и запрет DDL на реплике.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.schema.upgrade')

helper.serve(g)

-- Пустой набор шагов оставляет схему нетронутой.
g.test_no_steps_leaves_version_zero = function()
    local result = g.server:exec(function()
        return _G.schema.upgrade()
    end)

    t.assert_equals(result.from, 0)
    t.assert_equals(result.to, 0)
    t.assert_equals(result.applied, {})
end

-- Шаг применяется, версия записывается.
g.test_applies_step_and_records_version = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function(box_module)
            local space = box_module.schema.space.create('probe', {
                format = { { name = 'id', type = 'unsigned' } },
            })
            space:create_index('pk')
        end)

        return {
            upgrade = _G.schema.upgrade(),
            space_exists = box.space.probe ~= nil,
            version = _G.schema.current_version(),
        }
    end)

    t.assert_equals(result.upgrade.applied, { 1 })
    t.assert_equals(result.space_exists, true)
    t.assert_equals(result.version, 1)
end

-- Повторный запуск не применяет уже применённое.
g.test_second_run_is_a_no_op = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function(box_module)
            box_module.schema.space.create('probe'):create_index('pk')
        end)

        _G.schema.upgrade()
        return _G.schema.upgrade()
    end)

    t.assert_equals(result.applied, {})
    t.assert_equals(result.from, 1)
end

-- Шаги применяются по порядку.
g.test_applies_steps_in_order = function()
    local order = g.server:exec(function()
        local applied = {}

        for version = 1, 3 do
            _G.schema.register(version, function()
                table.insert(applied, version)
            end)
        end

        _G.schema.upgrade()
        return applied
    end)

    t.assert_equals(order, { 1, 2, 3 })
end

-- Догоняются только неприменённые шаги.
g.test_applies_only_pending_steps = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function(box_module)
            box_module.schema.space.create('probe'):create_index('pk')
        end)
        _G.schema.upgrade()

        _G.schema.register(2, function(box_module)
            box_module.schema.space.create('probe_two'):create_index('pk')
        end)

        return _G.schema.upgrade()
    end)

    t.assert_equals(result.from, 1)
    t.assert_equals(result.applied, { 2 })
end

-- Упавший шаг откатывается целиком: ни изменений, ни новой версии.
g.test_failed_step_is_rolled_back = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function(box_module)
            local space = box_module.schema.space.create('probe', {
                format = { { name = 'id', type = 'unsigned' } },
            })
            space:create_index('pk')
            space:insert({ 1 })
            error('шаг сломался')
        end)

        local upgrade, err = _G.schema.upgrade()

        return {
            upgrade = upgrade,
            err = tostring(err),
            space_exists = box.space.probe ~= nil,
            version = _G.schema.current_version(),
        }
    end)

    t.assert_equals(result.upgrade, nil)
    t.assert_str_contains(result.err, 'шаг 1 не применён')
    t.assert_str_contains(result.err, 'шаг сломался')
    t.assert_equals(result.space_exists, false, 'изменения шага откачены')
    t.assert_equals(result.version, 0, 'версия осталась прежней')
end

-- Версия в базе новее, чем в коде, — отказ: значит инстанс запустили
-- со старым кодом, и данные он может не понять.
g.test_refuses_when_database_is_newer = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.register(2, function() end)
        _G.schema.upgrade()

        -- Перезагружаем модуль с меньшим набором шагов: как если бы
        -- инстанс подняли предыдущей версией приложения.
        local older = _G.reload_schema()
        older.register(1, function() end)

        local upgrade, err = older.upgrade()
        return { upgrade = upgrade, err = tostring(err) }
    end)

    t.assert_equals(result.upgrade, nil)
    t.assert_str_contains(result.err, 'понижение версии недопустимо')
end

-- Спейс с версией реплицируемый: реплики должны узнавать о применённых
-- шагах журналом, иначе применят их повторно.
g.test_meta_space_is_replicated = function()
    local is_local = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        return box.space[_G.schema.meta_space_name()].is_local
    end)

    t.assert_equals(is_local, false)
end

-- Имя спейса с версией берётся из настройки.
g.test_meta_space_name_is_used = function()
    local exists = g.server:exec(function()
        _G.schema.configure({ meta_space = 'custom_versions' })
        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        local found = box.space.custom_versions ~= nil
        box.space.custom_versions:drop()
        return found
    end)

    t.assert_equals(exists, true)
end

-- На инстансе только для чтения схема не меняется.
g.test_read_only_instance_refuses = function()
    local result = g.server:exec(function()
        box.cfg({ read_only = true })

        _G.schema.register(1, function() end)
        local upgrade, err = _G.schema.upgrade()

        box.cfg({ read_only = false })
        return { upgrade = upgrade, err = tostring(err) }
    end)

    t.assert_equals(result.upgrade, nil)
    t.assert_str_contains(result.err, 'менять схему нельзя')
end

-- Пока спейса нет, версия считается нулевой.
g.test_version_is_zero_without_meta_space = function()
    local version = g.server:exec(function()
        return _G.schema.current_version()
    end)

    t.assert_equals(version, 0)
end

-- Время применения измеряется и неотрицательно. Шаг работает, а не спит:
-- уступка внутри шага оборвала бы транзакцию.
g.test_reports_elapsed_time = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function()
            _G.spin(0.01)
        end)

        return _G.schema.upgrade()
    end)

    t.assert_ge(result.elapsed_ms, 10, 'шаг работал десять миллисекунд')
    t.assert_lt(result.elapsed_ms, 5000, 'и это не тысячи миллисекунд')
end

-- Время меряется настоящими часами, а не отметкой цикла событий. Отметка
-- стоит на месте, пока файбер работает не уступая, и начало, снятое
-- по ней после такой работы, приписало бы миграции всё, что делал
-- вызывающий. Запас взят большим: настоящий шаг с записью в журнал идёт
-- доли миллисекунды, и спутать его с работой перед вызовом нельзя.
g.test_elapsed_does_not_take_in_the_work_done_before_the_call = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.upgrade()
        _G.schema.register(2, function() end)

        _G.spin(0.3)

        return _G.schema.upgrade()
    end)

    t.assert_equals(result.applied, { 2 })
    t.assert_lt(result.elapsed_ms, 300)
end

-- Когда применять нечего, журнал молчит, а время нулевое. Часы внешней зависимости
-- сдвигаются на каждом вызове: пустой план, пущенный циклом, отдал бы
-- ненулевое время и на тех настоящих часах, что не успели сдвинуться, —
-- а запись «применение миграций» с пустым планом видна и без часов.
g.test_nothing_to_apply_is_silent_and_takes_no_time = function()
    local result = g.server:exec(function()
        local logged = {}
        local now = 10

        local function record(message)
            table.insert(logged, message)
        end

        _G.schema.configure({ logger = { info = record, warn = record, error = record } })
        _G.schema._set_source({
            monotonic = function()
                now = now + 1

                return now
            end,
        })

        return { report = _G.schema.upgrade(), logged = logged }
    end)

    t.assert_equals(result.report, { from = 0, to = 0, applied = {}, elapsed_ms = 0 })
    t.assert_equals(result.logged, {})
end

-- Время шага и всего подъёма — разности часов в миллисекундах, точно.
-- Часы внешней зависимости отдают по очереди начало подъёма, начало шага, конец шага
-- и конец подъёма: на настоящих часах проверка видела бы только
-- диапазон, и ошибку единиц или знака в замере он пропускал.
g.test_elapsed_is_measured_by_the_clock_in_milliseconds = function()
    local result = g.server:exec(function()
        local readings = { 10, 10, 10.25, 10.5 }
        local calls = 0
        local steps = {}

        _G.schema.configure({
            logger = {
                info = function(message, fields)
                    if message == 'шаг применён' then
                        table.insert(steps, fields)
                    end
                end,
                warn = function() end,
                error = function() end,
            },
        })
        _G.schema._set_source({
            monotonic = function()
                calls = calls + 1

                return assert(readings[calls], 'часы спрошены лишний раз')
            end,
        })
        _G.schema.register(1, function() end)

        return { report = _G.schema.upgrade(), steps = steps, calls = calls }
    end)

    t.assert_equals(result.steps, { { version = 1, elapsed_ms = 250 } })
    t.assert_equals(result.report.elapsed_ms, 500)
    t.assert_equals(result.calls, 4)
end

-- Повторное разворачивание спейса версии не падает.
g.test_meta_space_creation_is_idempotent = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        _G.schema.register(2, function() end)
        local upgrade, err = _G.schema.upgrade()

        return { applied = upgrade and upgrade.applied, err = tostring(err) }
    end)

    t.assert_equals(result.applied, { 2 })
end

-- Испорченное значение версии читается как нулевое, а не роняет старт.
g.test_unreadable_version_is_treated_as_zero = function()
    local version = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        box.space[_G.schema.meta_space_name()]:replace({ 'schema_version', 'не число' })
        return _G.schema.current_version()
    end)

    t.assert_equals(version, 0)
end

-- Пропуск в нумерации ловится и при настоящем применении, а не только
-- в планировании.
g.test_missing_step_stops_upgrade = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.register(3, function() end)

        local upgrade, err = _G.schema.upgrade()
        return { upgrade = upgrade, err = tostring(err), version = _G.schema.current_version() }
    end)

    t.assert_equals(result.upgrade, nil)
    t.assert_str_contains(result.err, 'шаг 2 не зарегистрирован')
    t.assert_equals(result.version, 0, 'ни один шаг не применён')
end

-- Журнал получает сообщения о применении.
g.test_logger_receives_progress = function()
    local messages = g.server:exec(function()
        local logged = {}

        _G.schema.configure({
            logger = {
                info = function(message)
                    table.insert(logged, message)
                end,
                warn = function() end,
                error = function() end,
            },
        })
        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        return logged
    end)

    t.assert_equals(#messages, 2, 'начало и применённый шаг')
    t.assert_str_contains(messages[1], 'применение миграций')
end

-- Исходник вызывающего с известным именем: место ошибки программиста
-- сверяется дословно, и оно должно показывать на строку вызывающего,
-- а не на строку внутри раннера.
local CALLER = 'return function(upgrade) local report, err = upgrade() return report, err end'

-- Внутри транзакции раннер не зовётся: уступка оборвала бы транзакцию
-- вызывающего. Раньше отказ шага откатывал её молча — теперь она цела.
g.test_upgrade_inside_a_transaction_raises = function()
    local result = g.server:exec(function(caller_source)
        local call = assert(load(caller_source, '=caller'))()

        _G.schema.register(1, function() end)

        box.begin()

        local ok, err = pcall(call, _G.schema.upgrade)
        local still_open = box.is_in_txn()

        box.rollback()

        return { ok = ok, err = err, still_open = still_open, version = _G.schema.current_version() }
    end, { CALLER })

    t.assert_equals(result, {
        ok = false,
        err = 'caller:1: раннер миграций уступает управление вокруг шага и этим обрывает транзакцию: '
            .. 'внутри транзакции его не зовут',
        still_open = true,
        version = 0,
    })
end

-- Срез, съеденный вызывающим до вызова, шаг не срывает: перед шагом
-- файбер уступает, и срез начинается заново. Спейс с версией развёрнут
-- заранее: иначе его создание уступило бы само, и проверка ничего
-- не доказывала бы. Обход в полторы тысячи строк затем, что ядро
-- сверяет срез раз в тысячу обращений к box; срез взят с запасом,
-- чтобы обход укладывался в него и под замером покрытия.
g.test_slice_spent_by_the_caller_does_not_break_the_step = function()
    local result = g.server:exec(function()
        return _G.second_step_under_slice(0.2, _G.walking_step(0), nil, function()
            _G.spin(0.3)
        end)
    end)

    t.assert_equals(result.err, nil)
    t.assert_equals(result.report.applied, { 2 })
    t.assert_equals(result.version, 2)
end

-- Шаг длиннее среза срывается на срезе: транзакция откатывается, версия
-- прежняя, а отказ подсказывает задать шагу срез.
g.test_step_longer_than_the_slice_fails_with_a_hint = function()
    local result = g.server:exec(function()
        local logged = {}

        _G.schema.configure({
            logger = {
                info = function() end,
                warn = function() end,
                error = function(message, fields)
                    table.insert(logged, { message = message, fields = fields })
                end,
            },
        })

        local outcome = _G.second_step_under_slice(0.02, _G.walking_step(0.03))
        outcome.logged = logged

        return outcome
    end)

    t.assert_equals(result.report, nil)
    t.assert_equals(
        result.err,
        'шаг 2 не применён: шаг шёл без уступки дольше среза файбера (fiber slice is exceeded); '
            .. 'долгому шагу задают срез в секундах: register(2, step, { slice = секунды }), '
            .. 'а в migrations ядра и в файле database/migrations — { step = шаг, slice = секунды } вместо шага'
    )
    t.assert_equals(result.version, 1, 'версия осталась прежней')
    t.assert_equals(result.in_txn, false, 'транзакция шага закрыта')
    t.assert_equals(result.rows, 1500, 'строки на месте')
    t.assert_equals(result.logged, {
        {
            message = 'шаг миграции не применён',
            fields = { version = 2, err = 'fiber slice is exceeded' },
        },
    })
end

-- Отказ box в шаге, не связанный со срезом, подсказки не получает.
g.test_box_failure_in_a_step_has_no_slice_hint = function()
    local err = g.server:exec(function()
        _G.schema.register(1, function(box_module)
            local space = box_module.schema.space.create('probe')
            space:create_index('pk')
            space:insert({ 1 })
            space:insert({ 1 })
        end)

        local _, failure = _G.schema.upgrade()

        return failure
    end)

    t.assert_str_matches(err, '^шаг 1 не применён: Duplicate key exists.*$')
    t.assert_not_str_contains(err, 'срез')
end

-- Шаг с заданным срезом переживает срез ядра: `slice` — это срез
-- файбера на время шага.
g.test_step_with_a_slice_outlives_the_default_one = function()
    local result = g.server:exec(function()
        return _G.second_step_under_slice(0.02, _G.walking_step(0.03), { slice = 1 })
    end)

    t.assert_equals(result.err, nil)
    t.assert_equals(result.report.applied, { 2 })
    t.assert_equals(result.version, 2)
    t.assert_equals(result.rows, 1500)
end

-- Срез шага кончается вместе с шагом: после него вызывающий живёт под
-- своим срезом, а не под выданным шагу.
g.test_step_slice_ends_with_the_step = function()
    local result = g.server:exec(function()
        local probe = _G.fill_probe()
        _G.schema.register(1, function() end, { slice = 1 })

        return _G.with_slice(0.02, function()
            local report = assert(_G.schema.upgrade())

            _G.spin(0.03)

            local ok, err = pcall(function()
                for id = 1, 1500 do
                    probe:get(id)
                end
            end)

            return { applied = report.applied, ok = ok, err = tostring(err) }
        end)
    end)

    t.assert_equals(result.applied, { 1 })
    t.assert_equals(result.ok, false, 'срез вызывающего снова его собственный')
    t.assert_equals(result.err, 'fiber slice is exceeded')
end

-- Срез, съеденный сорвавшимся шагом, вызывающему не достаётся: после
-- отката файбер уступает. Шаг падает сам, не обращаясь к box, иначе
-- сорвался бы на срезе ещё внутри транзакции; откат не уступает,
-- и без уступки после шага следующее же обращение к box у вызывающего
-- упало бы за чужую работу. Срез взят с запасом, чтобы полторы тысячи
-- выборок вызывающего укладывались в него и под замером покрытия.
g.test_slice_spent_by_a_failed_step_is_not_left_to_the_caller = function()
    local result = g.server:exec(function()
        local probe = _G.fill_probe()
        _G.schema.register(1, function() end)
        assert(_G.schema.upgrade())
        _G.schema.register(2, function()
            _G.spin(0.3)
            error('шаг сломался', 0)
        end)

        return _G.with_slice(0.2, function()
            local report, err = _G.schema.upgrade()

            local ok, failure = pcall(function()
                for id = 1, 1500 do
                    probe:get(id)
                end
            end)

            return { report = report, err = err, ok = ok, failure = tostring(failure) }
        end)
    end)

    t.assert_equals(result.report, nil)
    t.assert_equals(result.err, 'шаг 2 не применён: шаг сломался')
    t.assert_equals(result.ok, true, result.failure)
end

-- Пока раннер стоял на уступке, миграции применил кто-то ещё: шаг
-- поверх чужого не применяется, версия не откатывается. Соседа играет
-- подменённая уступка: на первой из них она сама поднимает схему.
g.test_version_moved_while_the_runner_yielded = function()
    local result = g.server:exec(function()
        local fiber = require('fiber')
        local runs = 0
        local yields = 0
        local neighbour

        _G.schema.register(1, function()
            runs = runs + 1
        end)

        _G.schema._set_source({
            yield = function()
                yields = yields + 1

                if yields == 1 then
                    neighbour = { _G.schema.upgrade() }
                end

                fiber.yield()
            end,
        })

        local report, err = _G.schema.upgrade()

        return { report = report, err = err, neighbour = neighbour, runs = runs, version = _G.schema.current_version() }
    end)

    t.assert_equals(result.report, nil)
    t.assert_equals(
        result.err,
        'шаг 1 не применён: пока раннер стоял на уступке, версия в базе стала 1 — миграции применяет кто-то ещё'
    )
    t.assert_equals(result.neighbour[1].applied, { 1 })
    t.assert_equals(result.runs, 1, 'шаг выполнен один раз')
    t.assert_equals(result.version, 1)
end
