"""Run the real embedded Python writer with one filesystem fault (tests only)."""
import os
import stat
import sys
from contextlib import ExitStack
from unittest.mock import patch


def run():
    assert sys.argv[1] == '-c'
    program = sys.argv[2]
    sys.argv = ['-c'] + sys.argv[3:]
    target = sys.argv[1]
    failure = os.environ.get('ATOMIC_FAILURE', '')
    select = os.environ.get('ATOMIC_TARGET', '')
    if select and not target.endswith(select):
        failure = ''
    # Existing propagation suites retain their per-call failures, now injected
    # at the actual staged write instead of obsolete cat/sed/append calls.
    legacy = os.environ.get('FAILURE', '') or os.environ.get('MODE', '')
    if not failure and not select:
        if legacy in ('write', 'partial'):
            failure = 'write'
        if legacy in ('grep', 'sed', 'append') and target.endswith('/sshd_config'):
            failure = {'grep': 'read', 'sed': 'write', 'append': 'write'}[legacy]
        if legacy == 'hardening-write' and target.endswith('/00-vps-hardening.conf'):
            failure = 'write'
        if legacy == 'socket-write' and target.endswith('/99-vps-port.conf'):
            failure = 'write'
        for area, suffix in (('modules', '/tcp_bbr.conf'), ('sysctl', '/99-vps-tuning.conf'),
                             ('limits', '/99-vps.conf')):
            if legacy in ('write-' + area, 'partial-' + area) and target.endswith(suffix):
                failure = 'write'
    if failure == 'python':
        sys.exit(23)

    real_open, real_fdopen, real_fsync = os.open, os.fdopen, os.fsync
    real_replace, real_unlink = os.replace, os.unlink
    reads = 0

    def fail(*args, **kwargs):
        raise OSError('injected ' + failure)

    def opened(name, flags, *args, **kwargs):
        if failure == 'temp_open' and flags & os.O_CREAT:
            fail()
        if failure == 'source_open' and not flags & (os.O_CREAT | os.O_DIRECTORY):
            fail()
        return real_open(name, flags, *args, **kwargs)

    class Stream:
        def __init__(self, descriptor, mode):
            self.stream = real_fdopen(descriptor, mode)
            self.writable = '+' in mode

        def __enter__(self):
            self.stream.__enter__()
            return self

        def __exit__(self, *args):
            return self.stream.__exit__(*args)

        def __getattr__(self, name):
            return getattr(self.stream, name)

        def read(self, *args):
            nonlocal reads
            if not self.writable:
                reads += 1
                if failure == 'read' or (failure == 'post_read' and reads == 3):
                    fail()
            data = self.stream.read(*args)
            if failure == 'short_read' and not self.writable:
                return data[:1]
            if failure == 'stage_read' and self.writable:
                return b'corrupt'
            return data

        def write(self, data):
            if failure in ('write', 'short_write', 'cleanup'):
                self.stream.write(data[:1])
                if failure == 'short_write':
                    return 1
                fail()
            return self.stream.write(data)

        def flush(self):
            if failure == 'flush':
                fail()
            return self.stream.flush()

    def synced(descriptor):
        directory = stat.S_ISDIR(os.fstat(descriptor).st_mode)
        if failure == ('dir_fsync' if directory else 'fsync'):
            fail()
        return real_fsync(descriptor)

    def replaced(*args, **kwargs):
        if failure == 'replace':
            fail()
        real_replace(*args, **kwargs)
        if os.environ.get('ATOMIC_LOG'):
            with open(os.environ['ATOMIC_LOG'], 'a', encoding='utf-8') as log:
                log.write(target + '\n')

    def unlinked(*args, **kwargs):
        if failure == 'cleanup':
            fail()
        return real_unlink(*args, **kwargs)

    with ExitStack() as stack:
        for name, replacement in (('open', opened), ('fdopen', Stream), ('fsync', synced),
                                  ('replace', replaced), ('unlink', unlinked)):
            stack.enter_context(patch.object(os, name, replacement))
        if failure in ('chown', 'chmod'):
            stack.enter_context(patch.object(os, 'f' + failure, fail))
        exec(compile(program, '<atomic_config>', 'exec'), {'__name__': '__main__'})


if __name__ == '__main__':
    run()
