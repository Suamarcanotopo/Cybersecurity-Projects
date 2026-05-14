# Implementation walkthrough

Open the source files in another window and read along. We'll go through them in dependency order: bottom of the layer cake first, top last. The order is:

1. [`constants.py`](#1-constantspy--single-source-of-truth)
2. [`crypto.py`](#2-cryptopy--argon2id--aes-256-gcm)
3. [`generator.py`](#3-generatorpy--secure-random-passwords)
4. [`vault.py`](#4-vaultpy--file-format-atomic-writes-locking)
5. [`main.py`](#5-mainpy--the-cli)
6. [`__init__.py` and `__main__.py`](#6-__init__py-and-__main__py)
7. [The tests](#7-the-tests)

Every Python feature gets explained when it first appears. If you've seen it before, skim; if you haven't, the explanation is right there.

---

## 1. `constants.py` — single source of truth

Open [`src/password_manager/constants.py`](../src/password_manager/constants.py).

### Why this file exists

In a beginner's first Python project, numbers and strings get sprinkled all over: `length = 16`, `salt = os.urandom(16)`, `if memory > 65536:`. Six months later, nobody remembers why 16, and bumping it requires hunting through five files.

Putting every "magic number" in one file with a name and a comment turns the rest of the code into self-documenting prose. Instead of `os.urandom(16)`, we write `secrets.token_bytes(SALT_LENGTH_BYTES)` — and the reader can see immediately what kind of thing 16 means here.

### Top of the file: imports

```python
from pathlib import Path
from typing import Final
```

- **`pathlib.Path`** is Python's object-oriented filesystem-path type. Instead of `os.path.join("dir", "file.json")`, you write `Path("dir") / "file.json"`. The `/` operator is overloaded for paths. It's safer because there's no string-quoting/escaping involved.
- **`typing.Final`** is a type hint that marks a variable as "never reassign me." It's enforced by **mypy** (the type checker), not by Python itself. If you write `X: Final[int] = 5` and later try `X = 6`, mypy will flag it. The Python runtime won't — Final is documentation that the linter understands.

### Argon2id parameters

```python
ARGON2_TIME_COST: Final[int] = 3
ARGON2_MEMORY_KIB: Final[int] = 65536  # 64 MiB
ARGON2_PARALLELISM: Final[int] = 4
SALT_LENGTH_BYTES: Final[int] = 16
```

The three tunables explained in [01-CONCEPTS.md](./01-CONCEPTS.md). The comment block above them spells out *why* each value is what it is, including the deliberate divergence from OWASP's server-oriented `parallelism=1` recommendation.

Below them sit three "minimums":

```python
ARGON2_TIME_COST_MIN: Final[int] = 1
ARGON2_PARALLELISM_MIN: Final[int] = 1
ARGON2_MEMORY_KIB_PER_LANE_MIN: Final[int] = 8
```

These aren't tuning knobs — they're the algorithmic floors below which Argon2 itself refuses to run. We use them in `vault.py` to validate parameters loaded from disk, so a corrupted or hand-edited vault file can't make us call Argon2 with `time_cost=0` and crash deep inside the library with a confusing error.

### AES-256-GCM parameters

```python
KEY_LENGTH_BYTES: Final[int] = 32   # AES-256 wants 32 bytes
NONCE_LENGTH_BYTES: Final[int] = 12 # GCM-recommended nonce size
```

The key size says "we want AES-256, not AES-128." The nonce size is the GCM recommendation from [NIST SP 800-38D](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf). Don't change either.

### Vault file format

The big block of comments draws the on-disk format. Then the JSON key names live as constants:

```python
VAULT_KEY_VERSION: Final[str] = "version"
VAULT_KEY_KDF: Final[str] = "kdf"
VAULT_KEY_CIPHER: Final[str] = "cipher"

KDF_KEY_NAME: Final[str] = "name"
KDF_KEY_SALT: Final[str] = "salt"
# ... etc
```

This looks like over-engineering for a beginner project, but it has a real benefit: if you ever rename a field, you change it once here, and the linter immediately tells you every callsite that needs updating. Compare with `"version"` written inline in five different files — a typo (`"verison"`) might silently break things at runtime.

The file path constants use `pathlib`:

```python
DEFAULT_VAULT_DIRECTORY: Final[Path] = Path.home() / ".password-vault"
DEFAULT_VAULT_FILENAME: Final[str] = "vault.json"
DEFAULT_VAULT_PATH: Final[Path] = (
    DEFAULT_VAULT_DIRECTORY / DEFAULT_VAULT_FILENAME
)
```

`Path.home()` resolves at **import time**, not at call time. It returns `/home/yourname` on Linux, `/Users/yourname` on macOS, `C:\Users\yourname` on Windows. That's why this works on every OS without `if os.name == "windows"` branches.

### File mode

```python
VAULT_FILE_MODE: Final[int] = 0o600
```

`0o600` is Python's syntax for the octal number 600. In Unix file permissions, that's: owner can read and write, nobody else can read or anything. The `0o` prefix tells Python "interpret these digits as octal." (Just `600` would be six hundred decimal — wrong.) We pass this to `os.open` so the file is created world-unreadable from the very first syscall.

### Password generator defaults

```python
DEFAULT_GENERATED_PASSWORD_LENGTH: Final[int] = 24
MINIMUM_GENERATED_PASSWORD_LENGTH: Final[int] = 8
MINIMUM_MASTER_PASSWORD_LENGTH: Final[int] = 8

LOWERCASE_LETTERS: Final[str] = "abcdefghijklmnopqrstuvwxyz"
UPPERCASE_LETTERS: Final[str] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIGITS: Final[str] = "0123456789"
SAFE_SYMBOLS: Final[str] = "!@#$%^&*()-_=+[]{};:,.<>/?"
```

The symbol pool deliberately excludes a few characters:

- **Quotes** (`'`, `"`, `` ` ``) — confuse copy-paste in shells.
- **Backslash** (`\`) — shell metacharacter, double-quoted strings interpret it.
- **Space** — looks invisible when displayed.

This is a UX choice. If you want pure-random with every printable ASCII character, you'd put them back.

### CLI prompt and message strings

The rest of the file is the user-facing text:

```python
PROMPT_MASTER_PASSWORD: Final[str] = "Master password: "
MSG_VAULT_CREATED: Final[str] = "Vault created at {path}"
MSG_ENTRY_ADDED: Final[str] = "Added entry: {name}"
```

The `{path}` and `{name}` are placeholders for `.format()`. Putting these here means:

1. You can tweak the wording in one place without hunting through `main.py`.
2. If you ever want to internationalize the tool (Spanish version, etc.), you'd ship a different `constants.py` per language.

---

## 2. `crypto.py` — Argon2id + AES-256-GCM

Open [`src/password_manager/crypto.py`](../src/password_manager/crypto.py).

This is the lowest layer of the project. Bytes go in, bytes come out. No file I/O. No `print` statements. Pure cryptography wrapped in friendly Python functions.

### Imports

```python
import secrets
from dataclasses import dataclass

from argon2.low_level import Type, hash_secret_raw
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from password_manager.constants import (
    ARGON2_MEMORY_KIB,
    ARGON2_PARALLELISM,
    ARGON2_TIME_COST,
    KEY_LENGTH_BYTES,
    NONCE_LENGTH_BYTES,
    SALT_LENGTH_BYTES,
)
```

Three groups, blank lines between them. This is the standard Python convention ([PEP 8](https://peps.python.org/pep-0008/#imports)):

1. **Standard library** (ships with Python): `secrets`, `dataclasses`.
2. **Third-party** (installed from PyPI): `argon2-cffi`, `cryptography`.
3. **Local** (our own code): `password_manager.constants`.

`hazmat` in `cryptography.hazmat.primitives.ciphers.aead` is short for "hazardous materials" — the library uses this namespace for primitives that require care to use correctly. AES-GCM lives here because nonce reuse is a footgun. The library is being honest about that.

### Custom exceptions

```python
class CryptoError(Exception):
    """Base class for every cryptography error we raise."""

class WrongPasswordError(CryptoError):
    """Raised when decryption fails."""
```

Two classes, one inheriting from the other. The body is just a docstring — that's valid Python; a class needs *something* in its body, and a docstring counts.

**Why custom exceptions instead of just `raise Exception`?** Because the caller needs to be able to handle different errors differently:

```python
try:
    vault = UnlockedVault.unlock(path, password)
except WrongPasswordError:
    print("Try again")
except VaultNotFoundError:
    print("Run `pv init` first")
```

If we raised plain `Exception` for everything, the caller would have to compare exception messages as strings — fragile and ugly. Custom types make the API self-documenting.

### `@dataclass(frozen=True, slots=True)`

```python
@dataclass(frozen=True, slots=True)
class KdfParameters:
    time_cost: int
    memory_cost: int
    parallelism: int

    @classmethod
    def defaults(cls) -> "KdfParameters":
        return cls(
            time_cost=ARGON2_TIME_COST,
            memory_cost=ARGON2_MEMORY_KIB,
            parallelism=ARGON2_PARALLELISM,
        )
```

A **dataclass** is a class with auto-generated `__init__`, `__repr__`, and `__eq__` methods derived from the fields you declare. Without it, you'd write:

```python
class KdfParameters:
    def __init__(self, time_cost, memory_cost, parallelism):
        self.time_cost = time_cost
        self.memory_cost = memory_cost
        self.parallelism = parallelism

    def __eq__(self, other):
        return (self.time_cost == other.time_cost
                and self.memory_cost == other.memory_cost
                and self.parallelism == other.parallelism)

    def __repr__(self):
        return f"KdfParameters({self.time_cost}, {self.memory_cost}, ...)"
```

The `@dataclass` decorator writes all that for you. The fields with type annotations under the class body become the constructor arguments.

The two flags:

- **`frozen=True`** — instances are immutable. After `params = KdfParameters(3, 65536, 4)`, you cannot do `params.time_cost = 5`. Trying will raise an exception. Useful when you want a value to be passed around like a number or string — nobody downstream can secretly modify it.
- **`slots=True`** — saves memory by skipping the per-instance `__dict__`. Minor optimization. The bigger benefit is that it prevents accidentally adding attributes: `params.typo = 5` raises `AttributeError` instead of silently creating a typo.

**`@classmethod`**: a method whose first argument is the *class* itself, not an instance. Conventionally named `cls`. Used here to make a constructor with a friendlier name: `KdfParameters.defaults()` instead of `KdfParameters(3, 65536, 4)`.

### `generate_salt` and `generate_nonce`

```python
def generate_salt() -> bytes:
    return secrets.token_bytes(SALT_LENGTH_BYTES)

def generate_nonce() -> bytes:
    return secrets.token_bytes(NONCE_LENGTH_BYTES)
```

Both are one-liners. The job is *not* the function body — the job is the name. By having `generate_salt` and `generate_nonce` as named functions, the calling code is self-documenting:

```python
nonce = generate_nonce()    # everyone knows what this is for
salt = generate_salt()
```

vs.

```python
nonce = secrets.token_bytes(12)   # what's the 12? oh, must be a nonce
salt = secrets.token_bytes(16)    # what's the 16?
```

The named functions also keep the salt and nonce *sizes* invisible to the rest of the code — only `crypto.py` knows them.

### `derive_key` — the slow step

```python
def derive_key(
    master_password: str,
    salt: bytes,
    parameters: KdfParameters | None = None,
) -> bytes:
    if not master_password:
        raise ValueError("master_password must not be empty")

    if parameters is None:
        parameters = KdfParameters.defaults()

    password_bytes = master_password.encode("utf-8")

    return hash_secret_raw(
        secret=password_bytes,
        salt=salt,
        time_cost=parameters.time_cost,
        memory_cost=parameters.memory_cost,
        parallelism=parameters.parallelism,
        hash_len=KEY_LENGTH_BYTES,
        type=Type.ID,
    )
```

A few notable things:

- **`KdfParameters | None = None`** — the type hint syntax for "either a `KdfParameters` or `None`." The `|` is Python 3.10+'s shorter spelling of `Optional[KdfParameters]` or `Union[KdfParameters, None]`. The `= None` makes the argument default to `None` when omitted.
- **Empty password check first.** If the user (or a buggy caller) passes `""`, we refuse immediately. Argon2 would happily run, but the resulting key would be "the key derived from no secret + a public salt" — anyone who steals the file can re-derive it.
- **The `is None` check** for `parameters`. We could write `parameters: KdfParameters = KdfParameters.defaults()` as a default argument, but Python evaluates default arguments **once, at function definition time**. For an immutable `KdfParameters` that's actually fine, but the pattern of "use `None` as the default, then replace inside the function" is the safer general habit — because if the default ever becomes mutable (like a list), the one-default-shared-across-calls bug would bite.
- **`.encode("utf-8")`** — strings in Python live as Unicode code points. Cryptographic functions want raw bytes. UTF-8 is the universally-correct encoding for Unicode text. Always specify it explicitly; never rely on the platform default.
- **`Type.ID`** picks Argon2id specifically — not Argon2d or Argon2i. See [01-CONCEPTS.md §6](./01-CONCEPTS.md#6-argon2id-specifically-and-why).
- **Keyword arguments everywhere.** `secret=password_bytes`, not just `password_bytes`. This is a security-flavored API design choice: positional arguments to a function with seven parameters are a typo waiting to happen. Naming them at the call site makes mistakes loud.

### `encrypt` and `decrypt`

```python
def encrypt(plaintext: bytes, key: bytes) -> tuple[bytes, bytes]:
    cipher = AESGCM(key)
    nonce = generate_nonce()
    ciphertext = cipher.encrypt(
        nonce=nonce,
        data=plaintext,
        associated_data=None,
    )
    return nonce, ciphertext
```

Three things:

1. **`AESGCM(key)`** constructs a cipher object bound to the key. The library validates the key size — must be 16, 24, or 32 bytes. A wrong-size key raises immediately.
2. **Fresh nonce every call.** The `generate_nonce()` line is the single most security-critical line in the whole file. Reusing a nonce with the same key is catastrophic (see [01-CONCEPTS.md §10](./01-CONCEPTS.md#10-nonces-the-most-dangerous-thing-in-this-codebase)).
3. **`associated_data=None`.** AES-GCM has an optional "associated data" parameter: data that's authenticated (tamper-evident) but not encrypted. Useful for packet headers — you want the recipient to detect modifications to the header, but the header itself is public. We don't have any such data, so we pass `None`.

The return type `tuple[bytes, bytes]` means "two bytes objects returned together." The caller unpacks as `nonce, ciphertext = encrypt(data, key)`.

```python
def decrypt(ciphertext: bytes, nonce: bytes, key: bytes) -> bytes:
    cipher = AESGCM(key)
    try:
        return cipher.decrypt(
            nonce=nonce,
            data=ciphertext,
            associated_data=None,
        )
    except InvalidTag as exc:
        raise WrongPasswordError(
            "Decryption failed: wrong master password or corrupted vault"
        ) from exc
```

`InvalidTag` is the cryptography library's signal that the authentication tag didn't match — wrong key, wrong nonce, or modified ciphertext. We catch it and re-raise as our own `WrongPasswordError`. The caller doesn't have to know `cryptography.exceptions` exists.

**`raise WrongPasswordError(...) from exc`** — the `from exc` part preserves the original exception's traceback in the new exception's `__cause__` attribute. If something blows up unexpectedly, the debug output still shows the underlying `InvalidTag` cause. Good practice when you're translating one exception type into another.

---

## 3. `generator.py` — secure random passwords

Open [`src/password_manager/generator.py`](../src/password_manager/generator.py).

This file is shorter than `crypto.py` and easier to reason about. Two public functions worth following carefully.

### `generate_password`

```python
def generate_password(
    length: int = DEFAULT_GENERATED_PASSWORD_LENGTH,
    *,
    use_lowercase: bool = True,
    use_uppercase: bool = True,
    use_digits: bool = True,
    use_symbols: bool = True,
) -> str:
```

The **`*`** in the signature is a Python feature called **keyword-only arguments**. After the `*`, every argument must be passed by name. This:

```python
generate_password(20, use_symbols=False)    # OK
generate_password(20, True, True, True, False)  # ERROR
```

It forces call sites to be readable. `generate_password(20, True, True, True, False)` is impossible to understand at a glance — you'd have to count the booleans. `generate_password(20, use_symbols=False)` is self-documenting.

### Validating the inputs

```python
if length < MINIMUM_GENERATED_PASSWORD_LENGTH:
    raise PasswordTooShortError(...)

enabled_pools = {
    "lower": LOWERCASE_LETTERS if use_lowercase else "",
    "upper": UPPERCASE_LETTERS if use_uppercase else "",
    "digit": DIGITS if use_digits else "",
    "symbol": SAFE_SYMBOLS if use_symbols else "",
}
enabled_pools = {k: v for k, v in enabled_pools.items() if v}
```

The `if use_lowercase else ""` is a **conditional expression** (sometimes called a ternary). `<a> if <cond> else <b>` evaluates to `<a>` when `<cond>` is truthy, else `<b>`.

The second line is a **dict comprehension**: `{k: v for k, v in something.items() if condition}` builds a new dict from filtered items. It's the dict equivalent of `[x for x in list if cond]` (a list comprehension). Result: we keep only the pools whose flag was True (because empty strings are falsy in Python).

```python
if not enabled_pools:
    raise ValueError("At least one character pool must be enabled")

if length < len(enabled_pools):
    raise PasswordTooShortError(
        f"length={length} is too small to include one character "
        f"from each of {len(enabled_pools)} enabled pools"
    )
```

If every pool was disabled, refuse. If the user wants a password shorter than the number of pools they enabled, also refuse (we couldn't fit one of each).

### The actual generation

```python
alphabet = "".join(enabled_pools.values())

required = [secrets.choice(pool) for pool in enabled_pools.values()]
fill_count = length - len(required)
fill = [secrets.choice(alphabet) for _ in range(fill_count)]

chars = required + fill
_secure_shuffle(chars)

return "".join(chars)
```

Three steps:

1. **Required characters.** For each enabled pool, pick one character. This guarantees the final password contains at least one of each kind — important for sites that enforce "must contain a digit" rules even though random sampling without this guarantee is *technically* fine.
2. **Fill the rest.** Pick `length - len(required)` more characters from the combined alphabet.
3. **Shuffle.** Without the shuffle, the required characters would always be at positions 0..N-1 — which is a guessable pattern and a weakness, however small.

**`secrets.choice(pool)`** is the secure version of `random.choice(pool)`. Picks one element uniformly at random.

**`for _ in range(fill_count)`** — the underscore is a Python convention meaning "I need a loop variable but I'm not going to use its value." Same as Go's blank identifier.

### `_secure_shuffle`

```python
def _secure_shuffle(items: list[str]) -> None:
    for i in range(len(items) - 1, 0, -1):
        j = secrets.randbelow(i + 1)
        items[i], items[j] = items[j], items[i]
```

This implements the **Fisher-Yates shuffle** (also called the Knuth shuffle). It produces a uniformly random permutation if the random source is uniform.

Why not `random.shuffle()`? Because `random.shuffle()` uses the Mersenne Twister, which is predictable. We need shuffling that an attacker can't predict, so we build it ourselves on top of `secrets.randbelow`.

The line `items[i], items[j] = items[j], items[i]` is Python's **tuple-swap** syntax for exchanging two values without a temp variable. It works because the right-hand side is fully evaluated before any assignment happens on the left.

**Leading underscore** in `_secure_shuffle`: convention for "this is a module-private helper, don't import me from outside this module." Python doesn't enforce it; it's documentation aimed at humans.

---

## 4. `vault.py` — file format, atomic writes, locking

Open [`src/password_manager/vault.py`](../src/password_manager/vault.py).

This is the longest file (~1000 lines including docstrings/comments). It has the most going on. Take it in pieces.

### `from __future__ import annotations`

The very first import. This is a [PEP 563](https://peps.python.org/pep-0563/) opt-in that makes type hints evaluate as strings instead of actual objects. The benefit: classes can refer to themselves in their own annotations (`def foo(self) -> UnlockedVault` from inside `UnlockedVault`) without needing to quote them. It also speeds up module load slightly. Default behavior in some future Python version, opt-in for now.

### Imports — what they're for, briefly

```python
import base64           # encode raw bytes as ASCII text for JSON
import contextlib       # `contextlib.suppress` and `@contextmanager`
import json             # parse and serialize JSON
import os               # low-level filesystem ops (open/replace/fsync)
from collections.abc import Iterator   # type hint for generator return
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime, UTC     # timestamps in UTC
from pathlib import Path
from types import TracebackType        # type hint for __exit__
from typing import Any, Self           # Any for opaque JSON, Self for method-return types
```

The `try`/`except ImportError` block for `fcntl` is a portability dance: `fcntl` is POSIX-only. On Windows, `import fcntl` would raise `ImportError`. We catch it, set the variable to `None`, and check for `None` at call time. The `# pragma: no cover` comment tells the coverage tool to skip that line in coverage reports.

### Exceptions

Six classes:

```python
class VaultError(Exception): pass
class VaultNotFoundError(VaultError): pass
class VaultAlreadyExistsError(VaultError): pass
class VaultFormatError(VaultError): pass
class EntryNotFoundError(VaultError): pass
class EntryAlreadyExistsError(VaultError): pass
```

`pass` is the keyword for "this block has no code." A class with only `pass` is a valid class that just inherits everything from its parent. We use that here because the *names* are the point — `except VaultNotFoundError:` lets a caller handle that specific error without catching unrelated bugs.

### Base64 helpers

```python
def _b64encode(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")

def _b64decode(text: str) -> bytes:
    try:
        return base64.b64decode(text, validate=True)
    except (ValueError, TypeError) as exc:
        raise VaultFormatError(f"Invalid base64 in vault: {exc}") from exc
```

`base64.b64encode` returns `bytes`. We `.decode("ascii")` to get a `str` because JSON keys/values must be strings.

`validate=True` is important: by default `b64decode` silently ignores invalid characters. With `validate=True`, it raises on invalid input — which is what we want for "I'm reading a vault file and expect well-formed base64."

### `_validate_entry_name`

```python
def _validate_entry_name(name: str) -> None:
    if not name or not name.strip():
        raise ValueError("Entry name cannot be empty or whitespace")
    if name != name.strip():
        raise ValueError(
            "Entry name must not have leading or trailing whitespace"
        )
```

The leading/trailing whitespace check is the subtle one. Without it, `"github"` and `"github "` would be two different keys, looking identical on screen. We reject ambiguity at the boundary.

### `_file_lock` — the context manager

```python
@contextlib.contextmanager
def _file_lock(target_path: Path) -> Iterator[None]:
    if _fcntl is None:
        yield
        return

    lock_path = target_path.with_suffix(target_path.suffix + ".lock")
    target_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(
        lock_path,
        os.O_RDWR | os.O_CREAT,
        VAULT_FILE_MODE,
    )
    try:
        _fcntl.flock(fd, _fcntl.LOCK_EX)
        try:
            yield
        finally:
            _fcntl.flock(fd, _fcntl.LOCK_UN)
    finally:
        os.close(fd)
```

The `@contextlib.contextmanager` decorator turns a generator function into a context manager (something usable with `with`). The pattern is:

```python
@contextlib.contextmanager
def my_thing():
    # setup
    yield resource    # <-- the `with X as resource:` line gets this
    # teardown
```

In our case, "setup" is "acquire the lock" and "teardown" is "release the lock." The `yield` doesn't return a useful value — it just marks the point where the with-block runs.

**The `try`/`finally` nesting** is what makes the cleanup bulletproof: even if the user's code inside `with` raises an exception, the `finally` blocks still run, the lock gets released, and the file descriptor gets closed.

**`fcntl.LOCK_EX`** is an exclusive lock — only one process can hold it at a time. If another process already has it, we block (wait) until it's released. For a single-user CLI tool, blocking is fine.

### `Entry` dataclass

```python
@dataclass(slots=True, frozen=True)
class Entry:
    username: str
    password: str
    url: str = ""
    notes: str = ""
    created_at: str = field(default_factory=_now_iso)
    updated_at: str = field(default_factory=_now_iso)
```

`frozen=True` for the same reason as `KdfParameters` — once built, an entry is immutable.

**`field(default_factory=_now_iso)`** is how you give a dataclass field a *fresh* default value on every new instance. If we wrote `created_at: str = _now_iso()`, that would call `_now_iso()` once at class-definition time and reuse the same timestamp forever. `default_factory=_now_iso` (note: passing the function itself, not calling it) tells the dataclass to call it once per `Entry()` invocation.

### `Entry.from_dict`

```python
@classmethod
def from_dict(cls, data: dict[str, Any]) -> Entry:
    try:
        username = data["username"]
        password = data["password"]
    except KeyError as exc:
        raise VaultFormatError(
            f"Entry missing required field: {exc}"
        ) from exc
    if not isinstance(username, str) or not isinstance(password, str):
        raise VaultFormatError("Entry username and password must be strings")
    return cls(
        username=username,
        password=password,
        url=data.get("url", ""),
        notes=data.get("notes", ""),
        created_at=data.get("created_at", ""),
        updated_at=data.get("updated_at", ""),
    )
```

This is the "deserialize from JSON" path. Required fields use `data["username"]` — a missing key raises `KeyError`, which we catch and turn into `VaultFormatError`. Optional fields use `data.get("url", "")` — `dict.get(key, default)` returns the default if the key is missing.

Notice the timestamps default to `""` instead of "now." If we defaulted to "now" while reading, an old entry that didn't record its creation time would look freshly created — misleading.

### `UnlockedVault` — the big class

```python
@dataclass(slots=True)
class UnlockedVault:
    path: Path
    salt: bytes
    kdf_parameters: KdfParameters
    key: bytes
    entries: dict[str, Entry]
```

This dataclass is **not frozen**. It needs to be mutable so we can add/delete entries and rotate the master password. The `key` field holds the 32-byte AES key derived from the master password; the `entries` field holds the decrypted credential rows.

### `UnlockedVault.create`

```python
@classmethod
def create(
    cls,
    path: Path,
    master_password: str,
    *,
    kdf_parameters: KdfParameters | None = None,
) -> Self:
    if path.exists():
        raise VaultAlreadyExistsError(f"Vault already exists at {path}")

    salt = generate_salt()
    kdf_parameters = kdf_parameters or KdfParameters.defaults()
    key = derive_key(master_password, salt, kdf_parameters)

    vault = cls(
        path=path,
        salt=salt,
        kdf_parameters=kdf_parameters,
        key=key,
        entries={},
    )
    vault.save()
    return vault
```

**`-> Self`** is Python 3.11's way of saying "this method returns an instance of this same class." Useful for inherited methods to keep types straight.

**`kdf_parameters or KdfParameters.defaults()`** uses Python's short-circuiting `or`. If `kdf_parameters` is `None` (falsy), the right-hand side runs and produces the defaults. If a real `KdfParameters` was passed, that's truthy and we use it.

The `kdf_parameters` argument is the seam tests use. Tests pass weak parameters to make Argon2 finish in milliseconds. Production callers pass `None` and get the real defaults.

### `UnlockedVault.unlock`

```python
@classmethod
def unlock(cls, path: Path, master_password: str) -> Self:
    if not path.exists():
        raise VaultNotFoundError(f"No vault at {path}")

    try:
        envelope = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise VaultFormatError(f"...") from exc

    salt, kdf_parameters, nonce, ciphertext = _parse_envelope(envelope)

    key = derive_key(master_password, salt, kdf_parameters)
    plaintext_bytes = decrypt(ciphertext, nonce, key)

    try:
        entries_data = json.loads(plaintext_bytes.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise VaultFormatError(f"...") from exc

    entries = {
        name: Entry.from_dict(row)
        for name, row in entries_data.items()
    }

    return cls(
        path=path,
        salt=salt,
        kdf_parameters=kdf_parameters,
        key=key,
        entries=entries,
    )
```

Read top to bottom:

1. **File exists check** — raise `VaultNotFoundError` if not.
2. **Read + parse the JSON envelope.** `Path.read_text(encoding="utf-8")` reads the whole file as a string in one call.
3. **`_parse_envelope`** pulls the four fields we need out, validating version and algorithm names. Returns a tuple, unpacked into four variables.
4. **Derive key using the salt and parameters from the file** — *not* today's defaults. This is the magic that lets old vaults keep working.
5. **Decrypt.** `WrongPasswordError` bubbles up.
6. **Parse the decrypted JSON** into an `entries_data` dict.
7. **Convert each row** (a plain dict) into an `Entry` instance via the dict comprehension.

### `UnlockedVault.save`

```python
def save(self) -> None:
    entries_json = json.dumps(
        {name: entry.to_dict() for name, entry in self.entries.items()},
        sort_keys=True,
        indent=2,
    ).encode("utf-8")

    nonce, ciphertext = encrypt(entries_json, self.key)

    envelope = _build_envelope(
        salt=self.salt,
        kdf_parameters=self.kdf_parameters,
        nonce=nonce,
        ciphertext=ciphertext,
    )
    envelope_bytes = json.dumps(envelope, indent=2).encode("utf-8")

    self.path.parent.mkdir(parents=True, exist_ok=True)

    with _file_lock(self.path):
        self._atomic_write(envelope_bytes)
```

Five steps:

1. **Serialize the entries dict to JSON bytes.** `sort_keys=True` makes the output deterministic — nice for diffing encrypted files.
2. **Encrypt.** Fresh nonce generated inside `encrypt()`.
3. **Build the envelope dict.**
4. **Serialize the envelope to bytes.**
5. **Acquire the lock, do the atomic write.** Lock is released automatically when the `with` block ends.

### `UnlockedVault._atomic_write`

```python
def _atomic_write(self, envelope_bytes: bytes) -> None:
    tmp_path = self.path.with_suffix(self.path.suffix + ".tmp")

    fd = os.open(
        tmp_path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        VAULT_FILE_MODE,
    )
    try:
        try:
            os.write(fd, envelope_bytes)
            os.fsync(fd)
        finally:
            os.close(fd)

        os.replace(tmp_path, self.path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp_path)
        raise

    if os.name != "nt":
        dir_fd = os.open(self.path.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
```

The flags to `os.open`:

- **`os.O_WRONLY`** — open for writing only.
- **`os.O_CREAT`** — create if missing.
- **`os.O_TRUNC`** — truncate to zero if existing.

The third argument (`VAULT_FILE_MODE = 0o600`) is the file mode applied at *creation time*. Using `os.open` instead of the higher-level `Path.write_bytes` lets us set the mode in the same syscall, avoiding the brief window where a freshly-created file would otherwise have wider permissions (umask-determined).

**`except BaseException`** — catches *everything* including `KeyboardInterrupt` and `SystemExit`. We use the broadest catch here because we want to clean up the temp file no matter what stopped us. The `raise` at the end re-raises the original exception.

**`contextlib.suppress(FileNotFoundError)`** — a one-liner for "ignore this specific exception if it happens." Used here because the temp file might not exist if we crashed before creating it.

**The directory fsync** at the end is the second of two fsync calls. The first one (`os.fsync(fd)`) flushes the file's *bytes*. The second one (`os.fsync(dir_fd)`) flushes the directory's *entry* — without it, the rename itself can be lost on power loss. POSIX requires both.

`os.name != "nt"` skips the directory fsync on Windows because NTFS doesn't support it. NTFS journaling handles the durability there.

### `UnlockedVault.add_entry`

```python
def add_entry(self, name: str, entry: Entry, *, force: bool = False) -> None:
    _validate_entry_name(name)
    if name in self.entries and not force:
        raise EntryAlreadyExistsError(f"Entry already exists: {name}")
    if name in self.entries:
        old = self.entries[name]
        entry = replace(entry, created_at=old.created_at, updated_at=_now_iso())
    self.entries[name] = entry
```

**`replace(entry, created_at=..., updated_at=...)`** is a dataclasses helper that builds a new instance with some fields changed. Since `Entry` is frozen, we can't mutate it in place — `replace` makes a fresh copy with the overrides applied. This preserves the original `created_at` while bumping `updated_at`.

### `UnlockedVault.change_master_password`

```python
def change_master_password(
    self,
    new_master_password: str,
    *,
    kdf_parameters: KdfParameters | None = None,
) -> None:
    if not new_master_password:
        raise ValueError("new_master_password must not be empty")

    new_salt = generate_salt()
    new_kdf_parameters = kdf_parameters or KdfParameters.defaults()
    new_key = derive_key(new_master_password, new_salt, new_kdf_parameters)

    self.salt = new_salt
    self.kdf_parameters = new_kdf_parameters
    self.key = new_key
```

Note: **this method only mutates in-memory state.** It doesn't touch the disk. The caller must call `save()` afterward. Why split it like this? Because keeping side effects on different layers makes testing cleaner — and because if we did the save inside, a crash mid-save would leave the *file* in an undefined state while in-memory said "rotation succeeded."

### `close`, `__enter__`, `__exit__`

```python
def close(self) -> None:
    self.entries = {}
    self.key = bytes(KEY_LENGTH_BYTES)

def __enter__(self) -> Self:
    return self

def __exit__(self, exc_type, exc_val, exc_tb) -> None:
    self.close()
```

`__enter__` and `__exit__` are the Python special methods that make `with vault as v:` work. `__enter__` runs at the start and its return value is what `as v` binds to. `__exit__` runs at the end — normal or via exception.

`bytes(N)` constructs a bytes object of N zero bytes. So `self.key = bytes(32)` replaces the key with 32 zero bytes. We *can't* zero the original bytes in place because Python bytes are immutable, but we can drop the reference. This is a best-effort wipe.

### `_build_envelope` and `_parse_envelope`

These are the "serialize this dataclass into the envelope dict" and "deserialize the envelope dict into typed pieces" helpers. The interesting part of `_parse_envelope` is the validation:

```python
if version != VAULT_FORMAT_VERSION:
    raise VaultFormatError(f"Unsupported vault version: {version} ...")
```

We refuse vaults from a future format version. Better to fail loudly than to read a vault written by a future version of the tool with subtly different semantics.

The Argon2 parameter validation against algorithmic minimums is the rest of the function. A corrupted vault file with `time_cost=0` would otherwise crash deep inside argon2-cffi; we catch it at the boundary and surface a clean error.

---

## 5. `main.py` — the CLI

Open [`src/password_manager/main.py`](../src/password_manager/main.py).

This file is the glue between the user's keyboard and the rest of the code. It uses **Typer** for argument parsing and **Rich** for colored output.

### `Typer` basics

```python
app = typer.Typer(
    name="pv",
    help="Encrypted password manager (Argon2id + AES-256-GCM)",
    no_args_is_help=True,
    add_completion=False,
)
```

`typer.Typer()` creates an "app" — a registry that commands attach to. Then each command is a function decorated with `@app.command()`:

```python
@app.command()
def init(vault: VaultPath = DEFAULT_VAULT_PATH) -> None:
    """Create a new empty vault at --vault (or PV_VAULT or default path)"""
    ...
```

The function name becomes the command name. `pv init` runs the `init` function. The function's docstring becomes the `--help` text for that command. The type hints on parameters tell Typer how to parse them.

### `Annotated` and `typer.Option` / `typer.Argument`

```python
VaultPath = Annotated[
    Path,
    typer.Option(
        "--vault",
        "-v",
        help="Path to the vault file",
        envvar="PV_VAULT",
    ),
]
```

**`Annotated[T, metadata]`** is a way to attach extra metadata to a type hint without changing its underlying type. Typer reads the metadata to build the CLI behavior; everything else (mypy, runtime) sees just `Path`.

We define `VaultPath` once as a type alias so every command takes the same `--vault` flag with the same description and env var support. DRY-ish.

`envvar="PV_VAULT"` is a Typer convenience: if `--vault` isn't passed, Typer reads `$PV_VAULT` from the environment. If that's also missing, the function's default (`DEFAULT_VAULT_PATH`) kicks in.

### Two consoles, two streams

```python
console = Console()
error_console = Console(stderr=True)
```

**stdout** is for the "result" of the command (success output, the password panel, the table of entries). **stderr** is for diagnostics and errors. This split lets users redirect cleanly:

```bash
pv gen 32 | pbcopy           # only the password goes to clipboard
pv get foo 2>/dev/null       # swallow errors, keep the credential panel
```

If everything went through one console, neither redirect would work cleanly.

### `_prompt_master_password`

```python
def _prompt_master_password(prompt: str = PROMPT_MASTER_PASSWORD) -> str:
    return getpass.getpass(prompt)
```

`getpass.getpass(prompt)` reads input from the terminal *without echoing it*. The same primitive `sudo` uses. The user types their password, sees nothing, presses Enter, and `getpass` returns the string.

We wrap it in a function so we have one place to swap if we ever want non-interactive mode (read from stdin without prompting, for scripts).

### `_unlock_or_exit`

```python
def _unlock_or_exit(path: Path, master_password: str) -> UnlockedVault:
    try:
        return UnlockedVault.unlock(path, master_password)
    except VaultNotFoundError:
        error_console.print(f"[red]{MSG_VAULT_NOT_FOUND.format(path=path)}[/red]")
        raise typer.Exit(code=1) from None
    except WrongPasswordError:
        error_console.print(f"[red]{MSG_WRONG_MASTER_PASSWORD}[/red]")
        raise typer.Exit(code=1) from None
    except VaultFormatError as exc:
        error_console.print(f"[red]Vault file is invalid: {exc}[/red]")
        raise typer.Exit(code=1) from None
    except VaultError as exc:
        error_console.print(f"[red]Vault error: {exc}[/red]")
        raise typer.Exit(code=1) from None
```

A helper that wraps `UnlockedVault.unlock` and turns each error type into the right message + exit code. The CLI commands all call this so they don't have to repeat the try/except block.

**`typer.Exit(code=1)`** is Typer's clean way to exit with a non-zero status. We never call `sys.exit` ourselves; Typer wraps the whole `app()` call in something that converts `typer.Exit` into a real exit.

**`from None`** at the end of `raise X from None` suppresses the chained traceback. Without it, the user would see "While handling X, Y occurred" — useful for debugging but noisy for "we knew this could fail and handled it cleanly."

The `[red]...[/red]` markup is Rich's color syntax — it gets rendered as red text in a terminal that supports color, and as plain text in a terminal that doesn't.

### A representative command — `add`

```python
@app.command()
def add(
    name: Annotated[str, typer.Argument(help="Entry name (must be unique)")],
    vault: VaultPath = DEFAULT_VAULT_PATH,
    force: Annotated[bool, typer.Option("--force", "-f", help="Overwrite if exists")] = False,
    generate: Annotated[bool, typer.Option("--generate", "-g", help="...")] = False,
    length: Annotated[int, typer.Option("--length", "-n", help="...")] = DEFAULT_GENERATED_PASSWORD_LENGTH,
) -> None:
    """Add (or overwrite with --force) an entry in the vault"""
    master = _prompt_master_password()
    with _unlock_or_exit(vault, master) as unlocked:
        username = input(PROMPT_ENTRY_USERNAME.format(entry=name))

        if generate:
            try:
                password = generate_password(length)
            except PasswordTooShortError as exc:
                error_console.print(f"[red]{exc}[/red]")
                raise typer.Exit(code=1) from None
            console.print(f"[green]Generated password:[/green] {password}")
        else:
            password = _prompt_master_password(f"Password for {name} (hidden): ")

        url = input(PROMPT_ENTRY_URL).strip()
        notes = input(PROMPT_ENTRY_NOTES).strip()

        entry = Entry(username=username, password=password, url=url, notes=notes)

        try:
            unlocked.add_entry(name, entry, force=force)
        except EntryAlreadyExistsError:
            error_console.print(f"[red]{MSG_ENTRY_ALREADY_EXISTS.format(name=name)}[/red]")
            raise typer.Exit(code=1) from None
        except ValueError as exc:
            error_console.print(f"[red]{exc}[/red]")
            raise typer.Exit(code=1) from None

        unlocked.save()
    console.print(f"[green]{MSG_ENTRY_ADDED.format(name=name)}[/green]")
```

The command demonstrates the recurring pattern in every command:

1. **Prompt for master password.**
2. **Open the `with` block** — `_unlock_or_exit` handles the unlock and any unlock-time errors.
3. **Do the work** — collect input, call `add_entry`, handle any work-time errors.
4. **`save()` inside the `with` block** — we need the key for save.
5. **`with` block ends** — vault wipes its key and entries.
6. **Print success message** — after the wipe, the entry is no longer in memory, but the success message doesn't need it.

Notice `password = _prompt_master_password(f"Password for {name} (hidden): ")`. We reuse the same `getpass`-based helper that prompts for the master password, but with a different prompt string, so the *entry* password is also typed hidden. This is just convenience — the entry password is no more secret than the master, but it's a nicer UX to not echo it.

### `gen` — the only command without a vault

```python
@app.command()
def gen(
    length: Annotated[int, typer.Argument(help="Password length")] = DEFAULT_GENERATED_PASSWORD_LENGTH,
    no_symbols: Annotated[bool, typer.Option("--no-symbols", help="Letters and digits only")] = False,
    no_digits: Annotated[bool, typer.Option("--no-digits", help="Letters and symbols only")] = False,
    no_uppercase: Annotated[bool, typer.Option("--no-uppercase", help="No uppercase letters")] = False,
) -> None:
    try:
        password = generate_password(
            length,
            use_lowercase=True,
            use_uppercase=not no_uppercase,
            use_digits=not no_digits,
            use_symbols=not no_symbols,
        )
    except (PasswordTooShortError, ValueError) as exc:
        error_console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=1) from None

    print(password)
```

Notice the **plain `print()` instead of `console.print()`**. Rich's `console.print` would add ANSI color escape codes if the terminal supports them. We don't want those inside a password that might get piped to `pbcopy`. Plain `print` is the right tool here.

The flags are negative (`--no-symbols`, `--no-digits`, `--no-uppercase`) because the defaults are *on* — most people want a strong password with everything. Saying "I don't want X" is the rare case, which is the right semantics for a flag.

### `change-password`

```python
@app.command(name="change-password")
def change_password(vault: VaultPath = DEFAULT_VAULT_PATH) -> None:
    current = _prompt_master_password("Current master password: ")
    with _unlock_or_exit(vault, current) as unlocked:
        new_password = _prompt_master_password_with_confirmation()
        unlocked.change_master_password(new_password)
        unlocked.save()
    console.print(f"[green]{MSG_MASTER_PASSWORD_CHANGED.format(path=vault)}[/green]")
```

The `name="change-password"` overrides the auto-generated name (`change_password` from the function name) to use a hyphen instead of an underscore. Hyphens are more conventional in CLIs.

The flow:

1. Prompt for **current** master password.
2. Unlock with it. If wrong, `_unlock_or_exit` exits 1.
3. Prompt for **new** master password (twice, confirm).
4. Call `change_master_password` — only mutates in-memory state.
5. `save()` — encrypts everything under the new key and atomically writes.

If anything fails between steps 4 and 5, the file on disk still has the old salt and old ciphertext. The user is no worse off.

---

## 6. `__init__.py` and `__main__.py`

Two tiny but important files.

### `__init__.py`

This makes `password_manager/` a Python **package**. Without an `__init__.py` (or a `pyproject.toml` declaring it as a namespace package), Python wouldn't know it's allowed to look inside the folder.

Beyond that, the file re-exports the public API:

```python
from password_manager.crypto import (
    CryptoError,
    KdfParameters,
    WrongPasswordError,
)
from password_manager.vault import (
    Entry,
    EntryAlreadyExistsError,
    # ...
)
```

This lets external callers (tests, other tools) write:

```python
from password_manager import UnlockedVault
```

instead of:

```python
from password_manager.vault import UnlockedVault
```

The benefit is that we can split `vault.py` into three files later (or rename it) without breaking anyone's imports — they go through the package's front door, not the internal layout.

```python
__version__ = "1.0.0"

__all__ = [
    "CryptoError",
    "Entry",
    # ...
]
```

**`__version__`** is the conventional name for the package's version. Tools (`pip`, build systems) can read it.

**`__all__`** is the explicit list of names that `from password_manager import *` will bring in. It's also documentation: "these are the names we consider public."

### `__main__.py`

```python
from password_manager.main import app

if __name__ == "__main__":
    app()
```

This file lets you run the package directly:

```bash
python -m password_manager init
```

Same effect as `pv init`. Useful when the `pv` script isn't on your PATH yet.

The `if __name__ == "__main__":` check is the standard Python idiom for "only run this code if the file is the script entry point." If something imports this file (which they wouldn't, but the idiom is universal), the `app()` call doesn't fire.

---

## 7. The tests

Open the files in `tests/`. We won't walk every test, just point out the patterns to look for.

### `conftest.py`

Pytest treats `conftest.py` as magic. Anything defined here is available to every test file in the directory without an explicit import.

Three fixtures live here:

- **`vault_path`** — a fresh, non-existent vault path inside a temp directory. Built on pytest's built-in `tmp_path` fixture, which auto-creates and auto-cleans per test.
- **`master_password`** — a stable test master password (`"correct horse battery staple"`).
- **`fresh_vault`** — an empty `UnlockedVault` using fast Argon2 parameters.

The fast Argon2 parameters are the key trick:

```python
TEST_KDF_PARAMETERS = KdfParameters(
    time_cost=1,
    memory_cost=8,
    parallelism=1,
)
```

These are below OWASP recommendations — *deliberately*. They cut test runtime from minutes to milliseconds. The cryptographic correctness of the code is the same regardless of parameter strength; Argon2 does the same operations with fewer iterations.

Notice no monkey-patching of `KdfParameters.defaults()`. Instead, the test passes `kdf_parameters=TEST_KDF_PARAMETERS` explicitly into `UnlockedVault.create`. That's why the production code threads `kdf_parameters` through the constructor — so tests can swap it without polluting global state.

### `test_crypto.py`

The interesting tests here:

- **Round-trip.** Encrypt something, decrypt it, assert you got the original back.
- **Tampering.** Encrypt something, flip a byte in the ciphertext, assert `decrypt` raises `WrongPasswordError`.
- **Wrong key.** Encrypt with key A, try to decrypt with key B, assert `WrongPasswordError`.
- **Salt determinism.** Same password + same salt → same key. Same password + *different* salt → *different* key.

The tampering tests are the security-critical ones. If GCM auth ever stopped working, those tests fail loudly.

### `test_vault.py`

End-to-end vault tests. The patterns to notice:

- **Every test gets a fresh vault path.** Pytest's `tmp_path` makes each test fully isolated.
- **Round-trip tests.** Create vault, add entry, save, unlock with right password, get entry back.
- **Failure-mode tests.** Wrong password, missing file, corrupted JSON, modified ciphertext, modified envelope, missing fields, wrong algorithm name.
- **Whitespace/name-validation tests.** `"github "` is rejected. `""` is rejected.
- **`change_master_password` tests.** Rotate, save, re-open with new password, fail with old password.

### `test_generator.py`

Tests for the password generator:

- **Length.** Result is exactly the requested length.
- **Pool coverage.** Result contains at least one char from each enabled pool.
- **Pool exclusion.** Disabled pools never appear.
- **Refusal cases.** Length below minimum, no pools enabled, length less than pool count.
- **Randomness sanity.** Generate many passwords, assert they're not all the same. (Not a *real* randomness test — that's not statistically meaningful for so few samples — just a sanity check that the function isn't returning a constant.)

---

## Where to go next

You've seen every file. You know what each function does and why. The last piece is **[04-CHALLENGES.md](./04-CHALLENGES.md)** — extension ideas if you want to keep going.

After that, the best learning move is to write your own version *without looking at this one*. Open an empty file and try to rebuild the project from memory. The places you have to look something up are the places you don't yet understand — go back to that section and read it again.
