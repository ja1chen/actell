# Embedded Python commands

Actell registers `python3` and `python` in its existing ios_system command
dictionary. Both enter the same CPython runtime through the `bash` tool, with
the existing command authorization, working directory, output capture and run
lifecycle. There is no separate Python Agent tool. The runtime uses the locked
BeeWare CPython support package and preinstalled Pillow and NumPy wheels for
ARM64 iOS devices and ARM64 iOS simulators.

## Command contract

```sh
python3 script.py argument
python3 -c "import numpy; print(numpy.__version__)"
python3 -m json.tool input.json
echo hello | python3 -c "import sys; print(sys.stdin.read().upper())"
python3 script.py > output.txt
```

`python` is an alias for the same runtime. `-V`/`--version`, `-h`/`--help`,
`-u`, `-B`, and `-` for source from stdin are supported. Other interpreter
flags fail explicitly. No interactive REPL, subprocess support, runtime pip
installation or second interpreter is provided. Shell syntax follows ios_system.
Only one Python command can execute at a time; a pipeline requiring two Python
interpreters is unsupported.

Generic script and `-c` execution have the App's permissions. This command
integration does not restrict execution to bundled trusted script identifiers
and is not a malicious-code sandbox. No host device objects or credentials are
passed to Python. Network activity is not isolated by this adapter.

`CPythonBridge` initializes on its dedicated OS thread, serializes invocations,
releases the GIL while idle and keeps the interpreter alive for the process
lifetime. Each command receives fresh globals and its own duplicated streams.
The bootstrap restores argv, module search paths, standard streams, current
directory and changes through `os.environ` after execution. Module caches and
arbitrary process side effects remain shared; this is not a clean process reset.

Tracing and `actell_runtime.check_cancelled()` provide cooperative cancellation.
Scripts can report throttled progress to stderr with
`actell_runtime.report_progress(fraction, message)`. The host never kills the
Python worker or injects asynchronous exceptions. While it is active, the shell
watchdog requests cancellation instead of invoking ios_system's pthread kill.
Long native operations, blocking IO, deliberate trace removal or swallowed
interrupts can delay or prevent cancellation. The command lane stays occupied
until actual return; a timeout is not a hard stop. Existing command output limits
apply, and stdout/stderr are continuously drained, including truncated output.

## Dependency preparation

`ios-app/PythonRuntime/runtime-lock.json` pins each download URL, filename,
platform and SHA-256. The support package is published by
[Python-Apple-support](https://github.com/beeware/Python-Apple-support/releases/tag/3.13-b18),
Pillow comes from [PyPI](https://pypi.org/project/pillow/13.0.0/), and NumPy comes
from the [BeeWare index](https://pypi.anaconda.org/beeware/simple/numpy/).
The NumPy version is an index-specific build, not a claim about an upstream
NumPy release with the same version.

```sh
python3 ios-app/scripts/prepare_python_runtime.py
```

Use Python 3.12 or later on the build host for safe tar extraction.

Preparation checks archive hashes, wheel tags, complete RECORD coverage,
per-file hashes, required dependencies, Mach-O platform/CPU and native library
dependencies. Unknown external dynamic libraries fail validation. Artifacts and
audit output stay under ignored `.build/`; the linking XCFramework is copied to
ignored `ios-app/CommandKit/Artifacts/` before SwiftPM resolution. The App build
phase packages from the default `.build/python-runtime` cache. If using a custom
`--cache`, supply the same path to both preparation and packaging; the standard
App build phase uses the default path.

## App build and acceptance

Prepare dependencies before opening/resolving the project, then generate the
project and use the standard App build and test entries. The App build phase
packages Python resources for the selected SDK and signs native frameworks
after conversion. There are no downloads at App launch.

`ExecutionToolTests` exercises the actual command adapter: file execution with
arguments and a ten-second countdown, Pillow/NumPy native operations, stdin
pipes, output redirection, `-m`, exit codes, exceptions, environment restoration,
cooperative timeout/reuse and bounded binary output. The existing default test
target retains authorization, session isolation and recovery coverage.

The packager combines shared and platform-specific standard libraries, selects
the matching wheel set, converts extension modules into individual frameworks
with `.fwork` and `.origin` markers, and signs only after conversion. It rejects
loose native binaries and unexpected symlinks. NumPy's two downstream link-time
archives are explicitly excluded; runtime extension modules and license files
remain bundled. No binary platform markers are modified.

## Remaining acceptance limits

Simulator success and unsigned device builds do not establish signed physical
device import, Release Archive compliance, thermal behavior or App Store
acceptance. These gates remain separate from simulator regression tests.

The BeeWare NumPy wheel's exact build-source revision and patch set still need
source provenance review; wheel metadata and dynamic dependency checks alone do
not provide that mapping. Signed physical-device and redistribution acceptance
remain separate from local command integration. Missing provenance must remain
visible rather than silently replacing NumPy or claiming its source was audited.

File outputs are ordinary files in the command's working directory, with the
same permissions and retention behavior as other commands; there is no additional
Python job store or automatic attachment import. File/array memory consumption
is not bounded by the shell log limit. App background suspension can interrupt
execution, and recovery never automatically replays the command. The original
painting planner still requires adaptation and renderer comparison; numerical
tests are not a substitute for that acceptance.
