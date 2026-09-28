"""Extract only the production access helper; never execute script startup."""
from pathlib import Path
import os
import shlex
import sys

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
HELPER = 'access_safety() {' + SOURCE.split('access_safety() {', 1)[1].split('\ncheck_ssh_port()', 1)[0]
PROGRAM = HELPER.split("<<'PY_ACCESS'\n", 1)[1].split('\nPY_ACCESS', 1)[0]
if os.name == 'nt':
    HELPER += '\npython3() { ' + shlex.quote(Path(sys.executable).as_posix()) + ' "$@"; }\n'
