# tnt-schema

Миграции схемы спейсов Tarantool: в базе хранится номер версии, в коде —
пронумерованные шаги, и раннер догоняет базу до кода. Шаг и запись новой
версии идут одной транзакцией: изменение либо применено целиком, либо
не применено вовсе.

```lua
local schema = require('tnt.schema')

schema.register(1, function(box)
    local orders = box.schema.space.create('orders', {
        format = { { name = 'id', type = 'unsigned' }, { name = 'status', type = 'string' } },
    })
    orders:create_index('primary', { parts = { { field = 'id', type = 'unsigned' } } })
end)

schema.register(2, function(box)
    box.space.orders:create_index('by_status', { parts = { { field = 'status', type = 'string' } }, unique = false })
end)

local report, err = schema.upgrade()   --> { from = 0, to = 2, applied = { 1, 2 }, elapsed_ms = 3.4 }
```

Зависимости: `tnt-must` и `tnt-external`.

## Зачем

- **Версия и шаг — одна транзакция.** Падение между изменением схемы
  и записью версии оставило бы схему новой, а версию старой, и следующий
  запуск применил бы шаг повторно. Упавший шаг откатывается целиком.
- **Порядок и полнота проверяются до первого шага.** Пропущенный номер,
  версия в базе новее кода, инстанс только для чтения — отказ, пока схема
  ещё не тронута.
- **Отката нет.** DDL уезжает на реплики журналом; понижение версии
  отвергается, а «откатить» — значит выкатить ещё один шаг вперёд.
- **Шагу достаётся весь срез файбера.** Шаг в транзакции не уступает;
  раннер уступает перед ним и после него, а долгому шагу срез задают
  при регистрации: `register(3, step, { slice = 30 })`.
- **Журнал шагов.** В той же транзакции, что шаг и версия, ложится
  запись: когда, каким узлом и сколько шёл шаг. `status()` сводит
  версию, журнал и шаги кода: что применено, что ждёт, чего нет в коде.

## Установка

```sh
tt rocks install tnt-schema --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-schema.git
cd tnt-schema && tt rocks install --server=https://tnt-skein.github.io/rocks --only-deps tnt-schema-scm-1.rockspec && tt rocks make
```

## Как пользоваться

| Функция | Что делает |
|---|---|
| `register(version, step, opts)` | кладёт шаг в реестр; `opts.slice` — срез файбера на время шага, секунды |
| `upgrade()` | применяет неприменённые шаги; отчёт `{ from, to, applied, elapsed_ms }` либо `nil, err` |
| `status()` | состояние схемы узла: `{ instance, current, target, steps }`, у шага — `applied`, `registered`, `applied_at`, `instance`, `elapsed_ms`; либо `nil, err` |
| `current_version()` | версия в базе; 0, пока спейса с версией нет |
| `target_version()` | наибольший зарегистрированный шаг |
| `plan(from, to)` | список шагов между версиями без применения |
| `can_run_ddl()` | можно ли менять схему на этом инстансе, и почему нет |
| `configure({ meta_space, steps_space, logger })` | имена спейсов с версией (`app_schema_meta`) и журналом шагов (`app_schema_steps`), журнал сообщений |
| `meta_space_name()`, `steps_space_name()` | действующие имена спейсов |
| `_set_source({ yield, monotonic, realtime, instance })` | подмена уступки, часов и имени узла в проверках |

Отказ `upgrade` — пара `nil, err`: на инстансе только для чтения,
при понижении версии, при пропуске в нумерации, когда шаг бросил или
когда сосед поднял схему за время уступки. Вызов внутри транзакции —
исключение: уступка вокруг шага оборвала бы транзакцию вызывающего.

Журнал пакет не навязывает и по умолчанию молчит; `logger` — таблица
с `info`, `warn`, `error`, каждая берёт сообщение и таблицу полей.

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (64 проверки, 153 мутанта
в одном модуле). Применение проверяется на настоящем узле, срез файбера —
на живом ядре.

## Документ

Полное описание с обоснованием решений: [docs/schema.md](docs/schema.md).

## Лицензия

MIT.
