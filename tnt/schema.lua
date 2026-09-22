--- Версионирование схемы спейсов: миграции для Tarantool.
---
--- В базе хранится номер версии, в коде — пронумерованные шаги. Раннер
--- догоняет базу до кода, записывая версию после каждого шага в той же
--- транзакции, что и сам шаг: так изменение либо применено целиком,
--- либо не применено вовсе.
---
--- `box.once` для этого мал: он умеет только «выполнить один раз под
--- ключом» и не знает ни про версии, ни про порядок, ни про то, что DDL
--- допустим лишь на лидере.
---
--- Два правила, которые нельзя нарушать:
---
--- 1. Отката нет. Понижение версии отвергается: DDL уезжает на реплики
---    журналом, и «откатить» его на живом кластере — значит выкатить ещё
---    один шаг вперёд.
---
--- 2. Каждый шаг обязан быть совместим с предыдущей версией кода. Инстансы
---    обновляются по одному, и схема после шага N должна читаться кодом
---    версии N-1, иначе последовательная выкатка сломается на первом же
---    инстансе.
---
--- **Шаг не уступает, и срез файбера достаётся ему целиком.** Шаг идёт
--- в транзакции, а уступка внутри транзакции memtx обрывает её («Transaction
--- has been aborted by a fiber yield»; с `memtx_use_mvcc_engine` это
--- переживает только DML, DDL — нет). Поэтому обход спейса кусками
--- с уступкой между ними — обычный приём долгой работы над спейсом — шагу
--- недоступен, и единственный предел шага — срез файбера: ядро сверяет его
--- на обращениях к box раз в тысячу и обрывает работу без уступки после
--- секунды «fiber slice is exceeded». На 3.8 это около 250 000 `replace`
--- в одной транзакции; транзакция откатывается, версия остаётся прежней.
--- Раннер даёт шагу срез целиком: перед шагом файбер уступает — срез
--- начинается заново, иначе шагу достался бы остаток после работы
--- вызывающего (шаг на четверть секунды после девяти десятых секунды
--- чужого счёта срывался через десятую долю); после шага уступает снова —
--- ни съеденный шагом срез, ни выданный ему сверх обычного вызывающему
--- не достаются. При `wal_mode = 'write'` уступает и сам `box.commit`, при
--- `none` — нет, и без второй уступки второй шаг срывался бы на срезе
--- первого. Уступки обрывают транзакцию, отсюда запрет звать раннер
--- внутри транзакции: это ошибка программиста.
---
--- Долгому шагу срез задают при регистрации:
---
---     schema.register(7, function(box)
---         for _, row in box.space.orders:pairs() do
---             box.space.orders:replace(row:update({ { '=', 'status', 'new' } }))
---         end
---     end, { slice = 30 })
---
--- Это `fiber.set_slice` на время шага: он живёт до первой уступки, то есть
--- ровно до конца шага. Цена названа вслух: пока шаг идёт, на узле не
--- работает ни один другой файбер — ни репликация, ни запросы, — а реплики
--- получают одну транзакцию на все строки. Шаг без среза, сорвавшийся
--- на нём, отказывает с подсказкой задать срез.
---
--- Не всякий, кто пишет шаги, зовёт `register` сам: приложение может
--- объявлять их списком `migrations` либо файлами каталога
--- `database/migrations`, и срез там задают таблицей вместо шага —
--- `{ step = function(box) … end, slice = 30 }`, — а регистрирует их тот,
--- кто собирает приложение. Поэтому подсказка называет обе записи:
--- у отказа один текст на всех, а `register` автору файла недоступен.
---
--- Пока раннер стоит на уступке, миграции вправе применять кто-то ещё:
--- перед шагом версия перечитывается, и ушедшая вперёд — отказ, а не
--- повторное применение шага поверх чужого.
---
--- **Журнал шагов.** Версия говорит, докуда поднята схема, но не когда
--- и кем: после выкатки на десяток узлов оператор спрашивает именно это.
--- Поэтому в той же транзакции, что шаг и версия, ложится запись журнала
--- `app_schema_steps` — номер, стенное время, имя применившего узла
--- и длительность шага. Запись в той же транзакции затем же, зачем
--- и версия: журнал, разошедшийся со схемой, врал бы о применённом.
--- `status()` сводит версию, журнал и шаги кода в одну картину; шаги,
--- применённые до журнала, в ней видны применёнными, но без времени
--- и узла — придумывать их пакет не берётся.

local clock = require('clock')
local fiber = require('fiber')
local must = require('tnt.must')
local external = require('tnt.external')

local Module = {}

--- Имя спейса с версией по умолчанию.
--- Без ведущего подчёркивания: оно зарезервировано под системные спейсы.
local DEFAULT_META_SPACE = 'app_schema_meta'

--- Ключ, под которым хранится номер версии.
local VERSION_KEY = 'schema_version'

--- Зарегистрированные шаги: номер версии → функция.
---@type table<integer, fun(box: table)>
local steps = {}

--- Срезы файбера долгих шагов: номер версии → секунды. Есть только
--- у шагов, которым срез задали; остальные идут под срезом ядра.
---@type table<integer, number>
local slices = {}

--- Имя спейса с версией. Меняется через configure().
local meta_space_name = DEFAULT_META_SPACE

--- Имя спейса журнала шагов по умолчанию.
local DEFAULT_STEPS_SPACE = 'app_schema_steps'

--- Имя спейса журнала шагов. Меняется через configure().
local steps_space_name = DEFAULT_STEPS_SPACE

--- Тексты отказов и ошибок.
---
--- Вынесены из вызовов, чтобы каждый вызов стоял одной строкой: разнесённый
--- по строкам, он оставил бы уровень у `error` одиноким числом на своей
--- строке, а такие строки мутационный гейт пропускает не глядя.
---
--- Длинный текст склеен `table.concat`, а не `..` по строкам: у операнда,
--- открывающего многострочную склейку, своей инструкции нет, и замер
--- покрытия по строкам считал бы первую строку неисполненной.
local INSIDE_TRANSACTION =
    'раннер миграций уступает управление вокруг шага и этим обрывает транзакцию: внутри транзакции его не зовут'
local SLICE_EXCEEDED = table.concat({
    'шаг %d не применён: шаг шёл без уступки дольше среза файбера (%s); ',
    'долгому шагу задают срез в секундах: register(%d, step, { slice = секунды }), ',
    'а в migrations ядра и в файле database/migrations — { step = шаг, slice = секунды } вместо шага',
})
local VERSION_MOVED =
    'шаг %d не применён: пока раннер стоял на уступке, версия в базе стала %d — миграции применяет кто-то ещё'

--- Имя узла для журнала шагов: имя из конфигурации, а без него — uuid.
---
--- Узел, поднятый без имени (голый `box.cfg`), имени не знает, а uuid
--- у него есть всегда: пустое место в журнале не назвало бы никого.
--- Имени нет — это `box.NULL`, а он истинен для `or`; сравнение с `nil`
--- его узнаёт.
---@return string
local function instance_name()
    local info = box.info

    if info.name == nil then
        return info.uuid
    end

    return info.name
end

--- Внешние средства: уступка управления, часы и имя узла.
---
--- Через внешнюю зависимость затем, чтобы проверка могла встать ровно на уступку и сделать
--- там то, что делают соседние файберы: применить миграции самой. Часы —
--- по той же причине: длительность на настоящих часах сверяется только
--- диапазоном, и ошибку единиц или знака в замере он пропускает, а часы,
--- подменённые проверкой, дают точное число. Стенные часы и имя узла
--- ложатся в журнал шагов, и подменённые дают точную запись.
local source = external.install(Module, {
    yield = fiber.yield,
    monotonic = clock.monotonic,
    realtime = clock.realtime,
    instance = instance_name,
})

---@class TntSchemaLogger
---@field info fun(message: string, fields: table|nil)
---@field warn fun(message: string, fields: table|nil)
---@field error fun(message: string, fields: table|nil)

--- Журнал. Подменяется через configure(): пакет не навязывает свой.
---@type TntSchemaLogger
local logger = {
    info = function(_message, _fields) end,
    warn = function(_message, _fields) end,
    error = function(_message, _fields) end,
}

--- Проверенное имя спейса из настроек: непустая строка.
---@param value any
---@param key string Имя настройки — для текста ошибки
---@return string
local function space_name(value, key)
    if type(value) ~= 'string' or value == '' then
        error(('%s должен быть непустой строкой'):format(key), 3)
    end

    return value
end

--- Настраивает раннер.
---@param opts { meta_space: string|nil, steps_space: string|nil, logger: TntSchemaLogger|nil }|nil
function Module.configure(opts)
    opts = opts or {}

    if opts.meta_space ~= nil then
        meta_space_name = space_name(opts.meta_space, 'meta_space')
    end

    if opts.steps_space ~= nil then
        steps_space_name = space_name(opts.steps_space, 'steps_space')
    end

    if opts.logger ~= nil then
        logger = opts.logger
    end
end

--- Имя спейса с версией.
---@return string
function Module.meta_space_name()
    return meta_space_name
end

--- Имя спейса журнала шагов.
---@return string
function Module.steps_space_name()
    return steps_space_name
end

---@class TntSchemaStepOptions
---@field slice number|nil Срез файбера на время шага, секунды: шагу, которому не хватает секунды ядра

--- Регистрирует шаг миграции.
---@param version integer Версия, до которой поднимает шаг
---@param step fun(box: table) Что сделать; получает box
---@param opts TntSchemaStepOptions|nil
function Module.register(version, step, opts)
    if type(version) ~= 'number' or version ~= math.floor(version) or version < 1 then
        error('версия шага должна быть натуральным числом')
    end

    if type(step) ~= 'function' then
        error(('шаг %d должен быть функцией'):format(version))
    end

    must.optional.options(opts, 'настройки шага', { slice = '?positive' })

    if steps[version] ~= nil then
        error(('шаг %d уже зарегистрирован'):format(version))
    end

    steps[version] = step
    slices[version] = (opts or {}).slice
end

--- Наибольшая зарегистрированная версия — до неё раннер и поднимает схему.
---@return integer
function Module.target_version()
    ---@type integer
    local target = 0

    -- Наибольшее — `math.max`, а не своим сравнением: версии различны,
    -- и у `version > target` мутант `>=` не отличить ничем.
    for version in pairs(steps) do
        target = math.max(target, math.floor(version))
    end

    return target
end

--- Настроен ли box: без него ни менять схему, ни читать её нечем.
---@return boolean ready
---@return table|string info `box.info` либо причина, почему его нет
local function box_ready()
    if rawget(_G, 'box') == nil then
        return false, 'box не инициализирован'
    end

    local ok, info = pcall(function()
        return box.info
    end)

    if not ok or type(info) ~= 'table' then
        return false, 'box.info недоступен'
    end

    return true, info
end

--- Можно ли менять схему на этом инстансе.
--- DDL исполняется только там, где разрешена запись; реплики получают
--- изменения журналом.
---@return boolean allowed
---@return string|nil reason
function Module.can_run_ddl()
    local ready, info = box_ready()

    if not ready then
        return false, info --[[@as string]]
    end

    if info.ro == true then
        return false, info.ro_reason or 'инстанс только для чтения'
    end

    return true, nil
end

--- Разметка спейса с версией: ключ и значение строками.
local META_FORMAT = {
    { name = 'key', type = 'string' },
    { name = 'value', type = 'string' },
}

--- Разметка журнала шагов: номер, когда, кем и сколько шёл.
local STEPS_FORMAT = {
    { name = 'version', type = 'unsigned' },
    { name = 'applied_at', type = 'number' },
    { name = 'instance', type = 'string' },
    { name = 'elapsed_ms', type = 'number' },
}

--- Разворачивает спейс раннера: с версией либо с журналом шагов.
---
--- Спейс реплицируемый, и это принципиально: шаги выполняются на лидере,
--- их результат уезжает на реплики журналом. Если бы версия хранилась
--- локально, реплика получила бы изменённые данные, не увидела новую
--- версию и попыталась применить тот же шаг повторно; журнал шагов
--- на реплике без записей не назвал бы ни времени, ни узла.
---@param name string
---@param format table Разметка; ключ — первое поле
---@return table space
local function ensure_space(name, format)
    local existing = box.space[name]
    if existing ~= nil then
        return existing
    end

    local space = box.schema.space.create(name, { format = format })

    space:create_index('primary', {
        parts = { { field = format[1].name, type = format[1].type } },
    })

    return space
end

--- Текущая версия схемы, записанная в базе.
---@return integer
function Module.current_version()
    local space = box.space[meta_space_name]
    if space == nil then
        return 0
    end

    local row = space:get(VERSION_KEY)
    if row == nil then
        return 0
    end

    ---@type integer
    local version = math.floor(tonumber(row.value) or 0)

    return version
end

--- Строит список шагов от одной версии до другой.
---@param from integer
---@param to integer
---@return integer[]|nil plan
---@return string|nil err
function Module.plan(from, to)
    if type(from) ~= 'number' or type(to) ~= 'number' then
        return nil, 'версии должны быть числами'
    end

    if to < from then
        return nil, ('понижение версии с %d до %d недопустимо'):format(from, to)
    end

    local planned = {}

    for version = from + 1, to do
        if steps[version] == nil then
            return nil, ('шаг %d не зарегистрирован'):format(version)
        end

        table.insert(planned, version)
    end

    return planned, nil
end

--- Текст отказа шага: срыв на срезе файбера получает подсказку.
---@param version integer
---@param failure any Что бросил шаг
---@return string
local function step_failure(version, failure)
    -- `box.error.is` в аннотациях ядра не описан.
    ---@diagnostic disable-next-line: undefined-field
    if box.error.is(failure) and failure.type == 'FiberSliceIsExceeded' then
        return SLICE_EXCEEDED:format(version, tostring(failure), version)
    end

    return ('шаг %d не применён: %s'):format(version, tostring(failure))
end

--- Применяет один шаг: транзакция между двумя уступками.
---
--- Шаг, запись журнала и запись версии идут одной транзакцией: иначе
--- падение между ними оставило бы схему изменённой, а версию — старой,
--- и следующий запуск применил бы шаг повторно.
---@param spaces { meta: table, steps: table } Спейсы с версией и журналом
---@param version integer
---@param started number Начало шага по монотонным часам
---@return boolean ok
---@return string|number err Отказ либо длительность шага в миллисекундах
local function apply_step(spaces, version, started)
    -- Уступка перед шагом: срез файбера начинается заново, и шагу
    -- достаётся он целиком, а не остаток после работы вызывающего.
    source().yield()

    -- За уступкой миграции мог применить кто-то ещё: шаг поверх чужого
    -- вернул бы версию назад.
    local found = Module.current_version()
    if found ~= version - 1 then
        return false, VERSION_MOVED:format(version, found)
    end

    -- Срез шага живёт до первой уступки — ровно до конца шага.
    if slices[version] ~= nil then
        fiber.set_slice(slices[version])
    end

    -- Без начального значения: при отказе длительность не нужна, а при
    -- удаче её задаёт шаг.
    local elapsed_ms

    local ok, err = pcall(function()
        box.begin()
        steps[version](box)

        -- Длительность — до записи журнала: она ложится в журнал той же
        -- транзакцией, а фиксация с уступкой после неё — уже не шаг.
        elapsed_ms = (source().monotonic() - started) * 1000
        spaces.steps:replace({ version, source().realtime(), source().instance(), elapsed_ms })
        spaces.meta:replace({ VERSION_KEY, tostring(version) })
        box.commit()
    end)

    if not ok then
        pcall(box.rollback)
    end

    -- Уступка после шага: ни съеденный шагом срез, ни выданный ему сверх
    -- обычного вызывающему не достаются. При `wal_mode = 'write'` уступил
    -- бы и commit, при `none` — никто, и следующий шаг шёл бы на остатке.
    source().yield()

    if not ok then
        logger.error('шаг миграции не применён', { version = version, err = tostring(err) })

        return false, step_failure(version, err)
    end

    return true, elapsed_ms --[[@as number]]
end

--- Применяет все неприменённые шаги.
---
--- Уступает управление вокруг каждого шага, поэтому внутри транзакции
--- не зовётся: уступка оборвала бы её, и это ошибка программиста.
---@return { from: integer, to: integer, applied: integer[], elapsed_ms: number }|nil result
---@return string|nil err
function Module.upgrade()
    local allowed, reason = Module.can_run_ddl()
    if not allowed then
        return nil, ('менять схему нельзя: %s'):format(tostring(reason))
    end

    if box.is_in_txn() then
        error(INSIDE_TRANSACTION, 2)
    end

    local spaces = {
        meta = ensure_space(meta_space_name, META_FORMAT),
        steps = ensure_space(steps_space_name, STEPS_FORMAT),
    }
    local from = Module.current_version()
    local to = Module.target_version()

    if from > to then
        return nil,
            ('в базе версия %d, а в коде %d: понижение версии недопустимо'):format(
                from,
                to
            )
    end

    local planned, plan_error = Module.plan(from, to)
    if planned == nil then
        return nil, plan_error
    end

    if #planned == 0 then
        return { from = from, to = to, applied = {}, elapsed_ms = 0 }
    end

    logger.info('применение миграций', { from = from, to = to, steps = #planned })

    local applied = {}
    local started = source().monotonic()

    for _, version in ipairs(planned) do
        local ok, outcome = apply_step(spaces, version, source().monotonic())

        if not ok then
            return nil, outcome --[[@as string]]
        end

        table.insert(applied, version)
        logger.info('шаг применён', { version = version, elapsed_ms = outcome })
    end

    return {
        from = from,
        to = to,
        applied = applied,
        elapsed_ms = (source().monotonic() - started) * 1000,
    }
end

---@class TntSchemaStep
---@field version integer Номер шага — версия, до которой он поднимает схему
---@field applied boolean Применён: версия в базе не ниже номера
---@field registered boolean Шаг есть в коде
---@field applied_at number|nil Когда применён: секунды эпохи по стенным часам применившего узла
---@field instance string|nil Каким узлом применён: имя, а без имени — uuid
---@field elapsed_ms number|nil Сколько шёл шаг, миллисекунды

---@class TntSchemaStatus
---@field instance string Узел, который ответил: версия и журнал — его
---@field current integer Версия в базе
---@field target integer Версия в коде
---@field steps TntSchemaStep[] Шаги по номерам

--- Состояние схемы: какие шаги применены, какие ждут, когда и кем.
---
--- Применённым шаг считается по версии в базе, как его считает сам
--- раннер; журнал добавляет время, узел и длительность. Список идёт
--- с первого шага до наибольшего из кода и журнала: пропуск в нумерации
--- кода и шаг, которого в коде уже нет, видны в нём строкой. Запись
--- журнала выше версии в базе не показывается — версию правили руками,
--- и шаг применится заново. Читает и там, где писать нельзя: на реплике
--- видны шаги, применённые лидером.
---@return TntSchemaStatus|nil status
---@return string|nil err
function Module.status()
    local ready, reason = box_ready()

    if not ready then
        return nil, ('состояние схемы не прочитать: %s'):format(reason)
    end

    local current = Module.current_version()
    local last = Module.target_version()
    local history = box.space[steps_space_name]
    local recorded = {}

    if history ~= nil then
        for _, row in history:pairs() do
            if row.version <= current then
                recorded[row.version] = row
                last = math.max(last, row.version)
            end
        end
    end

    local entries = {}

    for version = 1, last do
        local row = recorded[version]

        table.insert(entries, {
            version = version,
            applied = version <= current,
            registered = steps[version] ~= nil,
            applied_at = row and row.applied_at,
            instance = row and row.instance,
            elapsed_ms = row and row.elapsed_ms,
        })
    end

    return { instance = source().instance(), current = current, target = Module.target_version(), steps = entries }
end

return Module
