"""Cooperative checkpoints for command scripts, not a security boundary."""
import json
import sys
import time

from _actell_host import check_cancelled

_last_progress = 0.0


def report_progress(fraction, message=''):
    global _last_progress
    check_cancelled()
    fraction = float(fraction)
    if not 0 <= fraction <= 1:
        raise ValueError('Progress must be between zero and one')
    now = time.monotonic()
    if fraction == 1 or now - _last_progress >= 0.25:
        print(json.dumps({'progress': fraction, 'message': str(message)[:512]}), file=sys.stderr)
        _last_progress = now
