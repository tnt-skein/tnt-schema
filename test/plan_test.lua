--- Тесты планирования миграций. База не нужна: проверяется только
--- разбор набора шагов и отказ от недопустимых переходов.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.schema.plan')

--- Выполняет проверку can_run_ddl с подменённым box.
---@param schema table
---@param fake_box any Чем подменить глобальный box
---@return boolean allowed
---@return string|nil reason
local function can_run_ddl_with(schema, fake_box)
    local saved = rawget(_G, 'box')
    rawset(_G, 'box', fake_box)

    local allowed, reason = schema.can_run_ddl()

    rawset(_G, 'box', saved)
    return allowed, reason
end

g.before_each(function()
    g.schema = helper.load_schema()
end)

g.after_each(function()
    helper.unload_schema()
end)

-- Шаг регистрируется и попадает в целевую версию.
g.test_register_sets_target_version = function()
    t.assert_equals(g.schema.target_version(), 0)

    g.schema.register(1, function() end)
    g.schema.register(2, function() end)

    t.assert_equals(g.schema.target_version(), 2)
end

-- Порядок регистрации не влияет на целевую версию.
g.test_target_version_is_the_highest = function()
    g.schema.register(3, function() end)
    g.schema.register(1, function() end)

    t.assert_equals(g.schema.target_version(), 3)
end

-- Номер шага обязан быть натуральным числом.
g.test_register_rejects_invalid_version = function()
    for _, version in ipairs({ 0, -1, 1.5 }) do
        t.assert_error_msg_contains('натуральным числом', g.schema.register, version, function() end)
    end

    t.assert_error_msg_contains(
        'натуральным числом',
        g.schema.register,
        'первый',
        function() end
    )
end

-- Шаг обязан быть функцией.
g.test_register_rejects_non_function_step = function()
    t.assert_error_msg_contains('должен быть функцией', g.schema.register, 1, 'не функция')
end

-- Повторная регистрация под тем же номером — ошибка, а не тихая замена.
g.test_register_rejects_duplicate = function()
    g.schema.register(1, function() end)

    t.assert_error_msg_contains('уже зарегистрирован', g.schema.register, 1, function() end)
end

-- Срез шага — число секунд больше нуля; незнакомая настройка — опечатка,
-- а не безобидная добавка. Негодные настройки шаг не регистрируют.
g.test_register_rejects_bad_step_options = function()
    for _, case in ipairs({
        { opts = { slice = 0 }, err = 'настройки шага.slice — число больше 0, а не 0' },
        {
            opts = { slice = '30' },
            err = 'настройки шага.slice — число больше 0, а не строка',
        },
        { opts = { slyce = 30 }, err = 'настройки шага: ключа «slyce» нет, есть slice' },
        { opts = 30, err = 'настройки шага — таблица, а не число' },
    }) do
        t.assert_error_msg_content_equals(case.err, g.schema.register, 1, function() end, case.opts)
    end

    t.assert_equals(g.schema.target_version(), 0, 'ни один шаг не зарегистрирован')
end

-- Срез принимается вместе с шагом; без настроек шаг регистрируется как прежде.
g.test_register_accepts_a_slice = function()
    g.schema.register(1, function() end, { slice = 30 })
    g.schema.register(2, function() end, {})
    g.schema.register(3, function() end)

    t.assert_equals(g.schema.target_version(), 3)
end

-- План перечисляет шаги по возрастанию.
g.test_plan_lists_steps_in_order = function()
    for version = 1, 3 do
        g.schema.register(version, function() end)
    end

    t.assert_equals(g.schema.plan(0, 3), { 1, 2, 3 })
end

-- План с уже применённой частью содержит только оставшиеся шаги.
g.test_plan_skips_applied_steps = function()
    for version = 1, 3 do
        g.schema.register(version, function() end)
    end

    t.assert_equals(g.schema.plan(2, 3), { 3 })
end

-- Совпадающие версии дают пустой план.
g.test_plan_is_empty_when_up_to_date = function()
    g.schema.register(1, function() end)

    t.assert_equals(g.schema.plan(1, 1), {})
end

-- Понижение версии отвергается: откатить DDL на живом кластере нельзя.
g.test_plan_refuses_downgrade = function()
    local planned, err = g.schema.plan(3, 1)

    t.assert_equals(planned, nil)
    t.assert_str_contains(err, 'понижение версии')
end

-- Пропуск в нумерации — ошибка: иначе часть изменений молча не применится.
g.test_plan_detects_missing_step = function()
    g.schema.register(1, function() end)
    g.schema.register(3, function() end)

    local planned, err = g.schema.plan(0, 3)

    t.assert_equals(planned, nil)
    t.assert_str_contains(err, 'шаг 2 не зарегистрирован')
end

-- Нечисловые версии отвергаются.
g.test_plan_rejects_non_numeric_versions = function()
    local planned, err = g.schema.plan('ноль', 1)

    t.assert_equals(planned, nil)
    t.assert_str_contains(err, 'должны быть числами')
end

-- Имя спейса с версией настраивается: пакет не навязывает своё.
g.test_meta_space_name_is_configurable = function()
    t.assert_equals(g.schema.meta_space_name(), 'app_schema_meta')

    g.schema.configure({ meta_space = 'my_versions' })

    t.assert_equals(g.schema.meta_space_name(), 'my_versions')
end

-- Пустое имя спейса отвергается.
g.test_blank_meta_space_is_rejected = function()
    t.assert_error_msg_contains('непустой строкой', g.schema.configure, { meta_space = '' })
    t.assert_error_msg_contains('непустой строкой', g.schema.configure, { meta_space = 42 })
end

-- configure без аргументов ничего не ломает.
g.test_configure_without_arguments = function()
    g.schema.configure()

    t.assert_equals(g.schema.meta_space_name(), 'app_schema_meta')
end

-- Целевая версия не сдвигается на равных номерах.
g.test_target_version_with_equal_registrations = function()
    g.schema.register(2, function() end)
    g.schema.register(1, function() end)

    t.assert_equals(
        g.schema.target_version(),
        2,
        'наибольший номер, а не последний зарегистрированный'
    )
end

-- Недоступный box.info — отказ, а не разрешение менять схему.
g.test_can_run_ddl_without_box_info = function()
    local allowed, reason = can_run_ddl_with(
        g.schema,
        setmetatable({}, {
            __index = function()
                error('box.info недоступен')
            end,
        })
    )

    t.assert_equals(allowed, false)
    t.assert_str_contains(reason, 'box.info недоступен')
end

-- box.info, вернувший не таблицу, — тоже отказ.
g.test_can_run_ddl_with_broken_box_info = function()
    local allowed, reason = can_run_ddl_with(g.schema, { info = 'не таблица' })

    t.assert_equals(allowed, false)
    t.assert_str_contains(reason, 'box.info недоступен')
end

-- Инстанс только для чтения без указанной причины всё равно отвергается.
g.test_can_run_ddl_read_only_without_reason = function()
    local allowed, reason = can_run_ddl_with(g.schema, { info = { ro = true } })

    t.assert_equals(allowed, false)
    t.assert_str_contains(reason, 'только для чтения')
end

-- Названная причина отказа доходит до вызывающего.
g.test_can_run_ddl_reports_reason = function()
    local _, reason = can_run_ddl_with(g.schema, { info = { ro = true, ro_reason = 'ожидание лидера' } })

    t.assert_equals(reason, 'ожидание лидера')
end

-- На инстансе с разрешённой записью схему менять можно.
g.test_can_run_ddl_when_writable = function()
    local allowed, reason = can_run_ddl_with(g.schema, { info = { ro = false } })

    t.assert_equals(allowed, true)
    t.assert_equals(reason, nil)
end

-- Без box менять схему нельзя, и причина названа.
g.test_can_run_ddl_without_box = function()
    local allowed, reason = can_run_ddl_with(g.schema, nil)

    t.assert_equals(allowed, false)
    t.assert_str_contains(reason, 'box не инициализирован')
end

-- Без box состояние схемы не прочитать, и причина названа.
g.test_status_without_box_is_a_refusal = function()
    local saved = rawget(_G, 'box')
    rawset(_G, 'box', nil)

    local status, err = g.schema.status()

    rawset(_G, 'box', saved)

    t.assert_equals(status, nil)
    t.assert_equals(
        err,
        'состояние схемы не прочитать: box не инициализирован'
    )
end
