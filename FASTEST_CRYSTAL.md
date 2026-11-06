# FASTEST_CRYSTAL — убрать отставание от C в горячих циклах

Форк компилятора Crystal с одной целью: закрыть типичный разрыв 15–40% до C
на hot loops в C-стильном коде (порты brotli.cr / freetype.cr: предаллоцированные
буферы, индексы вместо указателей, ноль аллокаций в горячем пути). Разрыв —
чисто кодогенерационный: GC (Boehm) в таких программах накладных расходов
не создаёт. Ниже — четыре фичи, закрывающие его. Общий принцип: всё это
opt-in аннотации и флаги сборки, а не новый синтаксис и не новый дефолт;
обычный код не меняется ни на символ.

Статус: **№4, №2, №3 реализованы и протестированы** (см. детали);
№1 (computed goto) — в работе.

---

## №4. Публичный `Intrinsics` + `llvm.prefetch` — ГОТОВО

`Intrinsics` — stdlib (`src/intrinsics.cr`), а не механизм компилятора:
`lib LibIntrinsics` объявляет `fun` с LLVM-именами, кодеген распознаёт их
по префиксу `llvm.`.

- [x] `llvm.prefetch` с версионной веткой (LLVM <15: `p0i8` + аргумент `rw`;
      ≥15: `p0`, без `rw`).
- [x] Обёртка-макрос `Intrinsics.prefetch(address, locality = 3, read_data = true)`:
      `locality`/`read_data` обязаны быть литералами — LLVM требует
      immarg-константы (не-литерал → понятная ошибка на макро-этапе).
- [x] `@[Primitive(:interpreter_intrinsics_prefetch)]` для `crystal i` (no-op).
- [x] Спек: `spec/std/intrinsics_prefetch_spec.cr`.

## №2. `@[NoAlias]` — аналог `restrict` — ГОТОВО

Без обещания «указатели не пересекаются» LLVM не векторизирует циклы, где
input и output читаются/пишутся вместе.

- [x] Аннотация зарегистрирована (`semantic/program.cr`); парсинг аннотаций
      аргументов в `lib fun` (`syntax/parser.cr`, `parse_fun_def`) и перенос
      в `External` (`semantic/top_level_visitor.cr`).
- [x] Кодеген ставит `noalias` на параметры (`codegen/fun.cr`, оба пути —
      def и lib fun). Не-указательный аргумент — ошибка компиляции.
- [x] Спеки: `spec/compiler/codegen/fun_spec.cr` (атрибуты проверяются
      через `LLVM::Function#attributes(index)`).

Синтаксис:

```crystal
def copy(@[NoAlias] dst : Pointer(UInt8), @[NoAlias] src : Pointer(UInt8))
lib Lib
  fun my_copy(@[NoAlias] dst : UInt8*, @[NoAlias] src : UInt8*, len : UInt64)
end
```

WARNING: ложный noalias — UB после оптимизации, как и ложный `restrict` в C.

## №3. PGO — ГОТОВО

- [x] C++-шайба `LLVMExtRunPassesWithPGO` (`src/llvm/ext/llvm_ext.cc`,
      LLVM ≥18): `PassBuilder` с `PGOOptions` (IRInstr / IRUse).
- [x] Флаги `--pgo-gen` / `--pgo-use=FILE` (CLI в `command.cr`,
      `compiler.cr`).
- [x] Линковка runtime: выбирает `libclang_rt.profile-<arch>.a` под
      мажор-версию LLVM компилятора; `-u__llvm_profile_runtime` (как clang)
      + `-z now`.
- [x] PGO-флаги в ключе биткод-кэша.
- [x] e2e-тест: gen → run → `llvm-profdata merge` → use; вывод идентичен,
      PGO-сборка быстрее инструментированной (~30% на тесте с fib).

Workflow:

```
crystal build --release --pgo-gen f.cr -o f_gen
./f_gen                                   # пишет default_%m.profraw
llvm-profdata merge -output=p.profdata default_*.profraw
crystal build --release --pgo-use=p.profdata f.cr
```

Особенности (выяснены при отладке):
- **Value profiling отключён** (`-disable-vp` в шайбе): рантайм
  профайлера портит список vnode при стартовом бёрсте инструментированных
  непрямых вызовов Crystal (файберный шедулер, воркер-потоки) — SIGSEGV в
  `__llvm_profile_instrument_target`. Ветка-веса (главный источник
  выигрыша PGO) не затронуты.
- Имя файла профайла задаёт рантайм (`default_%m.profraw`); переопределяется
  env `LLVM_PROFILE_FILE`. Отдельный аргумент в `--pgo-gen` не поддерживается:
  LLVM игнорирует `PGOOptions.ProfileFile` для output-имени (это делает
  clang-фронтенд).
- Без `--release`/`-O` PGO-флаги не действуют (кодеген пропускает optimize
  на O0).

## №1. Computed goto — диспетчер состояний на `indirectbr` — В РАБОТЕ

Интерпретатор TrueType hinting (`case @opcode` на ~200 опкодов) и декодер
brotli (`case phase`) в C едут на labels-as-values: `goto *ptr` в голову
нужного цикла, частые переходы — предсказуемый fall-through. В Crystal
каждый переход — цепочка сравнений + прыжок через голову цикла (ломается
BTB). `LLVMBlockAddress`/`LLVMBuildIndirectBr`/`LLVMAddDestination` есть в
C-API, но в биндингах Crystal их нет.

Дизайн: НЕ новый синтаксис `goto`, а аннотация `@[ComputedGoto]` на def +
пасс кодегена, распознающий паттерн `while true; case x; when <константы>`
и собирающий таблицу `blockaddress` + `indirectbr`.

- [ ] C-биндинги `LLVMBlockAddress`, `LLVMBuildIndirectBr`,
      `LLVMAddDestination` в `src/llvm/lib_llvm/core.cr` + обёртки в
      `src/llvm/builder.cr` (образец — `switch`).
- [ ] Аннотация `ComputedGoto` (паттерн `NoInline`).
- [ ] Пасс кодегена: все блоки создаются заранее, потом indirectbr-таблица
      (образцы: кодеген `while` в `codegen/codegen.cr`, switch-диспетчер
      type_id в `codegen/primitives.cr`).
- [ ] Обязательный `NoInline` для таких def (LLVM не инлайнит функции
      с address-taken блоками).
- [ ] Запрет переходов через границы rescue/ensure (EH через
      `invoke`+`landingpad` не переживёт indirectbr в/из EH-региона).
- [ ] Guard по таргету (WebAssembly не поддерживает адреса блоков);
      запрет в интерпретаторе.

Оценка: биндинги ~15–25 строк; пасс ~150–400 строк. Выигрыш: 5–15% на
пиковых циклах. Единственная фича, требующая измерений — LLVM неохотно
инлайнит функции с `indirectbr`, «магии C» автоматически не получится.

---

## Порядок работы

**№4 → №2 → №3 → №1.** Первые две — механические патчи по готовым образцам
(сделаны), их эффект можно мерить на fastest-freetype.cr и
fastest-brotli.cr. №3 сделана. №1 — дизайн + бенчмарки.

Escape analysis / ручное управление памятью осознанно не входят в план:
для C-стильного кода с предаллокацией они ничего не дают.
