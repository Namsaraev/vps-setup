"""Extract the production writer; fault injection exists only in test processes."""
from pathlib import Path
import shlex
import sys

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
HELPER = 'atomic_config() {' + SOURCE.split('atomic_config() {', 1)[1].split('\nconfigure_unattended_upgrades()', 1)[0]
PROGRAM = HELPER.split("<<'PY_ATOMIC'\n", 1)[1].split('\nPY_ATOMIC', 1)[0]
WRAPPER = Path(__file__).with_name('atomic_faults.py')
INJECT = ('\npython3() { ' + shlex.quote(Path(sys.executable).as_posix()) + ' ' +
          shlex.quote(WRAPPER.as_posix()) + ' "$@"; }\n')
HELPER += INJECT
