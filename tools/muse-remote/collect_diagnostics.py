#!/usr/bin/env python3
"""Read existing local logs through native CLI tools; never contacts a device."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

STATE_FIELDS = {
    'connection', 'route', 'status', 'body_bytes', 'phase', 'authenticated',
    'key_state', 'foreground', 'protected_data', 'scene', 'service_active',
    'service_background', 'journal_healthy', 'active_run', 'active_call',
    'draining', 'busy_sessions', 'saved_enabled', 'app_version', 'app_build',
    'underlying_domain', 'underlying_code', 'handler_in_flight',
    'selected_route', 'control_route', 'control_ready', 'control_running',
    'control_reserved', 'control_pairing', 'control_has_record', 'control_background',
    'control_failure_present', 'background_enabled', 'background_selected',
    'background_desired', 'background_effective', 'background_continuity',
    'release_elapsed_ms',
    'call', 'delivery', 'geometry_reason', 'native_stage', 'native_cause',
}


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def extract(value):
    events = []
    for text in strings(value):
        for line in text.splitlines():
            match = re.search(r'(?:^|\s)stage=([a-z][a-z0-9_.]*)\s', line)
            if not match:
                continue
            event = {'stage': match.group(1)}
            for name in ('diagnostic', 'client', 'run'):
                tag = re.search(r'\b' + name + r'=([0-9a-f]{16})(?=\s|$)', line)
                if tag:
                    event[name] = tag.group(1)
            code = re.search(r'\bcode=([a-z][a-z0-9_]*)\b', line)
            if code:
                event['code'] = code.group(1)
            state = {}
            for key, item in re.findall(r'"([^"\n]+)"\s*:\s*"([^"\n]*)"', line):
                if key in STATE_FIELDS and re.fullmatch(r'[A-Za-z0-9_.:+/-]{0,120}', item):
                    state[key] = item
            event['state'] = state
            events.append(event)
    return events


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--result-bundle', type=Path, help='Existing Xcode Run/Test .xcresult')
    source.add_argument('--input', type=Path, help='Existing local console text or JSON')
    source.add_argument('--unified', action='store_true', help='Mac log store only, not iPhone logs')
    parser.add_argument('--last', default='30m', help='Unified log lookback, such as 30m')
    parser.add_argument('--output', type=Path, required=True, help='Ignored/private output file')
    args = parser.parse_args()
    report = {'status': 'source_unavailable', 'source': '', 'device_contacted': False, 'events': []}
    try:
        if args.input:
            report['source'] = str(args.input)
            raw = args.input.read_text()
        else:
            env = dict(os.environ)
            env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
            if args.result_bundle:
                report['source'] = str(args.result_bundle)
                command = ['xcrun', 'xcresulttool', 'get', 'log', '--path', str(args.result_bundle), '--type', 'console', '--compact']
            else:
                report['source'] = 'mac_unified_logging'
                command = ['/usr/bin/log', 'show', '--last', args.last, '--style', 'json', '--predicate',
                           'subsystem == "com.ja1chen.PhoneAgent" AND category == "MuseAdmission"']
            result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=30)
            if result.returncode:
                report['tool_exit'] = result.returncode
                report['reason'] = 'sandboxed' if 'Cannot run while sandboxed' in result.stderr else 'native_tool_failed'
                raw = None
            else:
                raw = result.stdout
        if raw is not None:
            try:
                value = json.loads(raw)
            except ValueError:
                value = raw
            report['events'] = extract(value)
            report['status'] = 'ok' if report['events'] else 'no_matching_events'
    except (OSError, subprocess.TimeoutExpired) as error:
        report['reason'] = type(error).__name__
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Do not persist an unfiltered console, exception text or native-tool stderr.
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({'status': report['status'], 'events': len(report['events']), 'output': str(args.output)}))
    return 0 if report['status'] == 'ok' else 2


if __name__ == '__main__':
    raise SystemExit(main())
