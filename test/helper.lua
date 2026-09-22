--- Общие средства проверок пакета.
---
--- Раннер грузится из исходника с диска, а не через `require`: у Tarantool
--- свой загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must` и `tnt.external` — берутся из `.rocks` обычным
--- `require`: проверяется раннер, а не они.
---
--- Оснастка проверок — загрузчик исходников, часы с работой без уступки,
--- временный узел — лежит в `test/testing/` и грузится так же, файлами:
--- до неё загрузчика исходников нет.

local fio = require('fio')

--- Оснастка проверок в порядке зависимостей: узел берёт файлы и загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

local sources = package.loaded['tnt.testing.sources']
local node = package.loaded['tnt.testing.node']

--- Оснастка под теми именами, которыми её зовут проверки.
local testing = {
    load_sources = sources.load,
    unload_sources = sources.unload,
    modules = sources.merge,
    absolute = sources.absolute,
    start_node = node.start,
    stop_node = node.stop,
}

local helper = {}

--- Минимальная арена: тестам схемы данные не нужны, нужен только
--- работающий box с разрешённой записью.
local MEMTX_MEMORY = 32 * 1024 * 1024

--- Раннер из исходника; зависимости он берёт из `.rocks` сам.
helper.MODULES = {
    { name = 'tnt.schema', path = 'tnt/schema.lua' },
}

--- Что узел берёт сверх раннера: загрузчик исходников оснастки — им узел
--- собирает раннер заново перед каждой проверкой — и работу без уступки.
---
--- Функцию на узел не передать: туда уходит только тело `exec`, и снаружи
--- оно взять ничего не может. Поэтому узел берёт те же модули оснастки
--- исходниками, а не держит свои копии загрузки и работы без уступки.
local ON_NODE = testing.modules({
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
}, helper.MODULES)

--- Загружает раннер из исходников с чистым набором шагов.
---@return table schema
function helper.load_schema()
    return testing.load_sources(helper.MODULES, 'tnt.schema')
end

--- Убирает исходники раннера: следующая проверка грузит его заново.
function helper.unload_schema()
    testing.unload_sources(helper.MODULES)
end

--- Поднимает инстанс для тестов схемы: узел оснастки, под строгим
--- режимом глобалов.
---@return table server
function helper.start_instance()
    return testing.start_node({ modules = ON_NODE, box_cfg = { memtx_memory = MEMTX_MEMORY } })
end

--- Останавливает инстанс и убирает его каталог.
---@param server table
function helper.stop_instance(server)
    testing.stop_node(server)
end

--- Ставит набору узел: один на набор, чистая схема перед каждой проверкой.
---@param g table Группа luatest; узел ложится в `g.server`
function helper.serve(g)
    g.before_all(function()
        g.server = helper.start_instance()
    end)

    g.after_all(function()
        helper.stop_instance(g.server)
    end)

    -- Каждый тест начинает с чистой схемы и пустого набора шагов.
    g.before_each(function()
        helper.prepare(g.server)
    end)
end

--- Готовит инстанс к тесту: чистая схема, раннер из исходников в `_G.schema`.
---
--- Раннер собирается заново тем же загрузчиком оснастки, что и в процессе
--- проверок, — узел взял его исходником при подъёме. `_G.reload_schema`
--- собирает ещё один экземпляр со своим набором шагов: так проверка
--- поднимает узел «предыдущей версией приложения».
---@param server table
function helper.prepare(server)
    server:exec(function(modules)
        local sources_on_node = require('tnt.testing.sources')

        rawset(_G, 'reload_schema', function()
            return sources_on_node.load(modules, 'tnt.schema')
        end)

        rawset(_G, 'schema', _G.reload_schema())

        for _, name in ipairs({ 'app_schema_meta', 'app_schema_steps', 'probe', 'probe_two' }) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end

        local fiber = require('fiber')

        -- Работа без уступки на заданное время: так вызывающий съедает
        -- срез файбера, а шаг становится длиннее среза. Длительность —
        -- по настоящим часам ядра, как у оснастки в процессе проверок.
        rawset(_G, 'spin', require('tnt.testing.clock').work_without_yielding)

        -- Запускает работу в своём файбере с коротким срезом: срез ставится
        -- маленьким, чтобы не наполнять журнал на секунды счёта. Файбер
        -- свой и незащищённый, как у такта; брошенное отдаётся вызывающему.
        rawset(_G, 'with_slice', function(slice, work)
            local outcome

            local worker = fiber.new(function()
                ---@diagnostic disable-next-line: undefined-field
                fiber.self():set_max_slice(slice)
                fiber.yield()
                outcome = work()
            end)

            worker:set_joinable(true)

            local ok, failure = worker:join()
            assert(ok, failure)

            return outcome
        end)

        -- Спейс для шагов, перебирающих данные: тысяча с половиной строк —
        -- больше тысячи обращений к box, на которых ядро сверяет срез.
        rawset(_G, 'fill_probe', function()
            local space = box.schema.space.create('probe', { format = { { name = 'id', type = 'unsigned' } } })
            space:create_index('pk', { parts = { { field = 'id', type = 'unsigned' } } })

            box.begin()
            for id = 1, 1500 do
                space:insert({ id })
            end
            box.commit()

            return space
        end)

        -- Шаг, который проходит по всему probe без уступки: перед обходом
        -- работает `busy` секунд, чтобы съесть срез до обращений к box.
        rawset(_G, 'walking_step', function(busy)
            return function(box_module)
                _G.spin(busy)

                for _, row in box_module.space.probe:pairs() do
                    box_module.space.probe:replace({ row.id })
                end
            end
        end)

        -- Второй шаг под коротким срезом. Спейс с версией развёрнут первым
        -- шагом заранее: иначе его создание уступило бы само, и проверка
        -- среза ничего не доказывала бы. `before` — работа вызывающего
        -- перед подъёмом, в том же файбере.
        rawset(_G, 'second_step_under_slice', function(slice, step, opts, before)
            _G.fill_probe()
            _G.schema.register(1, function() end)
            assert(_G.schema.upgrade())
            _G.schema.register(2, step, opts)

            return _G.with_slice(slice, function()
                if before ~= nil then
                    before()
                end

                local report, err = _G.schema.upgrade()

                return {
                    report = report,
                    err = err,
                    version = _G.schema.current_version(),
                    in_txn = box.is_in_txn(),
                    rows = box.space.probe:len(),
                }
            end)
        end)
    end, { testing.absolute(helper.MODULES) })
end

return helper
