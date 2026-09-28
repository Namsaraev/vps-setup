"""Test-only injection at the replacement operations used by configure_pin."""
import os
import sys

program = sys.argv[2]
sys.argv = ['-c'] + sys.argv[3:]
if sys.argv[1] == 'key' and sys.argv[-1] != 'check':
    token = {'temp': 'os.fchmod(f, mode)', 'keys': 'os.fchmod(f, mode)',
             'directory': 'os.fchmod(d, 0o700)', 'chown': 'os.fchown(f, uid, gid)',
             'mv': 'os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd)'}.get(os.environ.get('FAILURE', ''))
    if token:
        program = program.replace(token, '(_ for _ in ()).throw(OSError("injected metadata/replace failure"))')
    program = program.replace('os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd)',
                              'os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd); print("MV")')
exec(compile(program, '<production-access-helper>', 'exec'))
