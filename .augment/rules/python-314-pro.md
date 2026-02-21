---
type: "agent_requested"
description: "Modern Python 3.14+ Best Practices"
---

# Modern Python 3.14+ Best Practices for 2025-Ready Development

Python 3.14 represents a watershed release with **free-threaded builds officially supported** (no longer experimental), **template strings** for secure interpolation, **deferred annotation evaluation** eliminating forward reference issues, and a maturing **JIT compiler**. This guide synthesizes authoritative sources to provide actionable rules for production-ready Python development in 2025.

---

## New syntax and features

### Template strings (t-strings) replace f-strings for secure interpolation

**Rule:** Use t-strings when you need to intercept, validate, or transform interpolated values before rendering; use f-strings for immediate string output.

T-strings (PEP 750) evaluate to a `Template` object rather than a string, providing structured access to static parts and interpolation values *before* combination. This enables secure HTML/SQL rendering, structured logging, and domain-specific languages. F-strings remain ideal when processing isn't needed.

```python
from string.templatelib import Template, Interpolation
import html as html_module

def safe_html(template: Template) -> str:
    """Escape all interpolated values for XSS prevention."""
    parts = []
    for item in template:
        if isinstance(item, Interpolation):
            parts.append(html_module.escape(str(item.value)))
        else:
            parts.append(item)
    return "".join(parts)

# Safe: XSS attack prevented
evil = "<script>alert('xss')</script>"
result = safe_html(t"<p>{evil}</p>")  # Escapes the script tags

# Access template components
name, value = "World", 42
tmpl = t"Hello {name}, value: {value:.2f}"
tmpl.strings       # ('Hello ', ', value: ', '')
tmpl.values        # ('World', 42)
tmpl.interpolations[1].format_spec  # '.2f'
```

**When to deviate:** Use f-strings for simple interpolation where security processing isn't needed. T-strings have no `__str__()` method—you must write processing code. T-strings cannot combine with f-strings (`ft"..."` is invalid).

*Source: PEP 750 – Template Strings, peps.python.org (2025-04); What's New in Python 3.14, docs.python.org (2025-10)*

---

### Deferred annotation evaluation eliminates forward references

**Rule:** Remove string quotes from forward references—Python 3.14's deferred evaluation handles them automatically. Use `annotationlib.get_annotations()` for runtime inspection.

Annotations are no longer evaluated at definition time but stored in `__annotate__` functions and evaluated only when accessed. This eliminates circular reference issues without stringized annotations, improves startup performance, and allows referencing names defined later in the module.

```python
# Python 3.14: No quotes needed for forward references
class Node:
    def __init__(self, value: int, next: Node | None = None):  # Works!
        self.value = value
        self.next = next

# Runtime inspection with annotationlib
from annotationlib import get_annotations, Format
get_annotations(Node.__init__, format=Format.VALUE)
# {'value': <class 'int'>, 'next': Node | None, 'return': None}

# For undefined names, use FORWARDREF format
get_annotations(func, format=Format.FORWARDREF)  # Returns proxy objects
get_annotations(func, format=Format.STRING)      # Returns source text
```

**Migration from `from __future__ import annotations`:** Remove the import—it now emits `DeprecationWarning` and will be removed. Existing code using `typing.get_type_hints()` or `inspect.get_annotations()` continues to work.

**When to deviate:** Walrus operator (`:=`), `yield`, and `await` are disallowed in annotations. Class-level annotations referencing class variables now work correctly.

*Source: PEP 649/749 – Deferred Evaluation Of Annotations, peps.python.org (2025); What's New in Python 3.14, docs.python.org (2025-10)*

---

### New REPL features improve interactive development

**Rule:** Leverage PyREPL's multiline editing, paste mode (F3), and history browser (F2); set `PYTHON_BASIC_REPL=1` only when debugging REPL-specific issues.

Python 3.13 introduced a new REPL with multiline editing, colored output, and block-level history. Python 3.14 adds **syntax highlighting** and **import autocompletion**. Direct commands work without parentheses (`exit`, `quit`, `help`).

- **F1**: Interactive help with separate history
- **F2**: History browser (code only, no prompts/output)
- **F3**: Paste mode for large code blocks with blank lines
- **Tab**: Import autocompletion (`import pa<Tab>` → `pathlib`, `pdb`...)

**Environment variables:** `PYTHON_COLORS=0` or `NO_COLOR=1` disables colors; `FORCE_COLOR=1` forces them.

*Source: PEP 762 – REPL-acing the default REPL, peps.python.org (2025); What's New in Python 3.13/3.14, docs.python.org*

---

### Improved error messages guide debugging

**Rule:** Let Python's enhanced error messages guide you—they now suggest typo corrections, highlight problem locations, and provide context-aware hints. Enable colored output for best readability.

```python
>>> whille True:
    whille True:
    ^^^^^^
SyntaxError: invalid syntax. Did you mean 'while'?

>>> s = set()
>>> s.add({'pages': 12})
TypeError: cannot use 'dict' as a set element (unhashable type: 'dict')

>>> "Hello".split(max_split=1)
TypeError: split() got unexpected keyword argument 'max_split'. Did you mean 'maxsplit'?
```

Python 3.14 adds: keyword typo detection, `elif` after `else` detection, expression vs statement errors in ternaries, and clearer unhashable type messages.

*Source: What's New in Python 3.13/3.14, docs.python.org (2024-10, 2025-10)*

---

### Bracketless except simplifies exception handling

**Rule:** Omit parentheses around multiple exception types in `except` clauses when not using `as`—improves readability for simple cases.

```python
# Python 3.14: Parentheses optional without 'as'
try:
    connect_to_server()
except TimeoutError, ConnectionRefusedError:
    print("Network error!")

# With 'as', parentheses still required
try:
    risky_operation()
except (ValueError, TypeError) as e:
    log_error(e)
```

*Source: PEP 758 – Allow except expressions without brackets, peps.python.org (2025)*

---

### Control flow in finally blocks now warns

**Rule:** Avoid `return`, `break`, or `continue` in `finally` blocks—Python 3.14 emits `SyntaxWarning`, which will become an error in future versions.

```python
# Anti-pattern (now warns)
def risky():
    try:
        return do_something()
    finally:
        return None  # SyntaxWarning: silently suppresses exceptions!

# Correct pattern
def safe():
    result = None
    try:
        result = do_something()
    finally:
        cleanup()  # No control flow—just cleanup
    return result
```

*Source: PEP 765 – Control flow in finally blocks, peps.python.org (2025)*

---

## Type system improvements

### PEP 695 type parameter syntax replaces TypeVar boilerplate

**Rule:** Use inline `class Foo[T]:` and `def foo[T]:` syntax for all generic types instead of explicit `TypeVar` declarations.

PEP 695 eliminates confusion around TypeVar scoping, automatically infers variance, and provides cleaner syntax. No need to import `TypeVar` or `Generic` for simple cases.

```python
# ❌ Legacy (pre-3.12)
from typing import TypeVar, Generic
_T_co = TypeVar("_T_co", covariant=True, bound=str)
class ClassA(Generic[_T_co]):
    def method1(self) -> _T_co: ...

# ✅ Modern (3.12+)
class ClassA[T: str]:  # Variance auto-inferred, bound inline
    def method1(self) -> T: ...

# Type aliases (3.12+)
type ListOrSet[T] = list[T] | set[T]  # Replaces TypeAlias
```

**When to deviate:** Use traditional `TypeVar` when sharing type parameters across unrelated classes or when explicit variance control is needed for complex library code. Also needed for Python <3.12 compatibility.

*Source: PEP 695, peps.python.org (Status: Final, Python 3.12)*

---

### TypeIs provides intuitive type narrowing

**Rule:** Prefer `TypeIs` for type narrowing functions; reserve `TypeGuard` only when narrowing to a non-subtype.

`TypeIs` (Python 3.13+) narrows in **both** `if` and `else` branches and requires the narrowed type to be a subtype—matching `isinstance()` behavior. `TypeGuard` only narrows the `if` branch and allows arbitrary assertions.

```python
from typing import TypeIs, TypeGuard

# ✅ Preferred: TypeIs narrows both branches
def is_str(val: object) -> TypeIs[str]:
    return isinstance(val, str)

def process(val: int | str) -> None:
    if is_str(val):
        print(val.upper())  # val is str
    else:
        print(val + 1)      # val is int ← TypeIs enables this!

# Use TypeGuard only for non-subtype narrowing (invariant containers)
def is_str_list(val: list[object]) -> TypeGuard[list[str]]:
    return all(isinstance(x, str) for x in val)
```

*Source: PEP 742, docs.python.org/3/library/typing.html (Python 3.13+)*

---

### Self type simplifies method return typing

**Rule:** Use `Self` for methods returning the instance's type, especially in method chaining and classmethods.

```python
# ❌ Legacy
from typing import TypeVar
TShape = TypeVar("TShape", bound="Shape")
class Shape:
    def set_scale(self: TShape, scale: float) -> TShape:
        self.scale = scale
        return self

# ✅ Modern (3.11+)
from typing import Self
class Shape:
    def set_scale(self, scale: float) -> Self:
        self.scale = scale
        return self

    @classmethod
    def create(cls) -> Self:
        return cls()

class Circle(Shape): ...
reveal_type(Circle().set_scale(1.0))  # Circle, not Shape!
```

**When to deviate:** `Self` is invalid in staticmethods, metaclasses, or type aliases.

*Source: PEP 673, peps.python.org (Python 3.11+)*

---

### @override decorator catches inheritance bugs

**Rule:** Decorate all intentional method overrides with `@override` and enable strict mode in type checkers.

```python
from typing import override  # 3.12+ or typing_extensions

class Parent:
    def foo(self, x: int) -> int:
        return x

class Child(Parent):
    @override
    def foo(self, x: int) -> int:  # ✅ Verified override
        return x + 1

    @override
    def bar(self) -> None: ...  # ❌ Error: bar doesn't exist in Parent
```

*Source: PEP 698, peps.python.org (Python 3.12+)*

---

### Protocol enables structural subtyping

**Rule:** Use `Protocol` for interfaces; prefer structural subtyping over ABCs for flexibility.

```python
from typing import Protocol

class SupportsClose(Protocol):
    def close(self) -> None: ...

class Resource:  # No inheritance needed!
    def close(self) -> None:
        self.cleanup()

def close_all(items: Iterable[SupportsClose]) -> None:
    for item in items:
        item.close()

close_all([Resource(), open("file.txt")])  # Both work via duck typing
```

**When to deviate:** Use ABCs when you need runtime enforcement or default implementations.

*Source: PEP 544, typing.python.org/en/latest/spec/protocol.html*

---

### TypedDict with Required/NotRequired for mixed totality

**Rule:** Use `Required` and `NotRequired` for mixed-totality dicts; prefer explicit markers over inheritance chains.

```python
from typing import TypedDict, Required, NotRequired, ReadOnly

class Movie(TypedDict):
    title: Required[str]
    year: NotRequired[int]
    rating: ReadOnly[float]  # 3.13+ immutable key

# Closed TypedDict (3.14+) - no extra keys allowed
class StrictConfig(TypedDict, closed=True):
    host: str
    port: int
```

*Source: PEP 655/728, typing.python.org/en/latest/spec/typeddict.html*

---

### basedpyright strict configuration

**Rule:** Use `typeCheckingMode = "recommended"` and enable strict inference settings.

```toml
[tool.basedpyright]
typeCheckingMode = "recommended"
pythonVersion = "3.14"
```

| Mode | Missing returns | Missing params | Unknown types |
|------|-----------------|----------------|---------------|
| basic | none | none | none |
| standard | none | none | warning |
| strict | error | error | error |
| recommended | error | error | error + extras |
| all | error (every rule) | error | error |

*Source: docs.basedpyright.com/v1.20.0/configuration/config-files/ (2024-12)*

---

## Performance and concurrency

### Free-threaded Python reaches Phase II

**Rule:** Experiment with free-threaded Python 3.14 now for compatible workloads; wait for broader library ecosystem support before production adoption.

Python 3.14 marks **Phase II** (PEP 779): free-threaded builds are officially supported but still opt-in. Single-threaded overhead dropped from **~40%** (3.13t) to **~5-10%** (3.14t).

```bash
# Installation and usage
python3.14t script.py           # Use 't' suffix executable
PYTHON_GIL=0 python3.14t script.py  # Force GIL disabled
python3.14t -X gil=0 script.py      # Command-line option

# Verification
import sys
print(sys._is_gil_enabled())  # False if GIL disabled
```

**Threading vs multiprocessing in the no-GIL world:**

| Task Type | GIL-Enabled Python | Free-Threaded Python |
|-----------|-------------------|---------------------|
| I/O-bound, many connections | asyncio (best) | asyncio (best) |
| CPU-bound | multiprocessing (required) | **threading (preferred)** |
| Mixed I/O + CPU | multiprocessing | threading + asyncio |

**Compatibility considerations:**
- Built-in types (`dict`, `list`, `set`) use internal locks, but compound operations still require `threading.Lock`
- Non-compatible C extensions re-enable the GIL when imported
- Track ecosystem compatibility: https://py-free-threading.github.io/tracking/

**Adopt now if:** Experimental environments, dependencies support free-threading, CPU-bound threading benefits.
**Wait if:** Production stability required, dependencies don't support it, single-threaded performance critical.

*Source: PEP 703/779, peps.python.org; py-free-threading.github.io (2025)*

---

### JIT compiler provides foundation for future optimization

**Rule:** Enable the JIT for compute-intensive applications as an experiment; don't expect dramatic speedups yet.

The copy-and-patch JIT uses pre-compiled machine code templates, offering faster compilation than traditional JITs without runtime LLVM dependency.

```bash
# Enable at runtime
PYTHON_JIT=1 python script.py

# Build with JIT
./configure --enable-experimental-jit
```

**Current benchmarks (3.13):** 2-9% faster than Tier 2 interpreter, ~10% memory overhead. Benefits tight loops and computation-intensive pure Python; minimal benefit for I/O-bound or C-extension-heavy code.

**Note:** JIT is NOT yet available with free-threaded builds—choose one or the other.

*Source: Anthony Shaw blog (2024-01); LWN.net PyCon coverage (2024-05)*

---

### asyncio improvements for structured concurrency

**Rule:** Use TaskGroups for structured concurrency; leverage new introspection tools for debugging.

```python
async def main():
    async with asyncio.TaskGroup() as tg:
        task1 = tg.create_task(fetch_data("url1"))
        task2 = tg.create_task(fetch_data("url2"))
    # Both tasks guaranteed complete here

# Exception handling with except*
try:
    async with asyncio.TaskGroup() as tg:
        tg.create_task(might_fail())
except* ValueError as eg:
    for exc in eg.exceptions:
        log.error(f"Value error: {exc}")
```

**Python 3.14 additions:**
- Thread-safe event loop for free-threaded builds
- Asyncio introspection CLI: `python -m asyncio ps <PID>`, `python -m asyncio pstree <PID>`
- `asyncio.get_event_loop()` now raises `RuntimeError` if no loop exists

*Source: docs.python.org/3/library/asyncio-task.html (2025)*

---

### Incremental GC reduces pause times

**Rule:** No action needed—enjoy reduced pause times automatically in Python 3.14.

Python 3.14 implements **incremental garbage collection**, reducing from 3 generations to 2 (young and old). Maximum pause times reduced by **an order of magnitude** for larger heaps.

**Behavioral change:** `gc.collect(1)` now collects young + increment of old generation. `gc.get_objects(generation=1)` returns empty (generation 1 no longer exists in the same way).

*Source: What's New in Python 3.14, docs.python.org (2025-10)*

---

## Standard library updates

### Exception groups handle concurrent failures

**Rule:** Use `ExceptionGroup` for propagating multiple unrelated exceptions; use `except*` to handle specific types from groups.

```python
# Raising exception groups
raise ExceptionGroup("multiple failures", [
    ValueError("bad value"),
    TypeError("bad type"),
    OSError("io error")
])

# Handling with except*
try:
    async with asyncio.TaskGroup() as tg:
        tg.create_task(risky_operation1())
        tg.create_task(risky_operation2())
except* ValueError as eg:
    for exc in eg.exceptions:
        log.error(f"Value error: {exc}")
except* OSError as eg:
    handle_io_errors(eg)
# Unhandled types automatically propagate

# Filtering with split()
recoverable, fatal = eg.split(lambda e: isinstance(e, (ValueError, TypeError)))
if fatal:
    raise fatal
```

**Anti-patterns:** Mixing `except` and `except*` in same try block (SyntaxError); empty `except*:` without type; `break`/`continue`/`return` in `except*` clauses.

*Source: PEP 654, peps.python.org (Python 3.11+)*

---

### pathlib gains copy, move, and cached stat

**Rule:** Use `Path.copy()`, `Path.move()` for file operations; leverage `Path.info` for cached stat results.

```python
from pathlib import Path

# Python 3.14 copy/move methods
source = Path("source.txt")
source.copy(Path("dest") / "copied.txt")
source.move(Path("dest") / "moved.txt")
source.copy_into(Path("dest"))  # Copy into directory

# Cached stat info (3.14)
for entry in Path(".").iterdir():
    if entry.info.is_file():  # Uses cached info from directory scan
        print(entry.name)

# File URI constructor (3.13)
p = Path.from_uri("file:///home/user/doc.txt")
```

*Source: What's New in Python 3.13/3.14, docs.python.org*

---

### itertools.batched() for chunking

**Rule:** Use `itertools.batched()` for chunking iterables; use `strict=True` when batch size consistency is required.

```python
from itertools import batched

# Basic batching
for batch in batched(range(10), 3):
    print(batch)  # (0, 1, 2), (3, 4, 5), (6, 7, 8), (9,)

# Strict mode (3.13+) raises if last batch incomplete
list(batched(range(10), 3, strict=True))  # ValueError

# Practical: batch API requests
async def fetch_users(user_ids):
    for batch in batched(user_ids, 50):  # API limit: 50/request
        await api.fetch_users(batch)
```

*Source: docs.python.org/3/library/itertools.html (2024-12)*

---

### tomllib for TOML parsing

**Rule:** Use `tomllib` for read-only TOML; always open files in binary mode (`'rb'`). Use `tomli-w` for writing.

```python
import tomllib

with open("pyproject.toml", "rb") as f:
    config = tomllib.load(f)

# Parse string
data = tomllib.loads('[project]\nname = "myapp"')

# For writing TOML
import tomli_w
with open("output.toml", "wb") as f:
    tomli_w.dump(config, f)
```

**Anti-patterns:** Opening in text mode (`'r'`); using deprecated `toml` package; expecting `tomllib.dump()` to exist.

*Source: docs.python.org/3/library/tomllib.html, PEP 680*

---

### Modern datetime with zoneinfo

**Rule:** Always use timezone-aware datetimes; prefer `zoneinfo.ZoneInfo` over `pytz`; store in UTC, display in local time.

```python
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

utc_now = datetime.now(timezone.utc)
local_now = datetime.now(ZoneInfo("America/New_York"))
tokyo_time = utc_now.astimezone(ZoneInfo("Asia/Tokyo"))

# Parse ISO with timezone
dt = datetime.fromisoformat("2024-03-15T10:30:00+05:30")

# DST handling with fold
dt = datetime(2024, 11, 3, 1, 30, tzinfo=ZoneInfo("America/New_York"))
dt_after_dst = dt.replace(fold=1)  # Second occurrence
```

**Anti-patterns:** `datetime.utcnow()` (deprecated, returns naive); `pytz.localize()` instead of ZoneInfo; storing local times in databases.

*Source: docs.python.org/3/library/zoneinfo.html*

---

### New Python 3.14 modules

- **`annotationlib`** — Introspecting deferred annotations (PEP 649/749)
- **`compression.zstd`** — Zstandard compression support (PEP 784)
- **`concurrent.interpreters`** — Multiple interpreters (PEP 734)
- **`string.templatelib`** — Template string literals (PEP 750)

```python
# Zstandard compression (3.14)
from compression import zstd
compressed = zstd.compress(b"data to compress")

# Multiple interpreters (3.14)
from concurrent.interpreters import Interpreter
interp = Interpreter()
interp.run("print('Hello from subinterpreter')")

# copy.replace protocol (3.13)
from copy import replace
from datetime import date
d2 = replace(date(2024, 1, 15), month=6)  # date(2024, 6, 15)
```

*Source: What's New in Python 3.14, docs.python.org (2025-10)*

---

## Tooling and quality assurance

### ruff replaces multiple linting tools

**Rule:** Use ruff as unified replacement for flake8, black, isort with balanced rule selection.

```toml
[tool.ruff]
line-length = 88
target-version = "py312"

[tool.ruff.lint]
select = [
    "E4", "E7", "E9",  # pycodestyle errors
    "F",               # Pyflakes
    "I",               # isort
    "B",               # flake8-bugbear
    "UP",              # pyupgrade
    "S",               # flake8-bandit (security)
    "C4",              # flake8-comprehensions
    "RUF",             # Ruff-specific
]
ignore = ["E501"]  # Let formatter handle line length
fixable = ["ALL"]

[tool.ruff.lint.per-file-ignores]
"__init__.py" = ["F401"]
"tests/**" = ["S101"]

[tool.ruff.format]
quote-style = "double"
docstring-code-format = true
```

Ruff is **10-100x faster** than traditional linters, implements 800+ rules, and provides both linting (`ruff check`) and formatting (`ruff format`).

*Source: docs.astral.sh/ruff/configuration/ (2024-12)*

---

### uv replaces pip, poetry, pyenv, virtualenv

**Rule:** Use `uv` as primary package manager—it's 10-100x faster and manages Python versions, dependencies, and virtual environments.

```bash
# Project management
uv init myproject && cd myproject
uv add requests pytest
uv add --dev ruff basedpyright
uv run python main.py
uv sync  # Sync from lockfile

# Python version management
uv python install 3.12 3.13
uv python pin 3.12

# Tool execution (replaces pipx)
uvx ruff check .
```

*Source: docs.astral.sh/uv/ (2024-08)*

---

### pyproject.toml as single source of truth

**Rule:** Use `pyproject.toml` for all configuration following PEP 517/518/621 with hatchling build backend.

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "myproject"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["requests>=2.28", "pydantic>=2.0"]

[project.optional-dependencies]
dev = ["pytest>=8.0", "ruff>=0.4", "basedpyright>=1.18"]

[project.scripts]
myapp = "myproject.cli:main"

[tool.hatch.build.targets.wheel]
packages = ["src/myproject"]
```

*Source: packaging.python.org/en/latest/specifications/pyproject-toml/, PEP 621*

---

### pytest 8.x configuration

**Rule:** Use pytest 8.x with `--import-mode=importlib` for proper package isolation.

```toml
[tool.pytest.ini_options]
minversion = "8.0"
testpaths = ["tests"]
pythonpath = ["src"]
addopts = [
    "-ra",
    "-q",
    "--strict-markers",
    "--strict-config",
    "--import-mode=importlib",
]
filterwarnings = ["error"]
```

*Source: docs.pytest.org/en/stable/changelog.html (2024-12)*

---

## Modern idioms

### f-string debug specifier for quick logging

**Rule:** Use `f"{variable=}"` for debugging—prints both expression and value.

```python
name, price = "Alice", 19.99
print(f"{name=}, {price = :.2f}")  # name='Alice', price = 19.99
print(f"{len(items) = }")         # len(items) = 3

# Python 3.12+ nested quotes allowed
users = [{"name": "Bob"}]
print(f"{users[0]["name"]=}")  # Works in 3.12+
```

*Source: docs.python.org/3/whatsnew/3.8.html, fstring.help*

---

### Walrus operator reduces redundancy

**Rule:** Use `:=` when you need to assign and use a value in the same expression—primarily in while loops, comprehensions with filtering, and if statements.

```python
# While loops
while (line := file.readline()):
    process(line)

# If statements
if (match := pattern.search(text)):
    print(match.group(0))

# List comprehensions - avoid calling function twice
results = [y for x in data if (y := process(x)) > 0]

# any() with witness capture
if any((n := x) > 100 for x in numbers):
    print(f"Found: {n}")
```

**When to deviate:** Avoid in nested expressions or when assignment obscures logic.

*Source: PEP 572, realpython.com/python-walrus-operator/*

---

### Positional-only and keyword-only parameters

**Rule:** Use `/` for positional-only parameters (API flexibility); use `*` for keyword-only (clarity and safety).

```python
def fetch(url, /, *, timeout=30, headers=None):
    """url is positional-only, others are keyword-only."""
    pass

fetch("https://api.example.com", timeout=60)  # ✓
# fetch(url="...", timeout=60)  # TypeError: positional-only
# fetch("...", 60)              # TypeError: keyword-only
```

*Source: PEP 570, peps.python.org*

---

### Slotted dataclasses for memory efficiency

**Rule:** Use `@dataclass(slots=True)` for data-heavy classes with many instances.

```python
from dataclasses import dataclass

@dataclass(slots=True, frozen=True)
class Point:
    x: float
    y: float

# Memory: ~80 bytes vs ~200 bytes without slots
# Attribute access: 20-35% faster
```

**When to deviate:** Avoid slots when you need dynamic attributes or mixin inheritance.

*Source: docs.python.org/3/library/dataclasses.html*

---

### Pattern matching for complex dispatch

**Rule:** Use structural pattern matching for complex conditionals and destructuring; use if/elif for simple value comparisons.

```python
from dataclasses import dataclass

@dataclass
class Point:
    x: float
    y: float

def describe(shape):
    match shape:
        case Point(0, 0):
            return "origin"
        case Point(x, 0):
            return f"on x-axis at {x}"
        case Point(x, y) if x == y:  # Guard clause
            return f"on diagonal at {x}"
        case {"type": "click", "button": btn}:  # Dict pattern
            return f"clicked {btn}"
        case [first, *rest]:  # Sequence pattern
            return f"list starting with {first}"
        case _:
            return "unknown"

# IMPORTANT: Use qualified names for constants
class Color:
    RED = 1
match color:
    case Color.RED:   # Correct: value comparison
        ...
    # case RED:  # WRONG: captures any value as 'RED'
```

*Source: PEP 634-636, docs.python.org/3/whatsnew/3.10.html*

---

## Complete pyproject.toml example

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "myproject"
version = "1.0.0"
description = "A modern Python 3.14 project"
readme = "README.md"
license = "MIT"
requires-python = ">=3.14"
dependencies = ["httpx>=0.25", "pydantic>=2.5"]

[project.optional-dependencies]
dev = ["pytest>=8.0", "pytest-cov>=4.1", "ruff>=0.4", "basedpyright>=1.18"]

[tool.ruff]
line-length = 88
target-version = "py314"

[tool.ruff.lint]
select = ["E4", "E7", "E9", "F", "I", "B", "UP", "S", "C4", "RUF"]
ignore = ["E501"]

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["S101"]
"__init__.py" = ["F401"]

[tool.ruff.format]
quote-style = "double"
docstring-code-format = true

[tool.basedpyright]
typeCheckingMode = "recommended"
pythonVersion = "3.14"

[tool.pytest.ini_options]
minversion = "8.0"
testpaths = ["tests"]
pythonpath = ["src"]
addopts = ["-ra", "-q", "--strict-markers", "--import-mode=importlib"]

[tool.hatch.build.targets.wheel]
packages = ["src/myproject"]
```

---

## Migration checklist: 3.12 → 3.14

| Feature | Change | Action |
|---------|--------|--------|
| Forward references | Deferred evaluation default | Remove string quotes from type hints |
| `from __future__ import annotations` | Deprecated | Remove import |
| `typing.List`, `Dict`, etc. | Deprecated aliases | Use `list`, `dict` builtins |
| TypeVar declarations | Verbose | Migrate to `class Foo[T]:` syntax |
| `except (A, B):` | Optional parens | Remove parentheses when not using `as` |
| `return` in `finally` | Now warns | Refactor to avoid control flow in finally |
| Exception handling | Groups available | Consider `except*` for concurrent code |

**Tooling migration:**
- `autopep695` — Auto-converts old TypeVar syntax to PEP 695
- `pyupgrade` — Modernizes type annotations
- `ruff --select=UP` — Upgrades deprecated patterns

**Free-threaded adoption checklist:**
1. Verify dependencies support free-threading (check py-free-threading.github.io)
2. Test with `python3.14t` in CI
3. Add explicit `threading.Lock` for compound operations
4. Monitor single-threaded performance (5-10% overhead)
5. Use `PYTHON_GIL=1` fallback for incompatible code paths

---

## Key Python 3.14 features replacing legacy approaches

| Legacy Pattern | Python 3.14 Replacement |
|---------------|------------------------|
| `"ClassName"` forward refs | Direct references (deferred evaluation) |
| `f"..."` for templating | `t"..."` for secure/processed strings |
| `from __future__ import annotations` | Default behavior |
| `TypeVar("T")` boilerplate | `class Foo[T]:` syntax |
| `TypeGuard` for narrowing | `TypeIs` for intuitive narrowing |
| `shutil.copy()` | `Path.copy()` |
| GIL-limited threading | Free-threaded CPU parallelism |
| 3-generation GC | Incremental 2-generation GC |
| Repeated `stat()` calls | `Path.info` cached stat |
| `except (A, B):` | `except A, B:` (optional parens) |
