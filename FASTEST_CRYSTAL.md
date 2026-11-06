# FASTEST_CRYSTAL — убрать отставание от C в горячих циклах

Форк компилятора Crystal с одной целью: закрыть типичный разрыв 15–40% до C
на hot loops в C-стильном коде (порты brotli.cr / freetype.cr: предаллоцированные
буферы, индексы вместо указателей, ноль аллокаций в горячем пути). Разрыв —
чисто кодогенерационный: GC (Boehm) в таких программах накладных расходов
не создаёт. Ниже — четыре фичи, закрывающие его. Общий принцип: всё это
opt-in аннотации и флаги сборки, а не новый синтаксис и не новый дефолт;
обычный код не меняется ни на символ.

Статус: **все четыре фичи реализованы и протестированы** (см. детали).
№1 реализована как switch-диспетчер (эквивалент jump table); честные
замеры и ограничения — в её секции.

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

Дизайн (реализовано): аннотация `@[ComputedGoto]` на def + пасс в
`visit(While)`, который распознаёт endless-цикл с диспетчерской цепочкой
`state == <int>` (во что разворачивается `case state; when 0...`, включая
форму `0 === state` от literal expander'а) и кодегенит её как один LLVM
`switch` (jump table) вместо цепочки сравнений. Выражения тела до цепочки
выполняются перед диспетчем (preamble), после — в общем postamble-блоке;
`break`/`next` работают через обычные Phi/context-механизмы, EH-границы
не пересекаются (никакого `indirectbr` — переключение через switch, для
него нет ограничений ни EH, ни WebAssembly, ни интерпретатора).

- [x] Аннотация `ComputedGoto` (регистрация, обработка, флаг на Def,
      копирование при клонировании — паттерн `NoInline`).
- [x] Пасс `try_computed_goto_dispatch` (`codegen/codegen.cr`): матчит
      обе формы сравнения; не-матч — тихий fallback на обычный кодеген.
- [x] Спеки: `spec/compiler/codegen/computed_goto_spec.cr` (switch в IR,
      отсутствие switch без аннотации, эквивалентность семантики).
- [x] e2e: интерпретаторный бенчмарк (8 опкодов, случайный поток) — вывод
      идентичен обычной сборке.

Честные результаты замеров (x86_64, LLVM 20):
- На микробенчмарке с 8 опкодами (случайный порядок) скорость равна
  цепочке сравнений: LLVM и с jump table, и с цепочкой упирается в
  предсказание переходов; при идеально предсказуемом потоке — тоже parity
  (упирается в сериальную зависимость аккумулятора).
- Реальный выигрыш ожидается на больших таблицах (~200 опкодов у
  интерпретатора TrueType hinting): цепочка сравнений деградирует
  линейно (~N/2 сравнений), jump table — константа. Требует замеров на
  fastest-freetype.cr.
- LLVM пост-оптимизация может развернуть switch обратно для маленьких
  таблиц (заметлено при 8 кейсах) — это нормально и безопасно.

Отдельно: `blockaddress`/`indirectbr` (настоящий per-handler threaded
dispatch как в C) не потребовались — в Crystal-структуре цикла диспетчер
всё равно один на голову цикла, выигрыш per-handler ветвления достижим
только при перестройке исходника. Биндинги при необходимости добавляются
тривиально (`LLVMBlockAddress` и др. есть в C-API).

---

## Порядок работы

**№4 → №2 → №3 → №1.** Первые две — механические патчи по готовым образцам
(сделаны), их эффект можно мерить на fastest-freetype.cr и
fastest-brotli.cr. №3 сделана. №1 — дизайн + бенчмарки.

Escape analysis / ручное управление памятью осознанно не входят в план:
для C-стильного кода с предаллокацией они ничего не дают.
