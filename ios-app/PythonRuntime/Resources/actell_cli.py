"""Noninteractive command adapter for the single embedded interpreter.

This is ordinary process-local Python, with the app's filesystem permissions.
It is not a sandbox and intentionally provides no host/device/credential bridge.
"""
import io
import os
import runpy
import sys
import traceback
import types

import _actell_host

HELP = '''Usage: python3 [-u] [-B] [-V | --version] [-c code | -m module | script.py | -] [args...]
Embedded CPython with preinstalled Pillow and NumPy. No interactive REPL,
package installation, subprocesses, or hard termination guarantee.
Runs with Actell's app permissions; this is not a code sandbox.
'''


def _execute(arguments, stdin, stdout):
    args = list(arguments[1:])
    while args and args[0] in ('-u', '-B'):
        args.pop(0)
    if args and args[0] in ('-V', '--version'):
        stdout.write('Python ' + sys.version.split()[0] + '\n')
        return 0
    if args and args[0] in ('-h', '--help'):
        stdout.write(HELP)
        return 0
    if not args:
        raise ValueError('Interactive Python is unavailable; provide a script, -c, -m or -.')
    mode = args.pop(0)
    main = types.ModuleType('__main__')
    sys.modules['__main__'] = main
    namespace = main.__dict__
    namespace.update(__package__=None, __spec__=None, __builtins__=__builtins__)
    if mode in ('-c', '-m'):
        if not args:
            raise ValueError(mode + ' requires an argument')
        source = args.pop(0)
        sys.argv = [source if mode == '-m' else '-c', *args]
        sys.path.insert(0, os.getcwd())
        if mode == '-m':
            if source == 'pip' or source.startswith('pip.'):
                raise ValueError('Package installation is unavailable; dependencies are bundled at build time.')
            runpy.run_module(source, run_name='__main__', alter_sys=True)
        else:
            exec(compile(source, '<string>', 'exec'), namespace, namespace)
    elif mode == '-':
        sys.argv = ['-', *args]
        sys.path.insert(0, os.getcwd())
        exec(compile(stdin.read(), '<stdin>', 'exec'), namespace, namespace)
    elif mode.startswith('-'):
        raise ValueError('Unsupported Python option: ' + mode)
    else:
        path = os.path.abspath(mode)
        sys.argv = [mode, *args]
        sys.path.insert(0, os.path.dirname(path))
        namespace['__file__'] = path
        with open(path, 'rb') as stream:
            code = compile(stream.read(), path, 'exec')
        exec(code, namespace, namespace)
    return 0


def run(arguments, input_fd, output_fd, error_fd, directory):
    # dup once more: this layer owns wrappers, the host owns the passed FDs.
    streams = []
    old = (sys.argv, sys.path[:], sys.stdin, sys.stdout, sys.stderr,
           sys.__stdin__, sys.__stdout__, sys.__stderr__, sys.gettrace(), os.getcwd())
    environment = dict(os.environ)
    main_module = sys.modules.get('__main__')
    try:
        for fd, mode in ((input_fd, 'rb'), (output_fd, 'wb'), (error_fd, 'wb')):
            raw = os.fdopen(os.dup(fd), mode, buffering=0)
            streams.append(io.TextIOWrapper(raw, encoding='utf-8', errors='replace',
                                           line_buffering=True, write_through=True))
        sys.stdin, sys.stdout, sys.stderr = streams
        sys.__stdin__, sys.__stdout__, sys.__stderr__ = streams
        os.chdir(directory)
        _actell_host.check_cancelled()
        _actell_host.enable_trace()
        return _execute(arguments, streams[0], streams[1])
    except SystemExit as error:
        if error.code is None:
            return 0
        if isinstance(error.code, int):
            return error.code & 255
        print(error.code, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('Python command cancelled.', file=sys.stderr)
        return 130
    except BaseException:
        traceback.print_exc(file=sys.stderr)
        return 1
    finally:
        sys.settrace(None)
        for stream in streams:
            try:
                stream.close()
            except (OSError, ValueError):
                pass
        (sys.argv, path, sys.stdin, sys.stdout, sys.stderr,
         sys.__stdin__, sys.__stdout__, sys.__stderr__, trace, cwd) = old
        sys.path[:] = path
        if main_module is None:
            sys.modules.pop('__main__', None)
        else:
            sys.modules['__main__'] = main_module
        os.chdir(cwd)
        for key in set(os.environ) | set(environment):
            if key not in environment:
                os.environ.pop(key, None)
            elif os.environ.get(key) != environment[key]:
                os.environ[key] = environment[key]
        sys.settrace(trace)
