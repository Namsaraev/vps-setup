#!/usr/bin/env bash
# tunevps.sh — первичная настройка Ubuntu VPS
# Запускайте: sudo bash tunevps.sh
set -o pipefail
export DEBIAN_FRONTEND=noninteractive

SSH_PORT=5829
PIN_USER="pin"
SWAP_RAM_THRESHOLD_MB=2048
SWAP_SIZE="2G"
P10K_REPOSITORY="https://github.com/romkatv/powerlevel10k.git"

# Маркер первого обновления (для выбора между full-upgrade и upgrade)
FIRST_UPDATE_MARKER="/var/lib/tunevps/.first-update-done"

# Глобальный флаг наличия ключа у pin
PIN_HAS_KEY=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "$BLUE[INFO]$NC $*"; }
ok() { echo -e "$GREEN[OK]$NC $*"; }
warn() { echo -e "$YELLOW[WARN]$NC $*"; }
error() { echo -e "$RED[ERROR]$NC $*" >&2; }
section() { echo -e "\n$CYAN========== $* ==========$NC"; }

ask() {
  printf '%s' "$1" > /dev/tty || return $?
  read -r "$2" < /dev/tty || return $?
  return 0
}
ask_password() {
  local prompt="$1" variable="$2" read_status=0 write_status=0
  printf '%s' "$prompt" > /dev/tty || {
    write_status=$?
    error "Не удалось вывести приглашение для пароля в /dev/tty"
    return "$write_status"
  }
  IFS= read -r -s "$variable" < /dev/tty || read_status=$?
  printf '\n' > /dev/tty || write_status=$?
  if [ "$read_status" -ne 0 ]; then
    error "Не удалось прочитать пароль из /dev/tty"
    return "$read_status"
  fi
  if [ "$write_status" -ne 0 ]; then
    error "Не удалось завершить ввод пароля в /dev/tty"
    return "$write_status"
  fi
  return 0
}
set_pin_password() {
  local password password_confirm
  while true; do
    ask_password "Введите пароль для $PIN_USER: " password || return $?
    ask_password "Повторите пароль: " password_confirm || return $?
    if [ -z "$password" ]; then
      warn "Пароль не может быть пустым"
    elif [ "$password" != "$password_confirm" ]; then
      warn "Пароли не совпадают"
    elif printf '%s:%s\n' "$PIN_USER" "$password" | chpasswd; then
      unset password password_confirm
      ok "Пароль для $PIN_USER установлен"
      return 0
    else
      unset password password_confirm
      error "Не удалось установить пароль; попробуйте ещё раз"
    fi
  done
}
pause() { local v; ask "Нажмите Enter для продолжения..." v; }
yes_by_default() { [[ -z "$1" || "$1" =~ ^[Yy]$ ]]; }

# SSH-only path, effective-context, persistence and evidence helpers.
access_safety() {
  local program
  program="$(command cat <<'PY_ACCESS'
import base64
import ipaddress
import json
import os
import re
import secrets
import shlex
import stat
import sys


def identity(s):
    return None if s is None else (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_gid,
                                   s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def directory(path):
    if not path.startswith('/') or '..' in path.split('/'):
        raise ValueError('Expected absolute path without parent traversal')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in filter(None, path.split('/')):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_at(fd, name):
    try:
        before = os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None, b''
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError('Expected regular non-linked file: ' + name)
    f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    with os.fdopen(f, 'rb') as stream:
        if identity(os.fstat(f)) != identity(before):
            raise ValueError('File changed during open: ' + name)
        data = stream.read()
        if identity(os.fstat(f)) != identity(before) or len(data) != before.st_size:
            raise ValueError('File changed during read: ' + name)
    return before, data


def same_directory(fd, path):
    check = directory(path)
    try:
        a, b = os.fstat(fd), os.fstat(check)
        if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
            raise ValueError('Parent directory changed: ' + path)
    finally:
        os.close(check)


def replace_at(fd, parent, name, old, data, uid, gid, mode, times=None):
    temp = '.tunevps-access-' + secrets.token_hex(16)
    try:
        f = os.open(temp, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(f, 'w+b') as stream:
            if stream.write(data) != len(data):
                raise OSError('Short staged write')
            stream.flush()
            os.fchown(f, uid, gid)
            os.fchmod(f, mode)
            if times is not None:
                os.utime(f, ns=tuple(times))
            os.fsync(f)
            stream.seek(0)
            if stream.read() != data:
                raise OSError('Staged bytes mismatch')
        now = read_at(fd, name)
        if identity(now[0]) != identity(old[0]) or now[1] != old[1]:
            raise ValueError('Target changed before replacement: ' + name)
        same_directory(fd, parent)
        os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd)
        temp = None
        os.fsync(fd)
        s, actual = read_at(fd, name)
        if actual != data or (s.st_uid, s.st_gid, stat.S_IMODE(s.st_mode)) != (uid, gid, mode):
            raise OSError('Live bytes/metadata verification failed: ' + name)
        if times is not None and s.st_mtime_ns != times[1]:
            raise OSError('Restored timestamp verification failed: ' + name)
        same_directory(fd, parent)
    finally:
        if temp is not None:
            try:
                os.unlink(temp, dir_fd=fd)
            except FileNotFoundError:
                pass


def key_path(home, uid, gid, action):
    h = directory(home)
    d = None
    try:
        hs = os.fstat(h)
        if hs.st_uid != uid or hs.st_mode & 0o022:
            raise ValueError('Unsafe home ownership or write permissions')
        try:
            d = os.open('.ssh', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=h)
        except FileNotFoundError:
            if action == 'check':
                return
            os.mkdir('.ssh', 0o700, dir_fd=h)
            d = os.open('.ssh', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=h)
            os.fchown(d, uid, gid)
        ds = os.fstat(d)
        if ds.st_uid != uid or ds.st_mode & 0o022:
            raise ValueError('Unsafe .ssh ownership or write permissions')
        old = read_at(d, 'authorized_keys')
        if old[0] and (old[0].st_uid != uid or old[0].st_mode & 0o022):
            raise ValueError('Unsafe authorized_keys ownership or write permissions')
        same_directory(h, home)
        same_directory(d, home + '/.ssh')
        if action == 'check':
            return
        key = sys.stdin.buffer.read()
        if not key or b'\x00' in key:
            raise ValueError('Empty or invalid key input')
        data = key if action == 'replace' else old[1] + (b'\n' if old[1] and not old[1].endswith(b'\n') else b'') + key
        os.fchmod(d, 0o700)
        replace_at(d, home + '/.ssh', 'authorized_keys', old, data, uid, gid, 0o600)
    finally:
        if d is not None:
            os.close(d)
        os.close(h)


def effective_path(home, user, context=''):
    text = sys.stdin.read()
    if context == 'checked-context':
        # OpenSSH itself expands Includes and parses Match. Its debug trace
        # exposes every Match expression, including non-matching branches.
        # Refuse connection-dependent conditions rather than treating one
        # synthetic/current peer as proof for other clients. Unknown trace
        # formats/versions fail closed; this is not an sshd_config parser.
        version = re.search(r'^debug1: sshd version OpenSSH_(8\.9|9\.[0-9]+|10\.2)[, ]', text, re.M)
        if not version:
            raise ValueError('Unsupported OpenSSH Match trace; inspect sshd -T -C manually before retrying')
        if 'debug2: parse_server_config_depth:' not in text:
            raise ValueError('Missing OpenSSH configuration parse trace')
        for field, allowed in (('pubkeyauthentication', {'yes'}), ('authenticationmethods', {'any', 'publickey'})):
            values = [l.split(maxsplit=1)[1] for l in text.splitlines() if l.startswith(field + ' ')]
            if len(values) != 1 or values[0] not in allowed:
                raise ValueError('Effective ' + field + ' does not confirm standalone public-key access')
        for line in text.splitlines():
            if 'checking syntax for ' not in line:
                continue
            # 10.2 adds the source line number; accept only its observed grammar.
            suffix = r" on line [1-9][0-9]*" if version[1] == "10.2" else ""
            match = re.fullmatch(r"debug3: checking syntax for 'Match (.*)'" + suffix + r"\r?", line, re.I)
            if not match:
                raise ValueError('Unsupported OpenSSH Match trace format')
            tokens = shlex.split(match[1])
            if [t.lower() for t in tokens] == ['all']:
                continue
            if not tokens or len(tokens) % 2 or any(t.lower() not in ('user', 'group') for t in tokens[::2]):
                raise ValueError('Connection-dependent/unsupported Match policy; verify key access and simplify Match before automatic password disabling')
    rows = [l.split()[1:] for l in text.splitlines() if l.startswith('authorizedkeysfile ')]
    if len(rows) != 1 or not rows[0]:
        raise ValueError('Missing or ambiguous effective AuthorizedKeysFile')
    paths = []
    for value in rows[0]:
        if value == 'none':
            continue
        if re.search(r'%(?![%hu])', value) or any(c in value for c in '*?"\\'):
            raise ValueError('Unsupported effective AuthorizedKeysFile token or path')
        value = re.sub(r'%([%hu])', lambda m: {'%': '%', 'h': home, 'u': user}[m[1]], value)
        paths.append(os.path.normpath(value if value.startswith('/') else home + '/' + value))
    if os.path.normpath(home + '/.ssh/authorized_keys') not in paths:
        raise ValueError('Effective AuthorizedKeysFile excludes installed key path')


def properties(text):
    result = {}
    for line in text.splitlines():
        key, sep, value = line.partition('=')
        if not sep:
            raise ValueError('Malformed systemd evidence')
        result.setdefault(key, []).append(value)
    return result


def one(p, key):
    if len(p.get(key, [])) != 1:
        raise ValueError('Missing/ambiguous systemd property: ' + key)
    return p[key][0]


def endpoints(p):
    result = []
    for value in p.get('Listen', []):
        for address, kind in re.findall(r'(\S+) \((\w+)\)', value):
            if kind != 'Stream':
                raise ValueError('Unsupported non-stream socket policy')
            match = re.fullmatch(r'(\[[0-9a-fA-F:]+\]|[0-9.]+):(\d+)', address)
            if not match:
                raise ValueError('Unsupported socket address; inspect systemctl cat ssh.socket')
            ipaddress.ip_address(match[1].strip('[]'))
            result.append((match[1], match[2]))
        if not value or ' '.join(a + ' (' + k + ')' for a, k in re.findall(r'(\S+) \((\w+)\)', value)) != value:
            raise ValueError('Ambiguous systemd Listen evidence')
    if not result or len(set(result)) != len(result):
        raise ValueError('Empty or duplicate socket policy')
    return result


def socket_plan(port):
    p = properties(sys.stdin.read())
    load, active, enabled = one(p, 'LoadState'), one(p, 'ActiveState'), one(p, 'UnitFileState')
    if active == 'inactive' and enabled in ('disabled', 'masked', '') and load in ('loaded', 'not-found', 'masked'):
        print('service')
        return
    if load != 'loaded' or active not in ('active', 'inactive') or enabled not in ('enabled', 'enabled-runtime', 'disabled', 'static', 'generated'):
        raise ValueError('Ambiguous ssh.socket state; inspect systemctl status ssh.socket')
    if one(p, 'Accept') != 'no' or one(p, 'Triggers') != 'ssh.service':
        raise ValueError('Unsupported socket activation target')
    if one(p, 'NeedDaemonReload') != 'no':
        raise ValueError('Stale systemd configuration; review/reload units before retrying')
    for path in one(p, 'DropInPaths').split():
        if os.path.basename(path) > '99-vps-port.conf':
            raise ValueError('Later socket drop-in could override managed policy: ' + path)
    entries = endpoints(p)
    if len({p for _, p in entries}) != 1:
        raise ValueError('Multiple existing ports; configure ssh.socket explicitly')
    print('socket')
    print('[Socket]\nListenStream=')
    for address, _ in entries:
        print('ListenStream=' + address + ':' + port)


def listener(port, service, socket):
    rows = [l for l in sys.stdin.read().splitlines() if len(l.split()) >= 4 and l.split()[3].endswith(':' + port)]
    if not rows:
        return 1
    s, p = properties(service), properties(socket)
    pid = one(s, 'MainPID')
    service_ok = (one(s, 'LoadState') == 'loaded' and one(s, 'ActiveState') == 'active'
                  and pid.isdigit() and int(pid) > 1 and 'path=/usr/sbin/sshd ;' in one(s, 'ExecStart'))
    socket_ok = one(p, 'LoadState') == 'loaded' and one(p, 'ActiveState') == 'active'
    if socket_ok:
        socket_ok = one(p, 'Triggers') == 'ssh.service' and one(p, 'Accept') == 'no'
        allowed = {a + ':' + n for a, n in endpoints(p)} if socket_ok else set()
    else:
        allowed = set()
    for row in rows:
        owners = re.findall(r'pid=(\d+),', row)
        if not owners:
            return 2
        endpoint = row.split()[3]
        if endpoint == '*:' + port and '[::]:' + port in allowed:
            endpoint = '[::]:' + port
        if not all((service_ok and owner == pid) or (owner == '1' and socket_ok and endpoint in allowed) for owner in owners):
            return 4
    return 0


def snapshot_files(paths):
    records = []
    for path in paths:
        parent, name = os.path.split(path)
        try:
            fd = directory(parent)
        except FileNotFoundError:
            records.append([path, None, ''])
            continue
        try:
            s, data = read_at(fd, name)
            records.append([path, [s.st_uid, s.st_gid, stat.S_IMODE(s.st_mode), [s.st_atime_ns, s.st_mtime_ns]] if s else None,
                            base64.b64encode(data).decode()])
        finally:
            os.close(fd)
    print(json.dumps(records))


def restore_files():
    failures = []
    for path, meta, encoded in json.loads(sys.stdin.read()):
        parent, name = os.path.split(path)
        try:
            try:
                fd = directory(parent)
            except FileNotFoundError:
                if meta is None:
                    continue
                raise
            try:
                old = read_at(fd, name)
                same_directory(fd, parent)
                if meta is None:
                    if old[0] is not None:
                        os.unlink(name, dir_fd=fd)
                        os.fsync(fd)
                    if read_at(fd, name)[0] is not None:
                        raise OSError('Expected restored absence')
                else:
                    replace_at(fd, parent, name, old, base64.b64decode(encoded), *meta)
            finally:
                os.close(fd)
        except (ValueError, OSError):
            failures.append(path)
    if failures:
        raise ValueError('FATAL: SSH rollback failed: ' + ', '.join(failures))


def ufw_order(port):
    text = sys.stdin.read()
    if not text.startswith('Status: active\n'):
        raise ValueError('Expected active numbered UFW state')
    seen_allow = set()
    rules = 0
    for line in text.splitlines():
        if not line.lstrip().startswith('['):
            continue
        match = re.fullmatch(r'\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW|DENY|REJECT|LIMIT)(?: IN)?\s+(.+?)(?:\s+#.*)?', line)
        if not match:
            raise ValueError('Unsupported UFW rule; inspect ufw status numbered')
        rules += 1
        destination, action, source = match[2].strip(), match[3], match[4].strip()
        family = 6 if '(v6)' in destination else 4
        destination = destination.replace(' (v6)', '')
        source = source.replace(' (v6)', '')
        # An earlier unknown deny may be an app profile/range/interface rule.
        # Do not infer non-conflict from a display alias we cannot resolve.
        harmless = re.fullmatch(r'(\d+)(?:/(tcp|udp))?', destination)
        unrelated = harmless and (harmless[1] != port or harmless[2] == 'udp')
        if action in ('DENY', 'REJECT', 'LIMIT') and family not in seen_allow and not unrelated:
            raise ValueError('Earlier UFW blocking/ambiguous rule ' + match[1] + '; inspect ufw status numbered and place a scoped SSH allow before it')
        if destination == port + '/tcp' and action == 'ALLOW' and source == 'Anywhere':
            seen_allow.add(family)
    # IPv6 coverage is required only if numbered output contains IPv6 rules.
    needed = {4, 6} if '(v6)' in text else {4}
    return 0 if needed <= seen_allow else 1


try:
    op, *args = sys.argv[1:]
    result = 0
    if op == 'key':
        key_path(args[0], int(args[1]), int(args[2]), args[3])
    elif op == 'effective':
        effective_path(*args)
    elif op == 'socket':
        socket_plan(*args)
    elif op == 'listener':
        result = listener(*args)
    elif op == 'snapshot':
        snapshot_files(args)
    elif op == 'restore':
        restore_files()
    elif op == 'ufw':
        result = ufw_order(*args)
    else:
        raise ValueError('Unknown access safety operation')
    sys.exit(result)
except (OSError, ValueError, KeyError) as exc:
    # Never include input content or key bytes in diagnostics.
    print('Access safety check failed: ' + str(exc), file=sys.stderr)
    sys.exit(2)
PY_ACCESS
)" || return 2
  python3 -c "$program" "$@"
}

check_ssh_port() {
  # 0 = expected SSH listener, 1 = absent, 2 = probe failure, 4 = foreign.
  local listeners service socket
  listeners="$(ss -ltnp)" || return 2
  service="$(systemctl show ssh.service -p LoadState -p ActiveState -p MainPID -p ExecStart)" || return 2
  socket="$(systemctl show ssh.socket -p LoadState -p ActiveState -p Listen -p Triggers -p Accept)" || return 2
  access_safety listener "$SSH_PORT" "$service" "$socket" <<< "$listeners"

}

if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

CURRENT_USER="$SUDO_USER"
[ -n "$CURRENT_USER" ] || CURRENT_USER=root
if ! id "$CURRENT_USER" >/dev/null 2>&1; then
  error "Не удалось определить пользователя, запустившего скрипт"
  exit 1
fi
if ! passwd_entry="$(getent passwd "$CURRENT_USER")"; then
  error "Не удалось получить passwd-запись пользователя $CURRENT_USER"
  exit 1
fi
if [[ "$passwd_entry" == *$'\n'* || ! "$passwd_entry" =~ ^([^:]+):[^:]*:[0-9]+:[0-9]+:[^:]*:([^:]+):[^:]*$ ]]; then
  error "Некорректная passwd-запись пользователя $CURRENT_USER"
  exit 1
fi
if [ "${BASH_REMATCH[1]}" != "$CURRENT_USER" ]; then
  error "Получена passwd-запись другого пользователя"
  exit 1
fi
USER_HOME="${BASH_REMATCH[2]}"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  error "Не найдена домашняя директория пользователя $CURRENT_USER"
  exit 1
fi

. /etc/os-release
case "$ID" in
  ubuntu) ;;
  *) error "Поддерживается только Ubuntu, обнаружено: $PRETTY_NAME"; exit 1 ;;
esac
ARCH="$(uname -m)"
info "Ubuntu $VERSION_ID ($VERSION_CODENAME), $ARCH"
info "Окружение будет настроено для $CURRENT_USER: $USER_HOME"

# Return 0: minimized, 1: not minimized, 2: probe failure.
detect_minimized() {
  local packages probe_status
  # Query the database without a package filter: an absent ubuntu-standard is
  # normal, whereas a failed database query must not look like an absent package.
  if ! packages=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n'); then
    error "Не удалось проверить пакеты для определения Ubuntu minimized"
    return 2
  fi
  case $'\n'"$packages"$'\n' in
    *$'\nubuntu-standard installed\n'*) return 1 ;;
  esac
  if [ -f /etc/dpkg/dpkg.cfg.d/excludes ]; then
    if grep -q 'path-exclude' /etc/dpkg/dpkg.cfg.d/excludes; then
      return 0
    else
      probe_status=$?
      if [ "$probe_status" -ne 1 ]; then
        error "Не удалось прочитать excludes для определения Ubuntu minimized"
        return 2
      fi
    fi
  fi
  local tool
  for tool in man less; do
    if command -v "$tool" >/dev/null 2>&1; then
      return 1
    else
      probe_status=$?
      if [ "$probe_status" -ne 1 ]; then
        error "Не удалось проверить $tool для определения Ubuntu minimized"
        return 2
      fi
    fi
  done
  return 0
}
IS_MINIMIZED=false
if detect_minimized; then
  IS_MINIMIZED=true
else
  minimized_status=$?
  [ "$minimized_status" -eq 1 ] || exit "$minimized_status"
fi

part1_update() {
  section "ЧАСТЬ 1: ОБНОВЛЕНИЕ И UNMINIMIZE"
  if [ "$IS_MINIMIZED" = true ]; then
    warn "Обнаружена Ubuntu minimized"
    local answer unminimize_status minimized_status
    if ! ask "Преобразовать в обычную Ubuntu через unminimize? [Y/n]: " answer; then
      error "Не удалось прочитать ответ о запуске unminimize"
      return 1
    fi
    if yes_by_default "$answer"; then
      apt-get update || { error "apt-get update завершился с ошибкой"; return 1; }
      if command -v unminimize >/dev/null 2>&1; then
        :
      else
        unminimize_status=$?
        if [ "$unminimize_status" -ne 1 ]; then
          error "Не удалось проверить наличие unminimize"
          return 1
        fi
        apt-get install -y unminimize || { error "Не удалось установить unminimize"; return 1; }
      fi
      set +o pipefail
      yes | unminimize
      unminimize_status="${PIPESTATUS[1]}"
      set -o pipefail
      minimized_status=1
      if [ "$unminimize_status" -ne 0 ]; then
        if detect_minimized; then
          minimized_status=0
        else
          minimized_status=$?
          [ "$minimized_status" -eq 1 ] || return "$minimized_status"
        fi
      fi
      if [ "$unminimize_status" -eq 0 ] || [ "$minimized_status" -eq 1 ]; then
        IS_MINIMIZED=false
        ok "unminimize завершён"
      else
        error "unminimize завершился с кодом $unminimize_status"
        warn "Проверьте: dpkg-query -W ubuntu-standard; cat /etc/dpkg/dpkg.cfg.d/excludes"
        return 1
      fi
    fi
  fi

  apt-get update || { error "apt-get update завершился с ошибкой"; return 1; }

  if [ ! -f "$FIRST_UPDATE_MARKER" ]; then
    info "ПЕРВОЕ обновление системы — используем full-upgrade"
    apt-get full-upgrade -y || { error "apt-get full-upgrade завершился с ошибкой"; return 1; }
    mkdir -p "$(dirname "$FIRST_UPDATE_MARKER")" || { error "Не удалось создать каталог маркера обновления"; return 1; }
    touch "$FIRST_UPDATE_MARKER" || { error "Не удалось создать маркер обновления"; return 1; }
  else
    info "ПОВТОРНОЕ обновление системы — используем upgrade"
    apt-get upgrade -y || { error "apt-get upgrade завершился с ошибкой"; return 1; }
  fi

  local answer
  if ! ask "Перезагрузить сервер сейчас? [Y/n]: " answer; then
    error "Не удалось прочитать ответ о перезагрузке"
    return 1
  fi
  if yes_by_default "$answer"; then
    warn "Перезагрузка через 5 секунд"
    sleep 5 || { error "Не удалось выдержать задержку перед перезагрузкой"; return 1; }
    reboot || { error "Не удалось перезагрузить сервер"; return 1; }
  else
    info "Перезагрузка отложена по вашему выбору"
  fi
  ok "Пакеты обновлены"
  return 0
}

install_packages() {
  section "БАЗОВЫЕ ПАКЕТЫ"
  apt-get update || { error "apt-get update завершился с ошибкой"; return 1; }

  if ! apt-get install -y nano git curl wget unzip jq htop tmux net-tools dnsutils \
    bat fd-find ripgrep fzf python3 python3-pip python3-venv build-essential \
    btop mtr-tiny iperf3 zsh sysbench ca-certificates gnupg \
    ncdu iotop ufw unattended-upgrades needrestart locales; then
    error "Не удалось установить базовые пакеты"
    return 1
  fi

  if [ -e /dev/hwrng ]; then
    info "Обнаружен /dev/hwrng — устанавливаем rng-tools5"
    apt-get install -y rng-tools5 || warn "Не удалось установить optional-пакет rng-tools5; продолжаем"
  else
    info "Аппаратный RNG не обнаружен — rng-tools5 не требуется"
  fi

  for package in eza zoxide; do
    if apt-cache show "$package" >/dev/null 2>&1; then
      apt-get install -y "$package" || warn "Не удалось установить optional-пакет $package; продолжаем"
    else
      warn "Пакет $package недоступен или не удалось проверить его доступность; пропуск"
    fi
  done
  ln -sf /usr/bin/batcat /usr/local/bin/bat || warn "Не удалось создать symlink /usr/local/bin/bat для batcat; продолжаем"
  ln -sf /usr/bin/fdfind /usr/local/bin/fd || warn "Не удалось создать symlink /usr/local/bin/fd для fdfind; продолжаем"
  return 0
}

configure_locale_time() {
  section "ВРЕМЯ И ЛОКАЛЬ"
  timedatectl set-timezone Asia/Irkutsk || { error "Не удалось настроить часовой пояс Asia/Irkutsk"; return 1; }
  locale-gen ru_RU.UTF-8 en_US.UTF-8 || { error "Не удалось сгенерировать локали ru_RU.UTF-8 en_US.UTF-8"; return 1; }
  update-locale LANG=ru_RU.UTF-8 || { error "Не удалось установить локаль LANG=ru_RU.UTF-8"; return 1; }
  ok "Часовой пояс и локаль настроены"
}

# Single-file persistence only: no rollback of earlier files or runtime changes.
# text reads stdin; fstab/sshd/zshrc transform a fully read snapshot.
# --user runs the same writer as CURRENT_USER (never root in a writable home).
atomic_config() {
  local user=false program
  if [ "${1-}" = --user ]; then user=true; shift; fi
  program="$(command cat <<'PY_ATOMIC'
import os
import re
import secrets
import stat
import sys


def transform(original, kind, args):
    if kind == "text":
        return sys.stdin.buffer.read()
    if kind == "fstab":
        source = os.fsencode(args[0])
        correct = source + b" none swap sw 0 0\n"
        rows = original.splitlines(keepends=True)
        managed = lambda row: len(row.split()) >= 3 and row.split()[0] == source and row.split()[2] == b"swap"
        matches = [row for row in rows if managed(row)]
        if matches == [correct]:
            return original
        result = b"".join(row for row in rows if not managed(row))
        return result + (b"\n" if result and not result.endswith(b"\n") else b"") + correct
    if kind == "sshd":
        name, value = map(os.fsencode, args)
        pattern = re.compile(rb"^#?" + re.escape(name) + rb"[ \t]+[^\r\n]*", re.M)
        line = name + b" " + value
        if pattern.search(original):
            return pattern.sub(lambda match: line, original)
        return original + (b"\n" if original and not original.endswith(b"\n") else b"") + line + b"\n"
    if kind == "zshrc":
        begin = b"# >>> tunevps managed block >>>"
        end = b"# <<< tunevps managed block <<<"
        block = begin + b'\nsource "$HOME/.config/tunevps/zshrc"\n' + end + b"\n"
        lines = original.splitlines(keepends=True)
        starts = [i for i, line in enumerate(lines) if line.rstrip(b"\r\n") == begin]
        ends = [i for i, line in enumerate(lines) if line.rstrip(b"\r\n") == end]
        if not starts and not ends:
            return block + original
        if len(starts) == len(ends) == 1 and starts[0] < ends[0]:
            return b"".join(lines[:starts[0]]) + block + b"".join(lines[ends[0] + 1:])
        raise ValueError("Invalid or duplicate tunevps managed markers; .zshrc unchanged")
    raise ValueError("Unknown configuration transform")


def open_parent(path):
    # Anchor every component, refusing symlinks even in parent directories.
    if not os.path.isabs(path) or ".." in path.split("/"):
        raise ValueError("Expected an absolute configuration path without '..'")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.split("/")[1:-1]:
            if not part:
                continue
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def snapshot(directory, name, missing=False):
    try:
        metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        if missing:
            return None, b""
        raise
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("Configuration must be a regular file: " + name)
    descriptor = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
    with os.fdopen(descriptor, "rb") as stream:
        actual = os.fstat(stream.fileno())
        if identity(actual) != identity(metadata):
            raise ValueError("Configuration changed while opening: " + name)
        data = stream.read()
        if identity(os.fstat(stream.fileno())) != identity(metadata) or len(data) != metadata.st_size:
            raise ValueError("Configuration changed or short read: " + name)
    return metadata, data


def identity(metadata):
    if metadata is None:
        return None
    return (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_uid,
            metadata.st_gid, metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)


def persist(path, kind, args):
    directory = open_parent(path)
    name = os.path.basename(path)
    temporary = None
    replaced = False
    try:
        metadata, original = snapshot(directory, name, kind in ("text", "zshrc"))
        updated = transform(original, kind, args)
        if kind != "text" and transform(updated, kind, args) != updated:
            raise ValueError("Configuration transform is not idempotent")
        if metadata is not None and updated == original:
            return
        candidate = ".tunevps-" + secrets.token_hex(16)
        descriptor = os.open(candidate, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
        temporary = candidate
        with os.fdopen(descriptor, "w+b") as stream:
            if stream.write(updated) != len(updated):
                raise OSError("Short configuration write")
            stream.flush()
            # Ownership precedes chmod (chown may clear permission bits).
            if metadata is not None:
                os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode) if metadata else 0o644)
            os.fsync(stream.fileno())
            stream.seek(0)
            if stream.read() != updated:
                raise OSError("Staged configuration verification failed")
        current, contents = snapshot(directory, name, metadata is None)
        if identity(current) != identity(metadata) or contents != original:
            raise ValueError("Configuration changed before replacement")
        # A renamed/replaced parent must not turn a successful write into an
        # update of a detached directory. dir_fd still prevents redirection.
        check = open_parent(path)
        try:
            before, now = os.fstat(directory), os.fstat(check)
            if (before.st_dev, before.st_ino) != (now.st_dev, now.st_ino):
                raise ValueError("Configuration parent changed before replacement")
        finally:
            os.close(check)
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        temporary = None
        replaced = True
        os.fsync(directory)
        final, contents = snapshot(directory, name)
        if contents != updated or stat.S_IMODE(final.st_mode) != (stat.S_IMODE(metadata.st_mode) if metadata else 0o644):
            raise OSError("Persisted configuration verification failed")
        if metadata and (final.st_uid, final.st_gid) != (metadata.st_uid, metadata.st_gid):
            raise OSError("Persisted configuration ownership changed")
    except (OSError, ValueError) as exc:
        state = "replacement completed; no rollback attempted" if replaced else "replacement not completed"
        raise OSError(str(exc) + "; " + state) from exc
    finally:
        try:
            if temporary is not None:
                os.unlink(temporary, dir_fd=directory)
        finally:
            os.close(directory)


try:
    persist(sys.argv[1], sys.argv[2], sys.argv[3:])
except (OSError, ValueError) as exc:
    sys.exit("Atomic configuration update failed: " + str(exc))
PY_ATOMIC
)" || return 1
  if [ "$user" = true ]; then
    as_current_user python3 -c "$program" "$@"
  else
    python3 -c "$program" "$@"
  fi
}

persist_swap() {
  if ! atomic_config /etc/fstab fstab /swapfile; then
    error "Не удалось записать /swapfile в /etc/fstab; /swapfile может быть активен в текущей сессии, но автоподключение после перезагрузки не подтверждено"
    return 1
  fi
}


configure_unattended_upgrades() {
  section "АВТО-ОБНОВЛЕНИЯ БЕЗОПАСНОСТИ"
  mkdir -p /etc/apt/apt.conf.d || { error "Не удалось создать каталог /etc/apt/apt.conf.d"; return 1; }
  if ! atomic_config /etc/apt/apt.conf.d/20auto-upgrades text <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
  then
    error "Не удалось записать /etc/apt/apt.conf.d/20auto-upgrades"
    return 1
  fi

  local key expected actual
  for key in Update-Package-Lists Unattended-Upgrade Download-Upgradeable-Packages AutocleanInterval; do
    expected=1; [ "$key" != AutocleanInterval ] || expected=7
    actual=$(apt-config shell value "APT::Periodic::$key") || { error "Не удалось проверить APT::$key"; return 1; }
    [ "$actual" = "value='$expected'" ] || { error "Конфликт effective APT::$key; проверьте overrides"; return 1; }
  done

  # Конфигурация обязательна; таймеры остаются best-effort.
  local timers_ok=true enablement enable_status
  for timer in apt-daily.timer apt-daily-upgrade.timer; do
    enable_status=0
    enablement=$(systemctl is-enabled "$timer" 2>/dev/null) || enable_status=$?
    if [ "$enablement" = disabled ] && [ "$enable_status" -eq 1 ]; then
      systemctl enable "$timer" 2>/dev/null || {
        warn "Не удалось включить $timer"
        timers_ok=false
      }
    elif [ "$enablement" != enabled ] || [ "$enable_status" -ne 0 ]; then
      warn "Не удалось подтвердить persistent enablement $timer ($enablement); проверьте unit state"
      timers_ok=false
    fi
  done

  local timer_state
  for timer in apt-daily.timer apt-daily-upgrade.timer; do
    if ! timer_state=$(systemctl show "$timer" -p LoadState -p UnitFileState -p ActiveState -p SubState -p NextElapseUSecRealtime -p NextElapseUSecMonotonic -p NeedDaemonReload); then
      warn "Не удалось проверить runtime scheduling $timer"; timers_ok=false; continue
    fi
    if ! python3 -c 'import datetime, re, sys
rows = sys.stdin.read().splitlines()
keys = ("LoadState", "UnitFileState", "ActiveState", "SubState", "NextElapseUSecRealtime", "NextElapseUSecMonotonic", "NeedDaemonReload")
data = dict(row.split("=", 1) for row in rows if "=" in row)
def scheduled(v):
    if re.fullmatch(r"[1-9][0-9]*", v):
        return True
    if re.fullmatch(r"(?:[0-9]+(?:us|ms|s|min|h|d|w|month|y) ?)+", v) and re.search(r"[1-9]", v):
        return True
    if re.fullmatch(r"[A-Za-z]{3} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \S+", v):
        try:
            datetime.datetime.strptime(" ".join(v.split()[1:3]), "%Y-%m-%d %H:%M:%S")
            return True
        except ValueError:
            pass
    return False
sys.exit(0 if len(rows) == len(keys) and set(data) == set(keys) and
data["LoadState"] == "loaded" and data["UnitFileState"] == "enabled" and
data["ActiveState"] == "active" and data["SubState"] == "waiting" and
data["NeedDaemonReload"] == "no" and
any(scheduled(data[k]) for k in keys[4:6]) else 1)' <<< "$timer_state"; then
      warn "$timer: active scheduling не подтверждено; проверьте systemctl list-timers"
      timers_ok=false
    fi
  done

  if [ "$timers_ok" = true ]; then
    ok "Авто-обновления безопасности включены"
  else
    warn "Не удалось включить некоторые timer'ы; проверьте: systemctl list-timers"
  fi
  return 0
}

configure_autoremove() {
  section "АВТООЧИСТКА НЕИСПОЛЬЗУЕМЫХ ПАКЕТОВ"

  # Автоудаление зависимостей ОТКЛЮЧЕНО для безопасности сервера
  if ! atomic_config /etc/apt/apt.conf.d/50auto-remove text <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
EOF
  then
    error "Не удалось отключить автоудаление зависимостей"
    return 1
  fi
  local key actual
  for key in Remove-Unused-Dependencies Remove-New-Unused-Dependencies; do
    actual=$(apt-config shell value "Unattended-Upgrade::$key") || { error "Не удалось проверить APT::$key"; return 1; }
    [ "$actual" = "value='false'" ] || { error "Конфликт effective APT::$key; проверьте overrides"; return 1; }
  done
  ok "Автоудаление зависимостей отключено (безопасно для Xray/3x-ui/Docker)"

  local packages=0 preview line package rest listing=""
  if ! preview=$(apt-get --dry-run autoremove); then
    error "Не удалось проверить пакеты для удаления (apt-get --dry-run autoremove)"
    return 1
  fi
  while IFS= read -r line; do
    if [[ "$line" == "Remv "* ]]; then
      packages=$((packages + 1))
      if [ "$packages" -le 20 ]; then
        read -r rest package rest <<< "$line"
        listing+="  - $package"$'\n'
      fi
    fi
  done <<< "$preview"
  if [ "$packages" -gt 0 ]; then
    info "Найдено $packages пакетов для удаления:"
    printf '%s' "$listing"
    [ "$packages" -gt 20 ] && info "  ... и ещё $((packages - 20))"
    local answer
    if ! ask "Удалить эти пакеты сейчас? [y/N]: " answer; then
      error "Не удалось прочитать ответ об удалении пакетов"
      return 1
    fi
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      if ! apt-get autoremove -y --purge; then
        error "Не удалось удалить неиспользуемые пакеты (apt-get autoremove)"
        return 1
      fi
      ok "Удаление неиспользуемых пакетов завершено"
    else
      info "Пропущено. Для ручного удаления: sudo apt autoremove --purge"
    fi
  else
    ok "Нет пакетов для удаления"
  fi
  return 0
}

configure_needrestart() {
  section "NEEDRESTART (ПЕРЕЗАПУСК СЛУЖБ ПОСЛЕ ОБНОВЛЕНИЙ)"
  info "Настройка режима перезапуска служб needrestart"

  local answer confirm
  ask "Включить автоматический перезапуск служб после обновлений? [y/N]: " answer || {
    error "Не удалось прочитать ответ для настройки needrestart"; return 1;
  }
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    warn "ВНИМАНИЕ: Автоматический перезапуск может прервать активные соединения"
    ask "Вы уверены? Это может остановить SSH, nginx, БД [y/N]: " confirm || {
      error "Не удалось прочитать подтверждение настройки needrestart"; return 1;
    }
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      local apt_hooks
      apt_hooks=$(apt-config dump) || { error "Не удалось проверить APT hooks needrestart"; return 1; }
      if ! python3 -c 'import re, sys
text = sys.stdin.read()
for line in text.splitlines():
    if "needrestart" in line.lower() and re.search(r"(?:-r\s*(?:\\?[\"\x27])?[^a\s;\"\x27]|NEEDRESTART_MODE\s*=\s*(?:\\?[\"\x27])?[^a\s;\"\x27]|NEEDRESTART_SUSPEND\s*=|--restart(?:=|\s+)[^a])", line):
        sys.exit("Conflicting APT needrestart hook; manual review required")' <<< "$apt_hooks"; then
        error "APT hook переопределяет needrestart"; return 1
      fi
      # Inspect snippets without executing administrator-provided Perl.
      if ! python3 - /etc/needrestart/conf.d <<'PY_SNIPPETS'
from pathlib import Path
import re
import sys
try:
    directory = Path(sys.argv[1])
    try:
        paths = sorted(directory.iterdir())
    except FileNotFoundError:
        if directory.is_symlink():
            raise
        paths = []
    for path in paths:
        if not path.name.endswith('.conf'):
            continue
        for line in path.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            if not re.fullmatch(r'''\s*\$nrconf\s*\{\s*(?:restart|'restart'|"restart")\s*\}\s*=\s*(['"])a\1\s*;\s*(?:#.*)?''', line):
                raise ValueError('Conflicting or unsupported needrestart snippet: ' + str(path))
except (OSError, ValueError) as exc:
    sys.exit(str(exc))
PY_SNIPPETS
      then
        error "Не удалось проверить needrestart conf.d; основной конфиг не изменён"; return 1
      fi
      if [ -n "${NEEDRESTART_MODE:-}" ] && [ "$NEEDRESTART_MODE" != a ]; then
        error "NEEDRESTART_MODE переопределяет автоматический режим"; return 1
      fi
      if [ -n "${NEEDRESTART_SUSPEND:-}" ]; then
        error "NEEDRESTART_SUSPEND отключает запуск needrestart"; return 1
      fi
      # Python 3 is installed by install_packages(); do not execute Perl config.
      if ! python3 - /etc/needrestart/needrestart.conf <<'PY'
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

path = Path(sys.argv[1])
key = rb"\$nrconf[ \t]*\{[ \t]*(?:restart|'restart'|\"restart\")[ \t]*\}"
setting = re.compile(rb"^([ \t]*)(?:#[ \t]*)?" + key +
                     rb"[ \t]*=[ \t]*(['\"])[ailq]\2[ \t]*;([ \t]*(?:#[^\r\n]*)?)(\r?\n)?$")
reference = re.compile(key)


def configure(data):
    # Reject multiline restart references instead of appending an ineffective setting.
    active = b'\n'.join(line.split(b'#', 1)[0] for line in data.splitlines())
    multiline_key = re.compile(key.replace(b'[ \\t]*', rb'\s*'))
    if len(multiline_key.findall(active)) != len(reference.findall(active)):
        raise ValueError("Unsupported multiline restart expression; configuration unchanged")
    lines = []
    found = False
    for line in data.splitlines(keepends=True):
        match = setting.fullmatch(line)
        if match:
            found = True
            # Leave an already active 'a' byte-for-byte unchanged.
            if re.match(rb"^[ \t]*" + key + rb"[ \t]*=[ \t]*(['\"])a\1[ \t]*;", line):
                lines.append(line)
            else:
                lines.append(match[1] + b'$nrconf{restart} = "a";' +
                             match[3] + (match[4] or b''))
        else:
            if not line.lstrip().startswith(b'#') and reference.search(line.split(b'#', 1)[0]):
                raise ValueError("Unsupported restart expression; configuration unchanged")
            lines.append(line)
    result = b''.join(lines)
    if not found:
        result += (b'\n' if result and not result.endswith(b'\n') else b'')
        result += b'$nrconf{restart} = "a";\n'
    return result


temporary = None
try:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("needrestart.conf must be a regular file")
    original = path.read_bytes()
    updated = configure(original)
    if updated != original:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.needrestart-', delete=False) as stream:
            temporary = stream.name
            if stream.write(updated) != len(updated):
                raise OSError("Short write of needrestart configuration")
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
        os.chmod(temporary, stat.S_IMODE(metadata.st_mode))
        os.replace(temporary, path)
        temporary = None
    actual = path.read_bytes()
    if actual != updated or configure(actual) != actual:
        raise ValueError("needrestart restart mode validation failed")
except (OSError, ValueError) as exc:
    sys.exit(str(exc))
finally:
    if temporary is not None:
        try:
            os.unlink(temporary)
        except OSError as exc:
            sys.exit("Could not remove needrestart temporary file: " + str(exc))
PY
      then
        error "Не удалось включить и проверить автоматический перезапуск needrestart"
        return 1
      fi
      ok "Режим автоматического перезапуска записан в основной конфиг needrestart"
      info "conf.d проверен без выполнения Perl; автоматический перезапуск каждого сервиса не гарантируется"
      warn "Параметры будущего APT hook/окружения и произвольный Perl основного конфига могут менять режим; это не runtime-проверка"
    else
      info "Настройки needrestart не изменены"
    fi
  else
    info "Настройки needrestart не изменены"
  fi
}

configure_safe_sysctl() {
  section "БЕЗОПАСНЫЕ SYSCTL"

  # BBR в Ubuntu может быть доступен как модуль tcp_bbr, но не загружен.
  # Сначала пробуем загрузить модуль, затем только при необходимости
  # отказываемся от BBR. Это важно для минимальных cloud-образов.
  local available_algorithms
  local bbr_available=false
  local bbr_module=false

  local module_file kernel_release kernel_config bbr_config='' config_line config_count=0
  # modinfo failure does not prove absence (missing tool/metadata/read errors).
  if command -v modinfo >/dev/null 2>&1 &&
     module_file=$(modinfo -F filename tcp_bbr) &&
     [[ "$module_file" = '(builtin)' || "$module_file" = /*.ko || "$module_file" = /*.ko.gz || "$module_file" = /*.ko.xz || "$module_file" = /*.ko.zst ]]; then
    if [ "$module_file" != '(builtin)' ]; then bbr_module=true; fi
  else
    module_file=''
    # Only an explicit setting from the running kernel can authorize fallback.
    kernel_release=$(uname -r) && [ -n "$kernel_release" ] || {
      error "Не удалось определить ядро для проверки BBR"; return 1;
    }
    kernel_config=$(cat "/boot/config-$kernel_release") || {
      error "modinfo не определил tcp_bbr; конфигурация текущего ядра недоступна"; return 1;
    }
    while IFS= read -r config_line; do
      case "$config_line" in
        CONFIG_TCP_CONG_BBR=*|'# CONFIG_TCP_CONG_BBR is not set')
          bbr_config="$config_line"; config_count=$((config_count + 1)) ;;
      esac
    done <<< "$kernel_config"
    [ "$config_count" -eq 1 ] || {
      error "Неоднозначная конфигурация BBR; файлы не изменены"; return 1;
    }
    case "$bbr_config" in
      CONFIG_TCP_CONG_BBR=m) bbr_module=true ;;
      CONFIG_TCP_CONG_BBR=y) ;;
      '# CONFIG_TCP_CONG_BBR is not set') ;;
      *) error "Некорректная конфигурация BBR; файлы не изменены"; return 1 ;;
    esac
  fi

  if ! available_algorithms=$(sysctl -n net.ipv4.tcp_available_congestion_control) || [ -z "$available_algorithms" ]; then
    error "Не удалось прочитать доступные алгоритмы контроля перегрузки"
    return 1
  fi
  if [[ ! "$available_algorithms" =~ (^|[[:space:]])bbr($|[[:space:]]) ]]; then
    if [ "$bbr_module" = true ]; then
      # Отсутствие модуля допустимо; сбой загрузки уже найденного модуля — ошибка.
      command -v modprobe >/dev/null 2>&1 || { error "tcp_bbr найден, но modprobe недоступен"; return 1; }
      if ! modprobe --dry-run tcp_bbr; then
        error "Не удалось проверить загрузку tcp_bbr"; return 1
      fi
      info "BBR найден как модуль tcp_bbr, загружаем его"
      if modprobe tcp_bbr 2>/dev/null; then
        ok "Модуль tcp_bbr загружен"
      else
        error "Не удалось загрузить найденный модуль tcp_bbr"
        return 1
      fi
    fi
  fi

  if ! available_algorithms=$(sysctl -n net.ipv4.tcp_available_congestion_control) || [ -z "$available_algorithms" ]; then
    error "Не удалось прочитать доступные алгоритмы контроля перегрузки"
    return 1
  fi
  if [[ ! "$available_algorithms" =~ (^|[[:space:]])bbr($|[[:space:]]) ]] &&
     { [ "$bbr_module" = true ] || [ "${module_file:-}" = '(builtin)' ] || [ "$bbr_config" = CONFIG_TCP_CONG_BBR=y ]; }; then
    error "BBR заявлен ядром, но алгоритм недоступен после проверки/загрузки"; return 1
  fi
  if [[ "$available_algorithms" =~ (^|[[:space:]])bbr($|[[:space:]]) ]]; then
    bbr_available=true
    if [ "$bbr_module" = true ]; then
      mkdir -p /etc/modules-load.d || { error "Не удалось создать /etc/modules-load.d"; return 1; }
      if ! atomic_config /etc/modules-load.d/tcp_bbr.conf text <<< tcp_bbr; then
        error "Не удалось записать /etc/modules-load.d/tcp_bbr.conf"
        return 1
      fi
      ok "tcp_bbr добавлен в автозагрузку модулей"
    fi
    info "BBR доступен в ядре"
  else
    rm -f /etc/modules-load.d/tcp_bbr.conf || { error "Не удалось удалить /etc/modules-load.d/tcp_bbr.conf"; return 1; }
    warn "BBR недоступен в этом ядре — будет использован штатный алгоритм"
  fi

  mkdir -p /etc/sysctl.d || { error "Не удалось создать /etc/sysctl.d"; return 1; }
  if ! atomic_config /etc/sysctl.d/99-vps-tuning.conf text <<EOF
# Совместимо с VPN, policy routing, туннелями и proxy.
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
$(if [ "$bbr_available" = true ]; then printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr'; fi)
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
EOF
  then
    error "Не удалось записать /etc/sysctl.d/99-vps-tuning.conf"
    return 1
  fi

  if ! sysctl --system >/dev/null; then
    error "Не удалось применить некоторые sysctl"
    return 1
  fi
  # A successful aggregate loader can still leave later overrides in effect.
  local setting expected actual managed_sysctl verified_count=0 expected_count=11
  [ "$bbr_available" != true ] || expected_count=13
  managed_sysctl=$(cat /etc/sysctl.d/99-vps-tuning.conf) || { error "Не удалось прочитать managed sysctl"; return 1; }
  while read -r setting equals expected; do
    [[ "$setting" = \#* || -z "$setting" ]] && continue
    [ "$equals" = = ] || { error "Некорректный managed sysctl"; return 1; }
    actual=$(sysctl -n "$setting") || { error "Не удалось проверить sysctl $setting"; return 1; }
    [ "$actual" = "$expected" ] || { error "Конфликт effective sysctl $setting; проверьте overrides"; return 1; }
    verified_count=$((verified_count + 1))
  done <<< "$managed_sysctl"
  [ "$verified_count" -eq "$expected_count" ] || { error "Неполный managed sysctl snapshot"; return 1; }

  mkdir -p /etc/security/limits.d || { error "Не удалось создать /etc/security/limits.d"; return 1; }
  if ! atomic_config /etc/security/limits.d/99-vps.conf text <<'EOF'
* soft nofile 1024
* hard nofile 1048576
root soft nofile 1024
root hard nofile 1048576
EOF
  then
    error "Не удалось записать /etc/security/limits.d/99-vps.conf"
    return 1
  fi
  # Conservative conflict check; PAM limits take effect only at a new login.
  if ! python3 - /etc/security <<'PY_LIMITS'
from pathlib import Path
import sys
try:
    root = Path(sys.argv[1])
    try:
        (root / 'limits.conf').lstat()
        paths = [root / 'limits.conf']
    except FileNotFoundError:
        paths = []
    paths += sorted((root / 'limits.d').iterdir())
    for path in paths:
        if path.name != 'limits.conf' and not path.name.endswith('.conf'):
            continue
        for line in path.read_text().splitlines():
            row = line.split('#', 1)[0].split()
            if 'nofile' not in row:
                continue
            if len(row) != 4 or row[1] not in ('soft', 'hard') or row[2] != 'nofile':
                raise ValueError('Unsupported PAM nofile entry: ' + str(path))
            expected = '1048576' if row[1] == 'hard' else '1024'
            if row[3] != expected:
                raise ValueError('PAM nofile override requires manual review: ' + str(path))
except (OSError, ValueError) as exc:
    sys.exit(str(exc))
PY_LIMITS
  then
    error "Не удалось проверить aggregate PAM limits"; return 1
  fi
  info "PAM nofile: soft=1024, hard=1048576 записаны для новых pam_limits-сессий; текущие процессы не изменены"
  ok "Безопасные sysctl применены"
  return 0
}

# Глобальный лимит для systemd-сервисов
configure_systemd_limits() {
  section "ЛИМИТЫ ДЛЯ SYSTEMD-СЕРВИСОВ"
  info "limits.d применяется только к интерактивным сессиям (через PAM)."
  info "Для системных сервисов (Xray, 3x-ui, Docker) задаём глобальный лимит."
  mkdir -p /etc/systemd/system.conf.d || { error "Не удалось создать /etc/systemd/system.conf.d"; return 1; }
  if ! atomic_config /etc/systemd/system.conf.d/99-nofile.conf text <<'EOF'
[Manager]
DefaultLimitNOFILE=1024:1048576
EOF
  then
    error "Не удалось записать /etc/systemd/system.conf.d/99-nofile.conf"
    return 1
  fi
  if systemctl daemon-reexec; then
    local limits
    limits=$(systemctl show -p DefaultLimitNOFILE -p DefaultLimitNOFILESoft) || { error "Не удалось проверить effective systemd limits"; return 1; }
    if [[ "$limits" != $'DefaultLimitNOFILE=1048576\nDefaultLimitNOFILESoft=1024' && "$limits" != $'DefaultLimitNOFILESoft=1024\nDefaultLimitNOFILE=1048576' ]]; then
      error "Конфликт effective systemd limits; проверьте overrides"; return 1
    fi
    ok "DefaultLimitNOFILE=1024:1048576 проверен для последующих запусков сервисов; per-unit overrides сохраняются"
  else
    error "Не удалось выполнить systemctl daemon-reexec"
    return 1
  fi
}

configure_swap() {
  section "SWAP"

  local ram desired_bytes desired_human active_output
  local own_bytes=0 foreign_count=0
  local source size_bytes type answer page_size expected_bytes

  # Проверяем, что SWAP_SIZE задан в формате, который понимает fallocate.
  if ! [[ "$SWAP_SIZE" =~ ^[1-9][0-9]*([KMGTP]i?B?|[KMGTP])?$ ]]; then
    error "Некорректный SWAP_SIZE: $SWAP_SIZE"
    return 1
  fi

  # Переводим SWAP_SIZE в байты без зависимости от numfmt.
  swap_size_to_bytes() {
    local value="$1" number suffix multiplier exponent radix=1024
    number="${value%%[KMGTPiB]*}"
    suffix="${value#$number}"
    case "${suffix^^}" in
      "") exponent=0 ;;
      K|KB|KI|KIB) exponent=1 ;;
      M|MB|MI|MIB) exponent=2 ;;
      G|GB|GI|GIB) exponent=3 ;;
      T|TB|TI|TIB) exponent=4 ;;
      P|PB|PI|PIB) exponent=5 ;;
      *) return 1 ;;
    esac
    [[ "$suffix" != [KMGTP]B ]] || radix=1000
    multiplier=$((radix ** exponent))
    # Check before Bash signed arithmetic; never permit wraparound.
    [ "${#number}" -le 19 ] || return 1
    if [ "${#number}" -eq 19 ] && [[ "$number" > 9223372036854775807 ]]; then return 1; fi
    [ "$number" -le "$((9223372036854775807 / multiplier))" ] || return 1
    printf '%s\n' "$((number * multiplier))"
  }

  desired_bytes="$(swap_size_to_bytes "$SWAP_SIZE")" || {
    error "Не удалось разобрать SWAP_SIZE=$SWAP_SIZE"
    return 1
  }
  desired_human="$SWAP_SIZE"
  page_size=$(getconf PAGESIZE) || { error "Не удалось определить размер страницы"; return 1; }
  [[ "$page_size" =~ ^[1-9][0-9]{0,6}$ ]] || { error "Некорректный размер страницы"; return 1; }
  # mkswap discards the last incomplete page and reserves one header page.
  expected_bytes=$(((desired_bytes / page_size - 1) * page_size))
  [ "$expected_bytes" -gt 0 ] || { error "SWAP_SIZE слишком мал для swap"; return 1; }

  swap_read_owned() {
    local listing row_source row_size row_type extra found=0 bytes=0
    listing=$(swapon --show=NAME,SIZE,TYPE --bytes --noheadings) || return 1
    while read -r row_source row_size row_type extra; do
      [ -n "$row_source" ] || continue
      [[ "$row_size" =~ ^[1-9][0-9]{0,18}$ ]] &&
        { [ "${#row_size}" -lt 19 ] || [[ "$row_size" < 9223372036854775808 ]]; } &&
        [[ "$row_type" = file || "$row_type" = partition ]] && [ -z "$extra" ] || return 1
      if [ "$row_source" = /swapfile ]; then
        [ "$found" -eq 0 ] && [ "$row_type" = file ] || return 1
        found=1; bytes="$row_size"
      fi
    done <<< "$listing"
    printf '%s\n' "$bytes"
  }

  # Ошибка чтения списка не означает отсутствие swap: ничего не меняем.
  if ! active_output=$(swapon --show=NAME,SIZE,TYPE --bytes --noheadings); then
    error "Не удалось определить активные swap-источники; swap не изменён"
    return 1
  fi
  while read -r source size_bytes type; do
    [ -n "$source" ] || continue
    if ! [[ "$size_bytes" =~ ^[1-9][0-9]{0,18}$ ]] ||
       { [ "${#size_bytes}" -eq 19 ] && [[ "$size_bytes" > 9223372036854775807 ]]; } ||
       [[ "$type" != file && "$type" != partition ]]; then
      error "Не удалось разобрать размер swap: $source; swap не изменён"
      return 1
    fi
    if [ "$source" = /swapfile ]; then
      [ "$own_bytes" -eq 0 ] && [ "$type" = file ] || { error "Неоднозначный /swapfile"; return 1; }
      own_bytes="$size_bytes"
    else
      foreign_count=$((foreign_count + 1))
      info "Чужой swap-источник: $source — $size_bytes байт ($type); оставлен без изменений"
    fi
  done <<< "$active_output"

  if [ "$own_bytes" -gt 0 ]; then
    if [ -L /swapfile ] || [ ! -f /swapfile ]; then
      error "Активный /swapfile не является обычным файлом"; return 1
    fi
    if [ "$own_bytes" -eq "$expected_bytes" ]; then
      persist_swap || return 1
      ok "Размер /swapfile соответствует $desired_human; запись /etc/fstab проверена"
      return 0
    fi
    warn "Размер /swapfile ($own_bytes байт) отличается от $desired_human."
    warn "При замене только /swapfile будет временно отключён. Не делайте это при критической нехватке RAM."
    ask "Заменить только /swapfile на $desired_human? [y/N]: " answer || { error "Не удалось прочитать подтверждение"; return 1; }
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      info "/swapfile оставлен без изменений"
      return 0
    fi
  elif [ "$foreign_count" -gt 0 ]; then
    ask "Чужой swap уже активен. Дополнительно создать /swapfile $desired_human? [y/N]: " answer || { error "Не удалось прочитать подтверждение"; return 1; }
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      info "Дополнительный /swapfile не создан"
      return 0
    fi
  else
    if ! ram="$(LC_ALL=C free -m | awk '/^Mem:/ {print $2}')"; then
      error "Не удалось измерить объём RAM"
      return 1
    fi
    if ! [[ "$ram" =~ ^[0-9]+$ ]]; then
      error "Не удалось определить объём RAM; swap не изменён"
      return 1
    fi
    if [ "$ram" -gt "$SWAP_RAM_THRESHOLD_MB" ]; then
      info "Активного swap нет, RAM больше $SWAP_RAM_THRESHOLD_MB MB — swap не нужен"
      return 0
    fi
    info "Активного swap нет, RAM не более $SWAP_RAM_THRESHOLD_MB MB — создаём $desired_human"
  fi

  # Не следуем симлинкам и не заменяем устройства даже по управляемому пути.
  if [ -L /swapfile ] || { [ -e /swapfile ] && [ ! -f /swapfile ]; }; then
    error "/swapfile существует, но это не обычный файл — отказываюсь его изменять"
    return 1
  fi
  # Prepare on the same filesystem while the old swap is still available.
  local staged backup='' old_moved=false new_moved=false runtime_bytes file_bytes
  staged=$(mktemp /swapfile.new.XXXXXX) || { error "Не удалось подготовить swap"; return 1; }
  if ! fallocate -l "$desired_bytes" "$staged"; then
    # GNU dd counts bytes exactly, including a final partial block.
    if ! dd if=/dev/zero of="$staged" bs=1M count="$desired_bytes" iflag=count_bytes status=progress; then
      error "Не удалось создать swap"; rm -f -- "$staged" || return 1; return 1
    fi
  fi
  file_bytes=$(stat -c %s -- "$staged") || file_bytes=''
  if [ "$file_bytes" != "$desired_bytes" ] || ! chmod 600 "$staged" || ! mkswap "$staged" >/dev/null; then
    error "Не удалось подготовить swap точного размера"
    rm -f -- "$staged" || return 1; return 1
  fi
  if [ -f /swapfile ]; then
    backup=$(mktemp /swapfile.old.XXXXXX) || { rm -f -- "$staged" || return 1; return 1; }
  fi

  swap_recover() {
    # Never unlink/rename a possibly active replacement after a failed probe.
    if [ "$new_moved" = true ]; then
      runtime_bytes=$(swap_read_owned) || { error "FATAL: runtime swap неизвестен; сохранены /swapfile и $backup"; return 1; }
      if [ "$runtime_bytes" -gt 0 ]; then
        swapoff /swapfile || { error "FATAL: replacement не отключён; сохранён $backup"; return 1; }
        runtime_bytes=$(swap_read_owned) && [ "$runtime_bytes" -eq 0 ] || {
          error "FATAL: отключение replacement не подтверждено; сохранён $backup"; return 1;
        }
      fi
      rm -f -- /swapfile || { error "FATAL: не удалось убрать replacement; сохранён $backup"; return 1; }
    fi
    if [ "$old_moved" = true ]; then
      mv -T -- "$backup" /swapfile || { error "FATAL: восстановите /swapfile из $backup"; return 1; }
      backup=''
    fi
    if [ "$own_bytes" -gt 0 ]; then
      runtime_bytes=$(swap_read_owned) || { error "FATAL: не удалось проверить старый swap"; return 1; }
      if [ "$runtime_bytes" -eq 0 ]; then
        swapon /swapfile || { error "FATAL: старый /swapfile сохранён, но не активирован"; return 1; }
      fi
      runtime_bytes=$(swap_read_owned) && [ "$runtime_bytes" -eq "$own_bytes" ] || {
        error "FATAL: восстановление старого runtime swap не подтверждено"; return 1;
      }
    fi
    rm -f -- "$staged" ${backup:+"$backup"} || { error "Не удалось очистить swap scratch files"; return 1; }
  }

  if [ "$own_bytes" -gt 0 ] && ! swapoff /swapfile; then
    error "Не удалось отключить /swapfile"; swap_recover || return 1; return 1
  fi
  runtime_bytes=$(swap_read_owned) || { error "Runtime swap неизвестен; сохранены /swapfile и $staged"; return 1; }
  if [ "$runtime_bytes" -ne 0 ]; then
    error "Отключение /swapfile не подтверждено"; swap_recover || return 1; return 1
  fi
  if [ -n "$backup" ]; then
    if ! mv -T -- /swapfile "$backup"; then
      error "Не удалось сохранить старый swap"; swap_recover || return 1; return 1
    fi
    old_moved=true
  fi
  if ! mv -T -- "$staged" /swapfile; then
    error "Не удалось установить replacement"; swap_recover || return 1; return 1
  fi
  new_moved=true
  if ! swapon /swapfile; then
    error "swapon завершился с ошибкой"; swap_recover || return 1; return 1
  fi
  runtime_bytes=$(swap_read_owned) || { error "FATAL: активация не проверена; сохранены /swapfile и $backup"; return 1; }
  if [ "$runtime_bytes" -ne "$expected_bytes" ]; then
    error "Swap активирован с неверным размером"; swap_recover || return 1; return 1
  fi
  # Persistence errors retain the verified active swap; the next run repairs fstab.
  if [ -n "$backup" ]; then
    rm -f -- "$backup" || { error "Не удалось очистить старый swap $backup"; return 1; }
  fi
  persist_swap || return 1
  ok "Swap $desired_human создан и активирован"
  return 0
}

# Безопасное управление ключами pin
# Проверяем одну запись authorized_keys самим OpenSSH (включая записи с options).
ssh_key_fingerprint() {
  # 0 = valid fingerprint, 1 = invalid/DSA input, 2 = operational failure.
  local line="$1" tmp fingerprint contents status=0
  [[ "$line" =~ ^[[:space:]]*($|#) || "$line" == *$'\n'* ]] && return 1
  tmp="$(mktemp)" || { error "Не удалось создать временный файл проверки ключа"; return 2; }
  if ! printf '%s\n' "$line" > "$tmp"; then
    rm -f -- "$tmp" || error "Не удалось удалить временный файл проверки ключа"
    error "Не удалось записать временный файл проверки ключа"
    return 2
  fi
  if ! contents="$(cat -- "$tmp")" || [ "$contents" != "$line" ]; then
    rm -f -- "$tmp" || error "Не удалось удалить временный файл проверки ключа"
    error "Не удалось прочитать временный файл проверки ключа"
    return 2
  fi
  fingerprint="$(LC_ALL=C ssh-keygen -E sha256 -lf "$tmp" 2>&1)" || status=$?
  # OpenSSH diagnostics may end in CRLF even on Unix.
  fingerprint="${fingerprint%$'\r'}"
  if ! rm -f -- "$tmp"; then
    error "Не удалось удалить временный файл проверки ключа"
    return 2
  fi
  if [ "$status" -ne 0 ]; then
    # OpenSSH uses status 1/255 for invalid input and I/O errors. Only its
    # exact C-locale invalid-file diagnostic is an expected input rejection.
    if { [ "$status" -eq 1 ] || [ "$status" -eq 255 ]; } && { [ "$fingerprint" = "$tmp is not a public key file." ] || [ "$fingerprint" = "$tmp is not a key file." ]; }; then
      return 1
    fi
    error "Не удалось выполнить проверку SSH-ключа"
    return 2
  fi
  # DSA не подходит для входа; комментарий ключа не участвует в сравнении.
  [[ "$fingerprint" == *" (DSA)" ]] && return 1
  if [[ "$fingerprint" != *$'\n'* && "$fingerprint" =~ ^[0-9]+[[:space:]]+(SHA256:[A-Za-z0-9+/]+)[[:space:]] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}" || { error "Не удалось вывести fingerprint SSH-ключа"; return 2; }
    return 0
  fi
  error "Неожиданный результат проверки SSH-ключа"
  return 2
}

authorized_keys_has_key() {
  # 0 = match, 1 = ordinary no-match, 2 = operational failure.
  local file="$1" wanted="${2:-}" line fingerprint content status
  [ -e "$file" ] || { [ ! -L "$file" ] && return 1; }
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    error "Не удалось прочитать обычный файл ключей: $file"
    return 2
  fi
  [ -r "$file" ] || return 1
  # Read the entire file before matching: a partial read must not yield a
  # successful early match or silently look like EOF/no-match.
  if ! content="$(cat -- "$file")"; then
    error "Не удалось прочитать файл ключей: $file"
    return 2
  fi
  while true; do
    status=0
    IFS= read -r line || status=$?
    [ "$status" -eq 1 ] && break
    if [ "$status" -ne 0 ]; then
      error "Не удалось прочитать запись SSH-ключа"
      return 2
    fi
    status=0
    fingerprint="$(ssh_key_fingerprint "$line")" || status=$?
    case "$status" in
      0) ;;
      1) continue ;;
      *) return 2 ;;
    esac
    if [ -z "$wanted" ] || [ "$fingerprint" = "$wanted" ]; then
      return 0
    fi
  done <<< "$content" || { error "Не удалось открыть прочитанные записи SSH-ключей"; return 2; }
  return 1
}

configure_pin() {
  section "ПОСТОЯННЫЙ ПОЛЬЗОВАТЕЛЬ $PIN_USER"
  local home sshdir keys action answer method public_key keyfile passwd_entry status
  local is_new=false replace_mode=false use_file=false
  PIN_HAS_KEY=false

  if id "$PIN_USER" >/dev/null 2>&1; then
    if ! passwd_entry="$(getent passwd "$PIN_USER")"; then
      error "Не удалось получить passwd-запись пользователя $PIN_USER"
      return 1
    fi
    # Parse one complete passwd record without a pipeline; preserve custom home.
    if [[ "$passwd_entry" == *$'\n'* || ! "$passwd_entry" =~ ^([^:]+):[^:]*:[0-9]+:[0-9]+:[^:]*:([^:]+):[^:]*$ ]]; then
      error "Некорректная passwd-запись пользователя $PIN_USER"
      return 1
    fi
    if [ "${BASH_REMATCH[1]}" != "$PIN_USER" ]; then
      error "Получена passwd-запись другого пользователя"
      return 1
    fi
    home="${BASH_REMATCH[2]}"
    sshdir="$home/.ssh"; keys="$sshdir/authorized_keys"
    if [ -z "$home" ] || [ ! -d "$home" ]; then
      error "Не найдена домашняя директория пользователя $PIN_USER"
      return 1
    fi
    if ! access_safety key "$home" "$(id -u "$PIN_USER")" "$(id -g "$PIN_USER")" check; then
      error "Небезопасный путь SSH-ключа пользователя $PIN_USER"; return 1
    fi
    status=0
    authorized_keys_has_key "$keys" || status=$?
    case "$status" in
      0) PIN_HAS_KEY=true ;;
      1) ;;
      *) error "Не удалось проверить ключи пользователя $PIN_USER"; return 1 ;;
    esac
    info "$PIN_USER уже существует; валидный SSH-ключ: $PIN_HAS_KEY"

    echo "Enter) Ничего не менять (по умолчанию)"
    echo "1) Сменить пароль"
    echo "2) Добавить публичный ключ"
    echo "3) Заменить все публичные ключи"
    ask "Ваш выбор: " action || { error "Не удалось прочитать ответ для настройки $PIN_USER"; return 1; }
    case "$action" in
      "") info "Пользователь $PIN_USER оставлен без изменений"; return 0 ;;
      1) set_pin_password; return $? ;;
      2|3) [ "$action" = 3 ] && replace_mode=true ;;
      *) warn "Неизвестный выбор — ничего не меняем"; return 0 ;;
    esac
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      error "Не удалось проверить существование пользователя $PIN_USER"
      return 1
    fi
    ask "Создать $PIN_USER и добавить в группу sudo? [Y/n]: " answer || { error "Не удалось прочитать ответ для настройки $PIN_USER"; return 1; }
    if ! yes_by_default "$answer"; then
      warn "Создание $PIN_USER пропущено"
      return 0
    fi

    # ЗАМЕЧАНИЕ 2: проверяем результат критичных команд
    if ! adduser --disabled-password --gecos "" "$PIN_USER"; then
      error "Не удалось создать пользователя $PIN_USER"
      return 1
    fi
    if ! usermod -aG sudo "$PIN_USER"; then
      error "Не удалось добавить $PIN_USER в группу sudo"
      return 1
    fi

    if ! passwd_entry="$(getent passwd "$PIN_USER")"; then
      error "Не удалось получить passwd-запись пользователя $PIN_USER"
      return 1
    fi
    # Parse one complete passwd record without a pipeline; preserve custom home.
    if [[ "$passwd_entry" == *$'\n'* || ! "$passwd_entry" =~ ^([^:]+):[^:]*:[0-9]+:[0-9]+:[^:]*:([^:]+):[^:]*$ ]]; then
      error "Некорректная passwd-запись пользователя $PIN_USER"
      return 1
    fi
    if [ "${BASH_REMATCH[1]}" != "$PIN_USER" ]; then
      error "Получена passwd-запись другого пользователя"
      return 1
    fi
    home="${BASH_REMATCH[2]}"
    if [ -z "$home" ] || [ ! -d "$home" ]; then
      error "Не найдена домашняя директория пользователя $PIN_USER"
      return 1
    fi
    sshdir="$home/.ssh"; keys="$sshdir/authorized_keys"; is_new=true
    ok "Пользователь $PIN_USER создан"
    info "Задайте пароль $PIN_USER (ввод и подтверждение не отображаются):"
    if ! set_pin_password; then
      error "Не удалось установить пароль для $PIN_USER"
      return 1
    fi
  fi

  # === Запрос ключа ===
  if [ "$is_new" = false ]; then
    echo "1) Вставить публичный ключ"
    echo "2) Скопировать ключ из файла на сервере"
    echo "3) Пропустить"
    ask "Способ добавления ключа [1/2/3]: " method || { error "Не удалось прочитать ответ для настройки $PIN_USER"; return 1; }
    case "$method" in
      1) use_file=false ;;
      2) use_file=true ;;
      *) info "Ключ не изменён"; return 0 ;;
    esac
  fi

  if [ "$use_file" = true ]; then
    ask "Путь к файлу публичного ключа: " keyfile || { error "Не удалось прочитать ответ для настройки $PIN_USER"; return 1; }
    # ЗАМЕЧАНИЕ 2: файл не найден — это ОШИБКА, а не успех
    if [ ! -f "$keyfile" ]; then
      error "Файл не найден: $keyfile"
      return 1
    fi
    public_key=$(cat "$keyfile") || { error "Не удалось прочитать файл публичного ключа: $keyfile"; return 1; }
  else
    info "Вставьте публичный SSH-ключ одной строкой:"
    read -r public_key < /dev/tty || { error "Не удалось прочитать публичный SSH-ключ из /dev/tty"; return 1; }
  fi

  # Пустой ключ: НЕ ломаем существующие ключи
  if [ -z "$public_key" ]; then
    if [ "$replace_mode" = true ]; then
      warn "Пустой ключ — замена отменена, старые ключи сохранены"
    elif [ "$is_new" = true ]; then
      warn "Ключ не добавлен. До отключения паролей добавьте его вручную."
    else
      warn "Пустой ключ — пропуск"
    fi
    return 0
  fi

  local fingerprint
  status=0
  fingerprint="$(ssh_key_fingerprint "$public_key")" || status=$?
  case "$status" in
    0) ;;
    1) warn "Некорректный публичный SSH-ключ или запрещённый ssh-dss. Ключ не добавлен."; return 0 ;;
    *) error "Не удалось проверить публичный SSH-ключ"; return 1 ;;
  esac
  if [ "$replace_mode" = false ]; then
    status=0
    authorized_keys_has_key "$keys" "$fingerprint" || status=$?
    case "$status" in
      0) PIN_HAS_KEY=true; info "Этот публичный ключ уже установлен"; return 0 ;;
      1) ;;
      *) error "Не удалось проверить наличие публичного SSH-ключа"; return 1 ;;
    esac
  fi

  PIN_HAS_KEY=false
  local key_action=append pin_uid pin_gid
  pin_uid="$(id -u "$PIN_USER")" && pin_gid="$(id -g "$PIN_USER")" || return 1
  if [ "$is_new" = true ] || [ "$replace_mode" = true ]; then key_action=replace; fi
  if ! printf '%s\n' "$public_key" | access_safety key "$home" "$pin_uid" "$pin_gid" "$key_action"; then
    error "Не удалось безопасно записать SSH-ключ для $PIN_USER"
    return 1
  fi

  PIN_HAS_KEY=false
  if ! authorized_keys_has_key "$keys"; then
    error "После записи не найден валидный SSH-ключ для $PIN_USER"
    return 1
  fi
  PIN_HAS_KEY=true
  ok "Ключ для $PIN_USER установлен"
  return 0
}

ufw_is_active() {
  # 0 = active, 1 = inactive, 2 = operational failure (fail closed).
  local status_output
  if ! status_output="$(LC_ALL=C ufw status)"; then
    error "Не удалось получить статус UFW"
    return 2
  fi
  case "$status_output" in
    'Status: active'|'Status: active'$'\n'*) return 0 ;;
    'Status: inactive'|'Status: inactive'$'\n'*) return 1 ;;
    *) error "Неожиданный ответ ufw status"; return 2 ;;
  esac
}

# Если UFW уже активен, целевой SSH-порт должен быть разрешён ДО
# переключения sshd. Старые SSH-правила здесь намеренно не удаляются.
ensure_ufw_ssh_port() {
  local status status_output
  if ! command -v ufw >/dev/null 2>&1; then
    error "UFW не установлен — невозможно безопасно проверить доступ к SSH-порту $SSH_PORT"
    return 1
  fi

  if ufw_is_active; then
    :
  else
    status=$?
    if [ "$status" -ne 1 ]; then return "$status"; fi
    info "UFW сейчас не активен — предварительное правило для SSH не требуется"
    return 0
  fi

  if ! status_output="$(LC_ALL=C ufw status numbered)"; then
    error "Не удалось прочитать порядок правил UFW"; return 2
  fi
  status=0
  access_safety ufw "$SSH_PORT" <<< "$status_output" || status=$?
  case "$status" in
    0) return 0 ;;
    1) [ "${1:-}" = check ] && return 0 ;;
    *) error "Порядок UFW не подтверждён; SSH не изменён"; return 2 ;;
  esac
  if ! ufw allow "$SSH_PORT/tcp" comment 'SSH'; then
    error "Не удалось разрешить $SSH_PORT/tcp в UFW"; return 1
  fi
  if ! status_output="$(LC_ALL=C ufw status numbered)"; then
    error "Не удалось проверить порядок правил UFW"; return 2
  fi
  if ! access_safety ufw "$SSH_PORT" <<< "$status_output"; then
    error "Эффективное правило ALLOW для $SSH_PORT/tcp не подтверждено"; return 1
  fi

  return 0
}

configure_ufw() {
  section "UFW"
  local answer action source_ip status

  if ufw_is_active; then
    # Повторная проверка безопасна и идемпотентна. Старый SSH-порт не удаляем.
    if ! ensure_ufw_ssh_port; then
      return 1
    fi
  else
    status=$?
    if [ "$status" -ne 1 ]; then return "$status"; fi
    ask "Настроить и активировать UFW? [Y/n]: " answer || {
      error "Не удалось прочитать ответ об активации UFW"; return 1;
    }
    if yes_by_default "$answer"; then
      ufw default deny incoming || { error "Не удалось установить UFW default deny incoming"; return 1; }
      ufw default allow outgoing || { error "Не удалось установить UFW default allow outgoing"; return 1; }
      ufw allow "$SSH_PORT/tcp" comment 'SSH' || { error "Не удалось разрешить $SSH_PORT/tcp в UFW"; return 1; }
      ufw allow 80/tcp comment 'HTTP' || { error "Не удалось разрешить 80/tcp в UFW"; return 1; }
      ufw allow 443/tcp comment 'HTTPS' || { error "Не удалось разрешить 443/tcp в UFW"; return 1; }
      ufw --force enable || { error "Не удалось включить UFW"; return 1; }
      ok "UFW включён: SSH $SSH_PORT, HTTP/HTTPS"
    fi
  fi

  echo "iPerf3: Enter) не менять; 1) открыть всем; 2) открыть одному IP; 3) закрыть общие правила"
  ask "Правило для порта 5201: " action || {
    error "Не удалось прочитать выбор правила iPerf3"; return 1;
  }
  case "$action" in
    1)
      ufw allow 5201/tcp comment 'temporary iperf3' || { error "Не удалось разрешить 5201/tcp в UFW"; return 1; }
      ufw allow 5201/udp comment 'temporary iperf3' || { error "Не удалось разрешить 5201/udp в UFW"; return 1; }
      warn "Закройте 5201 после теста: выберите пункт 3" ;;
    2)
      ask "IPv4 или IPv6-адрес клиента: " source_ip || {
        error "Не удалось прочитать IP-адрес клиента iPerf3"; return 1;
      }
      if [[ "$source_ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        ufw allow from "$source_ip" to any port 5201 proto tcp || { error "Не удалось разрешить iPerf3 TCP для $source_ip в UFW"; return 1; }
        ufw allow from "$source_ip" to any port 5201 proto udp || { error "Не удалось разрешить iPerf3 UDP для $source_ip в UFW"; return 1; }
        ok "iPerf3 разрешён только для $source_ip"
      else
        error "Некорректный IP"; return 1; fi ;;
    3)
      ufw --force delete allow 5201/tcp || { error "Не удалось удалить общее правило 5201/tcp в UFW"; return 1; }
      ufw --force delete allow 5201/udp || { error "Не удалось удалить общее правило 5201/udp в UFW"; return 1; }
      ok "Общие правила 5201 удалены" ;;
    *) info "Правила iPerf3 не изменены" ;;
  esac
}

set_sshd_line() {
  if ! atomic_config /etc/ssh/sshd_config sshd "$1" "$2"; then
    error "Не удалось обновить $1 в /etc/ssh/sshd_config"
    return 1
  fi
}

configure_ssh() {
  section "SSH: ПОРТ, КЛЮЧИ И SOCKET ACTIVATION"
  local answer
  local home keys_file passwd_entry key_status
  PIN_HAS_KEY=false
  if ! passwd_entry="$(getent passwd "$PIN_USER")"; then
    error "Не удалось получить passwd-запись пользователя $PIN_USER"
    return 1
  fi
  if [[ "$passwd_entry" == *$'\n'* || ! "$passwd_entry" =~ ^([^:]+):[^:]*:[0-9]+:[0-9]+:[^:]*:([^:]+):[^:]*$ ]]; then
    error "Некорректная passwd-запись пользователя $PIN_USER"
    return 1
  fi
  if [ "${BASH_REMATCH[1]}" != "$PIN_USER" ]; then
    error "Получена passwd-запись другого пользователя"
    return 1
  fi
  home="${BASH_REMATCH[2]}"
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    error "Не найдена домашняя директория пользователя $PIN_USER"
    return 1
  fi
  keys_file="$home/.ssh/authorized_keys"

  if ! access_safety key "$home" "$(id -u "$PIN_USER")" "$(id -g "$PIN_USER")" check; then
    error "Небезопасный путь SSH-ключа $PIN_USER"; return 1
  fi
  # Определяем наличие ключа непосредственно перед возможным отключением паролей.
  key_status=0
  authorized_keys_has_key "$keys_file" || key_status=$?
  case "$key_status" in
    0) PIN_HAS_KEY=true ;;
    1) ;;
    *) error "Не удалось проверить ключи пользователя $PIN_USER"; return 1 ;;
  esac

  if [ "$PIN_HAS_KEY" != "true" ]; then
    error "У $PIN_USER НЕТ SSH-ключа."
    error "Нельзя отключать пароли без ключа — вы потеряете доступ."
    error "Добавьте ключ и повторите настройку."
    return 1
  fi
  ok "SSH-ключ для $PIN_USER найден"

  # В Ubuntu/Debian sshd -t/-T может требовать этот runtime-каталог
  # даже до запуска службы.
  if ! install -d -m 0755 /run/sshd; then
    error "Не удалось создать /run/sshd"
    return 1
  fi

  # Сначала смотрим эффективную конфигурацию sshd, а не только текст файлов.
  # Это делает повторный запуск идемпотентным и учитывает *.d/ и cloud-init.
  local effective
  if ! effective="$(sshd -T 2>&1)"; then
    error "Не удалось получить эффективную конфигурацию sshd (sshd -T)"
    error "Причина:"
    printf '%s\n' "$effective" >&2
    error "Проверка: sshd -t"
    return 1
  fi

  local key_effective context_addr=127.0.0.1 context_laddr=127.0.0.1 context_client_port context_server_port
  if [ -n "${SSH_CONNECTION:-}" ]; then
    read -r context_addr context_client_port context_laddr context_server_port <<< "$SSH_CONNECTION"
    if [[ ! "$context_addr" =~ ^[0-9a-fA-F:.]+$ || ! "$context_laddr" =~ ^[0-9a-fA-F:.]+$ ]]; then
      error "Некорректный SSH connection context"; return 1
    fi
  fi
  if ! key_effective="$(sshd -T -C "user=$PIN_USER,host=$context_addr,addr=$context_addr,laddr=$context_laddr,lport=$SSH_PORT" -ddd 2>&1)"; then
    error "Не удалось подтвердить effective SSH Match context для $PIN_USER"; return 1
  fi
  if ! access_safety effective "$home" "$PIN_USER" checked-context <<< "$key_effective"; then
    error "OpenSSH не подтверждает путь установленного ключа $PIN_USER"; return 1
  fi
  if ! access_safety key "$home" "$(id -u "$PIN_USER")" "$(id -g "$PIN_USER")" check; then
    error "Небезопасный путь SSH-ключа $PIN_USER"; return 1
  fi

  local current_port pass_auth pubkey_auth root_login kbd_auth max_auth
  current_port=$(awk '$1 == "port" {print $2; exit}' <<< "$effective")
  pass_auth=$(awk '$1 == "passwordauthentication" {print $2}' <<< "$effective")
  pubkey_auth=$(awk '$1 == "pubkeyauthentication" {print $2}' <<< "$effective")
  root_login=$(awk '$1 == "permitrootlogin" {print $2}' <<< "$effective")
  kbd_auth=$(awk '$1 == "kbdinteractiveauthentication" {print $2}' <<< "$effective")
  max_auth=$(awk '$1 == "maxauthtries" {print $2}' <<< "$effective")

  local ssh_ok=true
  [ "$current_port" = "$SSH_PORT" ] || ssh_ok=false
  [ "$pass_auth" = "no" ] || ssh_ok=false
  [ "$pubkey_auth" = "yes" ] || ssh_ok=false
  [ "$root_login" = "no" ] || ssh_ok=false
  [ "$kbd_auth" = "no" ] || ssh_ok=false
  [ "$max_auth" = "3" ] || ssh_ok=false

  if [ "$ssh_ok" = true ] && check_ssh_port; then
    ok "SSH уже настроен согласно требованиям скрипта — ничего не меняем"
    return 0
  fi

  echo "Текущее состояние SSH:"
  echo "  Порт:                     ${current_port:-не определён} (требуется $SSH_PORT)"
  echo "  PasswordAuthentication:   ${pass_auth:-не определён} (требуется no)"
  echo "  PubkeyAuthentication:     ${pubkey_auth:-не определён} (требуется yes)"
  echo "  PermitRootLogin:          ${root_login:-не определён} (требуется no)"
  echo "  KbdInteractiveAuth:       ${kbd_auth:-не определён} (требуется no)"
  echo "  MaxAuthTries:             ${max_auth:-не определён} (требуется 3)"
  echo
  echo "Будет настроено: порт $SSH_PORT, вход по ключу, без паролей, root запрещён."
  warn "Не закрывайте текущую SSH-сессию до успешной проверки нового входа."
  ask "Применить настройки SSH? [y/N]: " answer || { error "Не удалось прочитать подтверждение"; return 1; }
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    info "Настройка SSH пропущена по вашему выбору"
    return 3
  fi

  # Критическая preflight-проверка: если UFW уже активен, новый SSH-порт
  # должен быть разрешён до изменения sshd. Старый порт намеренно сохраняем.
  if ! ensure_ufw_ssh_port check; then
    error "Новый SSH-порт не подтверждён в UFW — конфигурация SSH не изменена"
    return 1
  fi

  # Refuse special files before the backup as well (cp could block on a FIFO).
  if [ -L /etc/ssh/sshd_config ] || [ ! -f /etc/ssh/sshd_config ]; then
    error "sshd_config должен быть обычным файлом, не symlink"
    return 1
  fi
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)" || {
    error "Не удалось создать резервную копию sshd_config"
    return 1
  }

  local listener_status=0
  check_ssh_port || listener_status=$?
  case "$listener_status" in
    0|1) ;;
    4) error "Порт $SSH_PORT занят чужим listener; SSH не изменён"; return 1 ;;
    *) error "Не удалось проверить владельца SSH listener; SSH не изменён"; return 1 ;;
  esac
  local socket_state socket_plan socket_mode ssh_snapshot
  if ! socket_state="$(systemctl show ssh.socket -p LoadState -p ActiveState -p UnitFileState -p Listen -p Triggers -p Accept -p NeedDaemonReload -p DropInPaths)"; then
    error "Не удалось определить bind policy ssh.socket"; return 1
  fi
  if ! socket_plan="$(access_safety socket "$SSH_PORT" <<< "$socket_state")"; then
    error "Не удалось безопасно сохранить bind policy; проверьте systemctl cat ssh.socket"; return 1
  fi
  socket_mode="${socket_plan%%$'\n'*}"
  if [ "$socket_mode" = service ]; then
    local proposed
    proposed="$(sshd -T -o "Port=$SSH_PORT")" || { error "Не удалось проверить service bind policy"; return 1; }
    if ! awk -v port="$SSH_PORT" '$1 == "listenaddress" {n++; if ($2 !~ ":"port"$") bad=1} END {exit (!n || bad)}' <<< "$proposed"; then
      error "Explicit ListenAddress port несовместим; сохраните адреса и настройте порт вручную"; return 1
    fi
  fi
  local targets=(/etc/ssh/sshd_config /etc/ssh/sshd_config.d/00-vps-hardening.conf)
  if [ "$socket_mode" = socket ]; then targets+=(/etc/systemd/system/ssh.socket.d/99-vps-port.conf); fi
  ssh_snapshot="$(access_safety snapshot "${targets[@]}")" || {
    error "Не удалось сохранить SSH snapshots"; return 1;
  }

  if ! (
  if ! set_sshd_line Port "$SSH_PORT"; then
    error "Не удалось настроить Port в sshd_config"
    return 1
  fi
  mkdir -p /etc/ssh/sshd_config.d || {
    error "Не удалось создать /etc/ssh/sshd_config.d"
    return 1
  }

  if ! atomic_config /etc/ssh/sshd_config.d/00-vps-hardening.conf text <<EOF
# VPS hardening settings (создано tunevps.sh)
# Этот файл загружается ПЕРВЫМ (номер 00), чтобы переопределить
# настройки из 50-cloud-init.conf и других файлов.

# Port управляется в основном sshd_config; здесь — аутентификация.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no

# Защита от brute-force
MaxAuthTries 3

# Безопасность окружения
PermitUserEnvironment no

# PAM
UsePAM yes

# Keepalive: клиент отключается через 60*3 = 180 секунд неактивности
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3

# Подробные логи
LogLevel VERBOSE
EOF
  then
    error "Не удалось записать /etc/ssh/sshd_config.d/00-vps-hardening.conf"
    return 1
  fi

  if [ "$socket_mode" = socket ]; then
    mkdir -p /etc/systemd/system/ssh.socket.d || return 1
    if ! atomic_config /etc/systemd/system/ssh.socket.d/99-vps-port.conf text <<< "${socket_plan#*$'\n'}"; then
      error "Не удалось записать socket bind policy"; return 1
    fi
  fi
  if ! sshd -t; then
    error "Aggregate sshd -t failed; restoring managed SSH files"; return 1
  fi
  key_effective="$(sshd -T -C "user=$PIN_USER,host=$context_addr,addr=$context_addr,laddr=$context_laddr,lport=$SSH_PORT" -ddd 2>&1)" || return 1
  access_safety effective "$home" "$PIN_USER" checked-context <<< "$key_effective" || return 1
  if ! ensure_ufw_ssh_port; then
    error "UFW SSH access verification failed"; return 1
  fi
  ); then
    if ! access_safety restore <<< "$ssh_snapshot"; then
      error "FATAL: SSH rollback incomplete; managed paths: ${targets[*]}"; return 1
    fi
    error "SSH apply failed; managed files restored and verified; no restart"
    return 1
  fi

  if [ "$socket_mode" = socket ]; then
    if ! systemctl daemon-reload; then
      error "Не удалось выполнить systemctl daemon-reload для SSH"
      return 1
    fi
    if ! systemctl restart ssh.socket; then
      error "Не удалось перезапустить ssh.socket"
      return 1
    fi
  else
    if ! systemctl reload ssh.service && ! systemctl restart ssh.service; then
      error "Не удалось перезагрузить ssh.service"
      return 1
    fi
  fi
  sleep 2

  if check_ssh_port; then
    ok "SSH слушает $SSH_PORT"
  else
    listener_status=$?
    case "$listener_status" in
      1) error "Порт $SSH_PORT не слушается; текущую сессию не закрывайте" ;;
      4) error "Порт $SSH_PORT занят чужим listener; текущую сессию не закрывайте" ;;
      *) error "Не удалось проверить SSH listener; текущую сессию не закрывайте" ;;
    esac
    systemctl status ssh.socket ssh.service --no-pager || true
    return 1
  fi

  if ss -ltn | awk '$4 ~ /:22$/' | grep -q .; then
    warn "Порт 22 всё ещё слушается; покажите: systemctl cat ssh.socket"
  fi

  # One checked post-apply snapshot: display and validate the same output.
  if ! effective="$(sshd -T 2>&1)"; then
    error "Не удалось получить итоговую конфигурацию sshd (sshd -T)"
    printf '%s\n' "$effective" >&2
    return 1
  fi
  info "Итоговая конфигурация SSH (sshd -T):"
  printf '%s\n' "$effective" | grep -E "^(port|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|permituserenvironment|usepam|tcpkeepalive|clientaliveinterval|clientalivecountmax|maxauthtries|loglevel) " | sort

  local field expected actual
  while read -r field expected; do
    # OpenSSH can emit repeated identical ports; compare distinct port values.
    actual=$(awk -v field="$field" '$1 == field && (field != "port" || !seen[$2]++) {print $2}' <<< "$effective")
    if [ "$actual" != "$expected" ]; then
      error "$field=${actual:-не определён} (должно быть '$expected')"
      return 1
    fi
  done <<EOF
port $SSH_PORT
passwordauthentication no
pubkeyauthentication yes
permitrootlogin no
kbdinteractiveauthentication no
maxauthtries 3
EOF
  ok "Обязательные настройки SSH применены"

  return 0
}

as_current_user() {
  sudo -H -u "$CURRENT_USER" env HOME="$USER_HOME" "$@"
}

configure_shell() {
  section "ZSH, OH MY ZSH И POWERLEVEL10K"
  chsh -s /usr/bin/zsh "$CURRENT_USER" || {
    error "Не удалось изменить shell для $CURRENT_USER на /usr/bin/zsh"
    return 1
  }
  if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
    as_current_user git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$USER_HOME/.oh-my-zsh" || {
      error "Не удалось установить Oh My Zsh"
      return 1
    }
  fi
  local custom="$USER_HOME/.oh-my-zsh/custom"
  if [ ! -d "$custom/themes/powerlevel10k" ]; then
    as_current_user git clone --depth=1 --recurse-submodules "$P10K_REPOSITORY" "$custom/themes/powerlevel10k" || {
      error "Не удалось установить Powerlevel10k"
      return 1
    }
  fi
  for spec in \
    "zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git" \
    "zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git" \
    "zsh-completions https://github.com/zsh-users/zsh-completions.git"; do
    set -- $spec
    [ -d "$custom/plugins/$1" ] || as_current_user git clone --depth=1 "$2" "$custom/plugins/$1" || {
      error "Не удалось установить плагин $1"
      return 1
    }
  done

  local managed_dir="$USER_HOME/.config/tunevps"
  as_current_user mkdir -p "$managed_dir" || {
    error "Не удалось создать каталог $managed_dir"
    return 1
  }
  atomic_config --user "$managed_dir/zshrc" text <<'EOF'
# PATH — до P10K и Oh My Zsh.
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
if [[ -r "$HOME/.cache/p10k-instant-prompt-$USER.zsh" ]]; then
  source "$HOME/.cache/p10k-instant-prompt-$USER.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(
  git
  zsh-autosuggestions
  zsh-completions
  sudo
  extract
  zsh-syntax-highlighting
)
source "$ZSH/oh-my-zsh.sh"

# Первый интерактивный вход запускает мастер P10K.
if [[ -o interactive && ! -r "$HOME/.p10k.zsh" ]] && (( $+functions[p10k] )); then
  p10k configure
fi

# === Алиасы для установленных утилит ===
# Настоящий `cat` остаётся, добавлен bcat
if (( $+commands[bat] )); then
  alias bcat='bat --paging=never'
fi
if (( $+commands[eza] )); then
  alias ls='eza --icons'
  alias ll='eza -la --icons --git'
  alias lt='eza --tree --icons --level=2'
fi
# Настоящий `grep` остаётся, добавлен удобный алиас для `rg`
if (( $+commands[rg] )); then
  alias rg='rg --smart-case'
fi
if (( $+commands[btop] )); then
  alias top='btop'
fi

alias ..='cd ..'
alias ...='cd ../..'
alias ports='ss -tulnp'
alias listen='ss -ltnup'
alias myip='curl -4 -s ifconfig.me'
alias myip6='curl -6 -s ifconfig.me'
alias h='history'
alias hg='history | grep'
alias reload='source ~/.zshrc'
alias dfh='df -hT'
alias mem='free -h'
alias update='sudo apt update && sudo apt upgrade'

# UFW и SSH
alias ufwv='sudo ufw status verbose'
alias ufwn='sudo ufw status numbered'
alias ufwl='sudo journalctl -u ufw -n 50 --no-pager'
alias sshlog='sudo journalctl -u ssh -n 50 --no-pager'
alias sshcheck='sudo sshd -t && echo "SSH config OK"'

# Мониторинг
alias iotop='sudo iotop'
alias ncdu='ncdu --color dark'

# === ФZF ===
setup_fzf() {
  (( $+commands[fzf] )) || return 0
  if fzf --zsh >/dev/null 2>&1; then
    eval "$(fzf --zsh)"
    return 0
  fi
  local fzf_paths=(
    "/usr/share/doc/fzf/examples/key-bindings.zsh"
    "/usr/share/fzf/key-bindings.zsh"
    "/usr/local/share/fzf/key-bindings.zsh"
  )
  local fzf_file
  for fzf_file in "${fzf_paths[@]}"; do
    if [[ -r "$fzf_file" ]]; then
      source "$fzf_file"
      local fzf_completion="${fzf_file%/*}/completion.zsh"
      [[ -r "$fzf_completion" ]] && source "$fzf_completion"
      return 0
    fi
  done
  print -P "%F{yellow}[WARN]%f fzf установлен, но его zsh key-bindings не найдены"
}
setup_fzf
unfunction setup_fzf 2>/dev/null

if (( $+commands[fd] )); then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
fi

if (( $+commands[zoxide] )); then
  eval "$(zoxide init zsh)"
fi

[[ ! -r "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"
EOF
  [ "$?" -eq 0 ] || {
    error "Не удалось записать $managed_dir/zshrc"
    return 1
  }

  # Preserve user bytes; run the atomic writer without root privileges.
  if ! atomic_config --user "$USER_HOME/.zshrc" zshrc
  then
    error "Не удалось обновить managed block в $USER_HOME/.zshrc"
    return 1
  fi
  ok "Zsh и P10K настроены для $CURRENT_USER"
  info "После нового SSH-входа под $CURRENT_USER мастер P10K стартует автоматически."
}

# Download completely before parsing/executing; traps are scoped to this subshell.
run_remote_diagnostic() (
  local url="$1" temporary status=0
  shift
  case "$url" in
    https://*) ;;
    *) error "Для загрузки диагностики требуется HTTPS"; return 1 ;;
  esac
  temporary=$(mktemp "${TMPDIR:-/tmp}/tunevps-diagnostic.XXXXXXXX") || {
    error "Не удалось создать временный файл диагностики"; return 1;
  }
  trap 'status=$?; if ! rm -f -- "$temporary"; then error "Не удалось удалить временный файл диагностики"; [ "$status" -ne 0 ] || status=1; fi; exit "$status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -L "$temporary" ] || [ ! -f "$temporary" ]; then
    error "Временный файл диагностики должен быть обычным файлом"
    return 1
  fi
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 180 --output "$temporary" "$url" || {
    status=$?; error "Не удалось полностью загрузить диагностику: $url"; return "$status";
  }
  if [ -L "$temporary" ] || [ ! -f "$temporary" ] || [ ! -s "$temporary" ]; then
    error "Загруженный файл диагностики пуст или не является обычным файлом"
    return 1
  fi
  bash -n -- "$temporary" || {
    status=$?; error "Загруженная диагностика не прошла проверку синтаксиса"; return "$status";
  }
  bash -- "$temporary" "$@" || {
    status=$?; error "Диагностика завершилась ошибкой (код $status)"; return "$status";
  }
  return 0
)

final_check() {
  local failed=0
  section "ФИНАЛЬНАЯ ПРОВЕРКА"

  if ! install -d -m 0755 /run/sshd; then
    error "Не удалось подготовить /run/sshd для проверки SSH"
    failed=1
  fi

  local status=0
  check_ssh_port || status=$?
  case "$status" in
    0) ok "SSH слушает порт $SSH_PORT ✓" ;;
    4) error "Порт $SSH_PORT занят чужим listener"; failed=1 ;;
    1) error "SSH НЕ слушает порт $SSH_PORT! ⚠️"; failed=1 ;;
    *) error "Не удалось проверить listener на порту $SSH_PORT"; failed=1 ;;
  esac

  if systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket; then
    ok "SSH активен (service или socket) ✓"
  else
    error "Не удалось подтвердить активность SSH (service или socket)! ⚠️"
    failed=1
  fi

  if sshd -t; then
    ok "Синтаксис sshd_config корректен ✓"
  else
    error "Проверка sshd_config (sshd -t) завершилась ошибкой! ⚠️"
    failed=1
  fi

  local effective field expected actual
  if effective="$(sshd -T)"; then
    while read -r field expected; do
      # Port is a list in sshd -T; identical entries do not change its value.
      if ! actual=$(awk -v field="$field" '$1 == field && (field != "port" || !seen[$2]++) {print $2}' <<< "$effective"); then
        error "Не удалось прочитать поле SSH $field"
        failed=1
      elif [ "$actual" = "$expected" ]; then
        ok "$field=$expected ✓"
      else
        error "$field=${actual:-не определён} (должно быть '$expected')"
        failed=1
      fi
    done <<EOF
port $SSH_PORT
passwordauthentication no
pubkeyauthentication yes
permitrootlogin no
kbdinteractiveauthentication no
maxauthtries 3
EOF
  else
    error "Не удалось получить эффективную конфигурацию SSH (sshd -T)"
    failed=1
  fi

  local bbr swap_output
  if ! bbr=$(sysctl -n net.ipv4.tcp_congestion_control); then
    error "Не удалось прочитать алгоритм контроля перегрузки"
    failed=1
  elif [ -z "$bbr" ]; then
    error "Получен пустой алгоритм контроля перегрузки"
    failed=1
  elif [ "$bbr" = "bbr" ]; then
    ok "BBR включён ✓"
  else
    info "Алгоритм контроля перегрузки: $bbr"
  fi

  if ! swap_output=$(swapon --show --noheadings); then
    error "Не удалось получить состояние swap"
    failed=1
  elif [ -n "$swap_output" ]; then
    ok "Swap настроен ✓"
  else
    info "Активный swap отсутствует"
  fi

  if command -v ufw >/dev/null 2>&1; then
    status=0
    ufw_is_active || status=$?
    case "$status" in
      0) ok "UFW активен ✓" ;;
      1) warn "UFW НЕ активен" ;;
      *) error "Не удалось проверить состояние UFW"; failed=1 ;;
    esac
  else
    warn "UFW не установлен"
  fi

  if command -v zoxide >/dev/null 2>&1; then
    ok "zoxide установлен ✓"
  else
    warn "zoxide НЕ установлен"
  fi

  if [ -d "$USER_HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]; then
    ok "Powerlevel10k установлен ✓"
  else
    warn "Powerlevel10k не найден"
  fi

  if [ -f "$USER_HOME/.zshrc" ]; then
    ok ".zshrc создан для $CURRENT_USER ✓"
  else
    error ".zshrc НЕ найден! ⚠️"
    failed=1
  fi

  # Manager default does not describe existing processes or per-unit overrides.
  local default_nofile
  if ! default_nofile=$(systemctl show --property=DefaultLimitNOFILE --value); then
    error "Не удалось прочитать systemd DefaultLimitNOFILE"
    failed=1
  elif [[ ! "$default_nofile" =~ ^[0-9]+$ && "$default_nofile" != infinity ]]; then
    error "Некорректный ответ systemd DefaultLimitNOFILE"
    failed=1
  elif [ "$default_nofile" = "1048576" ]; then
    ok "systemd DefaultLimitNOFILE=1048576 ✓"
  else
    warn "systemd DefaultLimitNOFILE=$default_nofile"
  fi

  if [ "$IS_MINIMIZED" = true ]; then
    warn "⚠️  Система осталась в minimized состоянии"
  fi
  return "$failed"
}

part2_setup() {
  section "ЧАСТЬ 2: ОКРУЖЕНИЕ"

  # КРИТИЧНЫЕ ЭТАПЫ с контролем ошибок
  if ! install_packages; then
    error "Не удалось установить базовые пакеты — останавливаюсь"
    return 1
  fi

  configure_locale_time || return $?

  configure_unattended_upgrades || return $?

  # Менее критичные этапы (без остановки при ошибке)
  configure_autoremove || return $?
  configure_needrestart || return $?

  if ! configure_safe_sysctl; then
    error "Не удалось применить безопасные sysctl — останавливаюсь"
    return 1
  fi

  if ! configure_systemd_limits; then
    error "Не удалось настроить лимиты для сервисов — останавливаюсь"
    return 1
  fi

  if ! configure_swap; then
    error "Не удалось настроить swap — останавливаюсь"
    return 1
  fi

  if ! configure_pin; then
    error "Настройка пользователя $PIN_USER завершилась ошибкой"
    return 1
  fi

  # configure_ssh сам делает UFW preflight: если UFW уже активен,
  # порт $SSH_PORT/tcp разрешается и проверяется ДО переключения sshd.
  # SSH contract: 0 = compliant/applied, 3 = user skip, other = failure.
  local ssh_status=0
  configure_ssh || ssh_status=$?
  if [ "$ssh_status" -eq 3 ]; then
    info "Часть 2 остановлена: SSH пропущен; UFW и последующие шаги не выполнены"
    return 3
  elif [ "$ssh_status" -ne 0 ]; then
    error "Настройка SSH завершилась ошибкой — останавливаюсь"
    error "Доступ по текущей сессии сохранён, проверьте логи выше"
    return 1
  fi

  configure_ufw || return $?
  configure_shell || return $?
  final_check || return $?
  ok "Часть 2 завершена"
}

part3_tests() {
  section "ЧАСТЬ 3: ТЕСТЫ И ДИАГНОСТИКА"
  echo "  1) IP region"
  echo "  2) Censorcheck для проверки геоблока"
  echo "  3) Censorcheck для серверов РФ"
  echo "  4) Тест до российских iPerf3 серверов"
  echo "  5) YABS"
  echo "  6) Проверка IP сервера на блокировки зарубежными сервисами"
  echo "  7) Параметры сервера и проверка скорости к зарубежным провайдерам"
  echo "  8) IPQuality"
  echo "  9) Тест на процессор, можно понять примерно какой процент CPU выделили"
  echo "  0) Назад"
  local choice
  ask "Выбор: " choice || { error "Не удалось прочитать выбор диагностики"; return 1; }
  local status=0
  case "$choice" in
    1) run_remote_diagnostic https://ipregion.vrnt.xyz || status=$? ;;
    2) run_remote_diagnostic https://github.com/vernette/censorcheck/raw/master/censorcheck.sh --mode geoblock || status=$? ;;
    3) run_remote_diagnostic https://github.com/vernette/censorcheck/raw/master/censorcheck.sh --mode dpi || status=$? ;;
    4) run_remote_diagnostic https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh || status=$? ;;
    5) run_remote_diagnostic https://yabs.sh -4 || status=$? ;;
    6) run_remote_diagnostic https://IP.Check.Place -l en || status=$? ;;
    7) run_remote_diagnostic https://bench.sh || status=$? ;;
    8) run_remote_diagnostic https://Check.Place -EI || status=$? ;;
    9) sysbench cpu run --threads=1 || status=$? ;;
    0) return 0 ;;
    *) warn "Неверный выбор" ;;
  esac
  if [ "$status" -ne 0 ]; then
    error "Выбранная диагностика завершилась ошибкой (код $status)"
  fi
  return "$status"
}

while true; do
  echo
  echo "1) Первое обновление / unminimize"
  echo "2) Настройка окружения"
  echo "3) Тесты"
  echo "0) Выход"
  choice=""
  if ! ask "Выберите действие [0-3]: " choice; then
    error "Не удалось прочитать выбор действия"
    exit 1
  fi
  case "$choice" in
    1) part1_update || exit $? ;;
    2) part2_setup || exit $? ;;
    3) part3_tests || error "Тест не завершён успешно; возврат в главное меню" ;;
    0) exit 0 ;;
    *) warn "Неверный выбор" ;;
  esac
  pause || { error "Не удалось прочитать ответ для продолжения"; exit 1; }
done
