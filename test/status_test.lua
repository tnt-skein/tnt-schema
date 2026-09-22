--- Журнал шагов и состояние схемы на настоящем инстансе: запись журнала
--- в транзакции шага, сведение версии, журнала и шагов кода.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.schema.status')

helper.serve(g)

-- Шаг кладёт в журнал номер, время, узел и длительность — той же
-- транзакцией, что версию. Часы и имя узла подменены: запись сверяется
-- точными числами, а не диапазоном.
g.test_a_step_leaves_a_record_with_time_instance_and_duration = function()
    local result = g.server:exec(function()
        local readings = { 10, 10, 10.25, 10.5 }
        local calls = 0

        _G.schema._set_source({
            monotonic = function()
                calls = calls + 1

                return readings[calls]
            end,
            realtime = function()
                return 1790000000.5
            end,
            instance = function()
                return 'storage-001-a'
            end,
        })
        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        ---@type any
        local history = box.space[_G.schema.steps_space_name()]
        local key = history.index.primary.parts[1]

        return { rows = history:select(), is_local = history.is_local, key = { key.fieldno, key.type } }
    end)

    t.assert_equals(result.rows, { { 1, 1790000000.5, 'storage-001-a', 250 } })
    -- Тип ключа сверяется отдельно: дробный номер и так отвергла бы
    -- разметка поля, и по записям ключ `number` от `unsigned` не отличить.
    t.assert_equals(
        result.key,
        { 1, 'unsigned' },
        'ключ журнала — номер шага, целое без знака'
    )
    t.assert_equals(
        result.is_local,
        false,
        'журнал уезжает на реплики вместе с версией'
    )
end

-- Без подмены журнал называет узел: узел проверок поднят без имени,
-- и за него говорит uuid. Время — настоящие стенные часы.
g.test_an_instance_without_a_name_is_recorded_by_uuid = function()
    local result = g.server:exec(function()
        local before = require('clock').realtime()

        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        ---@type any
        local row = box.space.app_schema_steps:get(1)

        return {
            instance = row.instance,
            uuid = box.info.uuid,
            name = box.info.name,
            fresh = row.applied_at >= before and row.applied_at <= require('clock').realtime(),
        }
    end)

    t.assert_equals(result.name, nil)
    t.assert_equals(result.instance, result.uuid)
    t.assert_equals(result.fresh, true)
end

-- У узла с именем журнал пишет имя, а не uuid.
g.test_an_instance_with_a_name_is_recorded_by_name = function()
    local recorded = g.server:exec(function()
        local real = box.info

        -- box.info подменяется на время подъёма: ядро не даёт назвать
        -- узел, поднятый голым box.cfg. Подмене хватает того, что спросит
        -- раннер: записи разрешены, имя и uuid.
        rawset(box, 'info', { ro = false, name = 'router-001-a', uuid = 'не он' })

        local ok, failure = pcall(function()
            _G.schema.register(1, function() end)

            return _G.schema.upgrade()
        end)

        rawset(box, 'info', real)
        assert(ok, failure)

        ---@type any
        local row = box.space.app_schema_steps:get(1)

        return row.instance
    end)

    t.assert_equals(recorded, 'router-001-a')
end

-- Сорвавшийся шаг записи в журнале не оставляет: она в той же транзакции.
g.test_a_failed_step_leaves_no_record = function()
    local rows = g.server:exec(function()
        _G.schema.register(1, function()
            error('шаг сломался')
        end)
        _G.schema.upgrade()

        return box.space.app_schema_steps:select()
    end)

    t.assert_equals(rows, {})
end

-- Имя журнала настраивается, как и имя спейса с версией.
g.test_the_steps_space_is_configurable = function()
    local result = g.server:exec(function()
        _G.schema.configure({ steps_space = 'custom_steps' })
        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        local rows = box.space.custom_steps:len()
        box.space.custom_steps:drop()

        return { rows = rows, name = _G.schema.steps_space_name() }
    end)

    t.assert_equals(result, { rows = 1, name = 'custom_steps' })

    -- Место в отказе — строка вызывающего, а не пакета.
    local refused = g.server:exec(function()
        local ok, err = pcall(function()
            _G.schema.configure({ steps_space = '' })
        end)

        return { ok = ok, err = tostring(err) }
    end)

    t.assert_equals(refused.ok, false)
    t.assert_str_matches(
        refused.err,
        '.*status_test.lua:%d+: steps_space должен быть непустой строкой'
    )
end

-- Свежая база: ничего не применено, всё из кода ждёт.
g.test_status_of_a_fresh_database_lists_every_step_as_pending = function()
    local status = g.server:exec(function()
        _G.schema._set_source({
            instance = function()
                return 'storage-001-a'
            end,
        })
        _G.schema.register(1, function() end)
        _G.schema.register(2, function() end)

        return _G.schema.status()
    end)

    t.assert_equals(status, {
        instance = 'storage-001-a',
        current = 0,
        target = 2,
        steps = {
            { version = 1, applied = false, registered = true },
            { version = 2, applied = false, registered = true },
        },
    })
end

-- После подъёма шаги применены, и журнал называет, когда и кем.
g.test_status_after_an_upgrade_names_time_instance_and_duration = function()
    local status = g.server:exec(function()
        ---@type number
        local now = 0

        _G.schema._set_source({
            monotonic = function()
                now = now + 0.5

                return now
            end,
            realtime = function()
                return 1790000000
            end,
            instance = function()
                return 'storage-001-a'
            end,
        })
        _G.schema.register(1, function() end)
        _G.schema.register(2, function() end)
        _G.schema.upgrade()
        _G.schema.register(3, function() end)

        return _G.schema.status()
    end)

    t.assert_equals(status.current, 2)
    t.assert_equals(status.target, 3)
    t.assert_equals(status.steps, {
        {
            version = 1,
            applied = true,
            registered = true,
            applied_at = 1790000000,
            instance = 'storage-001-a',
            elapsed_ms = 500,
        },
        {
            version = 2,
            applied = true,
            registered = true,
            applied_at = 1790000000,
            instance = 'storage-001-a',
            elapsed_ms = 500,
        },
        { version = 3, applied = false, registered = true },
    })
end

-- Шаг, применённый до журнала, виден применённым, но без времени и узла.
g.test_a_step_applied_before_the_journal_is_applied_without_time = function()
    local steps = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.register(2, function() end)
        _G.schema.upgrade()

        -- Так выглядит база, поднятая раннером до журнала: версия есть,
        -- записей нет.
        box.space.app_schema_steps:truncate()

        return _G.schema.status().steps
    end)

    t.assert_equals(steps, {
        { version = 1, applied = true, registered = true },
        { version = 2, applied = true, registered = true },
    })
end

-- Шаг, которого нет в коде, виден строкой: база новее кода, а в пропуске
-- нумерации подъём откажет.
g.test_steps_missing_in_the_code_are_listed_as_unregistered = function()
    local result = g.server:exec(function()
        local newer = _G.reload_schema()

        newer._set_source({
            realtime = function()
                return 5
            end,
            instance = function()
                return 'storage-001-b'
            end,
        })

        for version = 1, 3 do
            newer.register(version, function() end)
        end

        newer.upgrade()

        -- Код старее базы и с пропуском: шагов 2 и 3 в нём нет, а 4 есть.
        _G.schema.register(1, function() end)
        _G.schema.register(4, function() end)

        local status = _G.schema.status()
        local versions = {}

        for _, step in ipairs(status.steps) do
            table.insert(versions, { step.version, step.applied, step.registered, step.instance })
        end

        return { current = status.current, target = status.target, versions = versions }
    end)

    t.assert_equals(result.current, 3)
    t.assert_equals(result.target, 4)
    t.assert_equals(result.versions, {
        { 1, true, true, 'storage-001-b' },
        { 2, true, false, 'storage-001-b' },
        { 3, true, false, 'storage-001-b' },
        { 4, false, true },
    })
end

-- База новее кода, а журнал знает шаги выше кода: они видны, хотя в коде
-- их нет вовсе, — список идёт до наибольшего из кода и журнала.
g.test_the_list_reaches_the_highest_recorded_step = function()
    local versions = g.server:exec(function()
        local newer = _G.reload_schema()

        for version = 1, 2 do
            newer.register(version, function() end)
        end

        newer.upgrade()

        local listed = {}

        for _, step in ipairs(_G.schema.status().steps) do
            table.insert(listed, { step.version, step.applied, step.registered })
        end

        return listed
    end)

    t.assert_equals(versions, { { 1, true, false }, { 2, true, false } })
end

-- Запись журнала выше версии в базе не показывается: версию правили
-- руками, и шаг применится заново.
g.test_a_record_above_the_version_is_not_shown = function()
    local steps = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.register(2, function() end)
        _G.schema.upgrade()

        box.space.app_schema_meta:replace({ 'schema_version', '1' })

        return _G.schema.status().steps
    end)

    t.assert_equals(#steps, 2)
    t.assert_equals(steps[1].applied, true)
    t.assert_not_equals(steps[1].applied_at, nil)
    t.assert_equals(steps[2], { version = 2, applied = false, registered = true })
end

-- Без журнала и без спейса с версией состояние читается: всё ждёт.
g.test_status_without_the_runner_spaces = function()
    local status = g.server:exec(function()
        _G.schema.register(1, function() end)

        local found = _G.schema.status()

        return { current = found.current, steps = found.steps, meta = box.space.app_schema_meta }
    end)

    t.assert_equals(status.current, 0)
    t.assert_equals(status.steps, { { version = 1, applied = false, registered = true } })
    t.assert_equals(status.meta, nil, 'состояние ничего не разворачивает')
end

-- Состояние читается и на инстансе только для чтения: шаги применил лидер.
g.test_status_is_read_on_a_read_only_instance = function()
    local result = g.server:exec(function()
        _G.schema.register(1, function() end)
        _G.schema.upgrade()

        box.cfg({ read_only = true })

        local status, err = _G.schema.status()

        box.cfg({ read_only = false })

        return { current = status and status.current, err = err }
    end)

    t.assert_equals(result, { current = 1 })
end
