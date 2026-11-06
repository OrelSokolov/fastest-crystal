# FASTEST_CRYSTAL — убрать отставание от C в горячих циклах

Форк компилятора Crystal с одной целью: закрыть типичный разрыв 15–40% до C
на hot loops в C-стильном коде (порты brotli.cr / freetype.cr: предаллоцированные
буферы, индексы вместо указателей, ноль аллокаций в горячем пути). Разрыв —
чисто кодогенерационный: GC (Boehm) в таких программах накладных расходов
не создаёт. Ниже — четыре фичи, закрывающие его, с точками входа в этом
форке. Порядок внедрения — по соотношению усилие/выигрыш.

Общий принцип: всё это opt-in аннотации и флаги сборки, а не новый синтаксис
и не новый дефолт. Обычный код не меняется ни на символ.

---

## №4. Публичный `Intrinsics` + `llvm.prefetch` (компилятор не трогается)

`Intrinsics` — это stdlib (`src/intrinsics.cr`), а не механизм компилятора:
`lib LibIntrinsics` объявляет `fun` с LLVM-именами (`"llvm.memcpy..."`),
кодеген уже распознаёт их по префиксу имени (`src/compiler/crystal/codegen/ast.cr`).

Доделать:
- [ ] Обнародовать обёртки над уже объявленными интринзиками (модуль
  `Intrinsics` уже публичный — добавить `prefetch`, недостающие обёртки).
- [ ] `llvm.prefetch` с версионной веткой: до LLVM 15 —
      `llvm.prefetch.p0i8(ptr, read, rw, locality, cache)`,
      с LLVM 15 — `llvm.prefetch.p0(ptr, read, locality, cache)`
      (аргумент `rw` удалён, мангля сменился). Паттерн ветвления по
      `Crystal::LLVM_VERSION` уже есть в этом же файле.
- [ ] Обёртка `Intrinsics.prefetch(address, locality = 3, read_data = true)`.
- [ ] `@[Primitive(:interpreter_intrinsics_prefetch)]` для `crystal i`.

Оценка: ~20–40 строк. Выигрыш: единицы процентов.

## №2. `@[NoAlias]` — аналог `restrict` (главный пункт для encoder'ов)

Без обещания «указатели не пересекаются» LLVM не векторизирует циклы, где
input и output читаются/пишутся вместе. Вся инфраструктура уже есть:
`LLVM::Attribute::NoAlias` в enum, `Function#add_attribute` на параметр,
аннотации на аргументах def уже парсятся и переживают клонирование.

Доделать:
- [ ] Зарегистрировать аннотацию `NoAlias` (по образцу `NoInline`:
      `semantic/program.cr`, `semantic/top_level_visitor.cr`,
      `semantic/ast.cr`).
- [ ] В цикле выставления атрибутов параметров (`codegen/fun.cr`, цикл
      `args.each` с `add_attribute(attr, i + offset + 1)`) ставить
      `NoAlias`, если аргумент аннотирован и его тип — указатель
      (`Pointer`, `Slice`). Для не-указательных — ошибка компиляции:
      верификатор LLVM требует `noalias` только на pointer-типах.
- [ ] Разрешить `@[NoAlias]` на `fun` в `lib` (главной use-case —
      C-байндинги вроде memcpy).
- [ ] Спеки: атрибут виден через `Function#attributes(index)`.

Синтаксис: `def copy(@[NoAlias] dst : Pointer(UInt8), @[NoAlias] src : Pointer(UInt8))`.

Оценка: ~25–40 строк в 3 файлах. Выигрыш: разблокировка векторизации.

## №3. PGO — прокинуть LLVM-профилирование в `crystal build`

`--release` сегодня — это просто `default<O3>` через `LLVM.run_passes`.
C-API не умеет передавать PGO-профиль в PassBuilderOptions, поэтому нужен
C++ в существующей шайбе `src/llvm/ext/llvm_ext.cc` (прецедент —
`LLVMExt*`-функции): обёртка над `llvm::PassBuilder::runPasses(..., PGOOptions)`.

Доделать:
- [ ] `LLVMExtRunPassesWithPGO(mod, passes, tm, action, profile_file)` в
      `llvm_ext.cc`, ограничить по версии LLVM (≥ 15) через
      `IS_LT_150`-флаги; декларация в `src/llvm/lib_llvm_ext.cr`.
- [ ] Флаги CLI: `--pgo-gen` (instrument: pass-строка
      `function(pgo-instr-gen),default<Ox>` + линковка
      `libclang_rt.profile`) и `--pgo-use=FILE` (чтение `.profdata`).
- [ ] Прокидывание из `Crystal::Compiler#optimize` (место вызова
      `LLVM.run_passes`).
- [ ] Инвалидация биткод-кэша: в ключ кэша добавить хэш профиля.
- [ ] Понятная деградация, если runtime/profile не найден.

Оценка: ~150–250 строк (шайба + CLI + кэш). Выигрыш: 10–20% на ветвистом
коде — крупнейший одиночный источник отставания.

## №1. Computed goto — диспетчер состояний на `indirectbr`

Интерпретатор TrueType hinting (`case @opcode` на ~200 опкодов) и декодер
brotli (`case phase`) в C едут на labels-as-values: `goto *ptr` в голову
нужного цикла, частые переходы — предсказуемый fall-through. В Crystal
каждый переход — цепочка сравнений + прыжок через голову цикла (ломается
BTB). `LLVMBlockAddress`/`LLVMBuildIndirectBr`/`LLVMAddDestination` есть в
C-API во всех поддерживаемых версиях, но в биндингах Crystal их нет.

Дизайн: НЕ новый синтаксис `goto`, а аннотация `@[ComputedGoto]` на def +
скрытый пасс кодегена, распознающий паттерн
`while true; case x; when <Int-константы>` и собирающий таблицу
`blockaddress` + `indirectbr`.

Доделать:
- [ ] C-биндинги `LLVMBlockAddress`, `LLVMBuildIndirectBr`,
      `LLVMAddDestination` в `src/llvm/lib_llvm/core.cr` + обёртки в
      `src/llvm/builder.cr` (образец — `switch`).
- [ ] Аннотация `ComputedGoto` (паттерн `NoInline`).
- [ ] Пасс кодегена `codegen/computed_goto.cr`: по образцу `while`
      (`codegen/codegen.cr`) и switch-диспетчера type_id
      (`codegen/primitives.cr`) — все блоки создаются заранее, потом
      indirectbr-таблица.
- [ ] Обязательный `NoInline` для таких def (LLVM не инлайнит функции
      с address-taken блоками).
- [ ] Запрет переходов через границы rescue/ensure (EH через
      `invoke`+`landingpad` не переживёт indirectbr в/из EH-региона).
- [ ] Guard по таргету (WebAssembly не поддерживает адреса блоков);
      запрет в интерпретаторе.

Оценка: биндинги ~15–25 строк; пасс ~150–400 строк. Выигрыш: 5–15% на
пиковых циклах декодера/интерпретатора. Единственная фича, требующая
дизайна и измерений — LLVM исторически неохотно инлайнит функции с
`indirectbr`, «магии C» автоматически не получится.

---

## Порядок работы

**№4 → №2 → №3 → №1.** Первые две — механические патчи по готовым
образцам (дни), их эффект можно сразу мерить на fastest-freetype.cr и
fastest-brotli.cr. №3 — недели, основной риск — мультиверсионность LLVM
в C++-шайбе. №1 — дизайн + бенчмарки.

Escape analysis / ручное управление памятью осознанно не входят в план:
для C-стильного кода с предаллокацией они ничего не дают.
