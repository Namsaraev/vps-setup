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
  local prompt="$1" variable="$2" read_status=0
  printf '%s' "$prompt" > /dev/tty
  IFS= read -r -s "$variable" < /dev/tty || read_status=$?
  printf '\n' > /dev/tty
  if [ "$read_status" -ne 0 ]; then
    error "Не удалось прочитать пароль из /dev/tty"
    return "$read_status"
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

# Надёжная проверка: порт должен быть в конце поля локального адреса (4-е поле)
# Работает для 0.0.0.0:5829, [::]:5829, *:5829
check_ssh_port() {
  ss -ltn | awk -v suffix=":$SSH_PORT" '$4 ~ suffix"$" {found=1} END {exit !found}'
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

configure_unattended_upgrades() {
  section "АВТО-ОБНОВЛЕНИЯ БЕЗОПАСНОСТИ"
  mkdir -p /etc/apt/apt.conf.d || { error "Не удалось создать каталог /etc/apt/apt.conf.d"; return 1; }
  if ! cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
  then
    error "Не удалось записать /etc/apt/apt.conf.d/20auto-upgrades"
    return 1
  fi

  # Конфигурация обязательна; включение таймеров остаётся best-effort.
  local timers_ok=true
  for timer in apt-daily.timer apt-daily-upgrade.timer; do
    if ! systemctl is-enabled "$timer" >/dev/null 2>&1; then
      systemctl enable "$timer" 2>/dev/null || {
        warn "Не удалось включить $timer"
        timers_ok=false
      }
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
  if ! cat > /etc/apt/apt.conf.d/50auto-remove <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
EOF
  then
    error "Не удалось отключить автоудаление зависимостей"
    return 1
  fi
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
      ok "Автоматический перезапуск включён"
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
  local bbr_available=false
  local bbr_module=false

  if command -v modinfo >/dev/null 2>&1 && modinfo tcp_bbr >/dev/null 2>&1; then
    bbr_module=true
  fi

  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    if [ "$bbr_module" = true ]; then
      # Отсутствие модуля допустимо; сбой загрузки уже найденного модуля — ошибка.
      command -v modprobe >/dev/null 2>&1 || { error "tcp_bbr найден, но modprobe недоступен"; return 1; }
      info "BBR найден как модуль tcp_bbr, загружаем его"
      if modprobe tcp_bbr 2>/dev/null; then
        ok "Модуль tcp_bbr загружен"
      else
        error "Не удалось загрузить найденный модуль tcp_bbr"
        return 1
      fi
    fi
  fi

  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    bbr_available=true
    if [ "$bbr_module" = true ]; then
      mkdir -p /etc/modules-load.d || { error "Не удалось создать /etc/modules-load.d"; return 1; }
      if ! printf '%s\n' tcp_bbr > /etc/modules-load.d/tcp_bbr.conf; then
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
  if ! cat > /etc/sysctl.d/99-vps-tuning.conf <<EOF
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

  mkdir -p /etc/security/limits.d || { error "Не удалось создать /etc/security/limits.d"; return 1; }
  if ! cat > /etc/security/limits.d/99-vps.conf <<'EOF'
* soft nofile 524288
* hard nofile 1048576
root soft nofile 524288
root hard nofile 1048576
EOF
  then
    error "Не удалось записать /etc/security/limits.d/99-vps.conf"
    return 1
  fi
  ok "Безопасные sysctl применены"
  return 0
}

# Глобальный лимит для systemd-сервисов
configure_systemd_limits() {
  section "ЛИМИТЫ ДЛЯ SYSTEMD-СЕРВИСОВ"
  info "limits.d применяется только к интерактивным сессиям (через PAM)."
  info "Для системных сервисов (Xray, 3x-ui, Docker) задаём глобальный лимит."
  mkdir -p /etc/systemd/system.conf.d || { error "Не удалось создать /etc/systemd/system.conf.d"; return 1; }
  if ! cat > /etc/systemd/system.conf.d/99-nofile.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
  then
    error "Не удалось записать /etc/systemd/system.conf.d/99-nofile.conf"
    return 1
  fi
  if systemctl daemon-reexec; then
    ok "DefaultLimitNOFILE=1048576 применён ко всем сервисам"
  else
    error "Не удалось выполнить systemctl daemon-reexec"
    return 1
  fi
}

configure_swap() {
  section "SWAP"

  local ram desired_bytes desired_human active_output
  local own_bytes=0 foreign_count=0
  local source size_bytes type answer

  # Проверяем, что SWAP_SIZE задан в формате, который понимает fallocate.
  if ! [[ "$SWAP_SIZE" =~ ^[1-9][0-9]*([KMGTP]i?B?|[KMGTP])?$ ]]; then
    error "Некорректный SWAP_SIZE: $SWAP_SIZE"
    return 1
  fi

  # Переводим SWAP_SIZE в байты без зависимости от numfmt.
  swap_size_to_bytes() {
    local value="$1" number suffix multiplier
    number="${value%%[KMGTPiB]*}"
    suffix="${value#$number}"
    case "${suffix^^}" in
      ""|B) multiplier=1 ;;
      K|KB|KI|KIB) multiplier=1024 ;;
      M|MB|MI|MIB) multiplier=1048576 ;;
      G|GB|GI|GIB) multiplier=1073741824 ;;
      T|TB|TI|TIB) multiplier=1099511627776 ;;
      P|PB|PI|PIB) multiplier=1125899906842624 ;;
      *) return 1 ;;
    esac
    printf '%s\n' "$((number * multiplier))"
  }

  desired_bytes="$(swap_size_to_bytes "$SWAP_SIZE")" || {
    error "Не удалось разобрать SWAP_SIZE=$SWAP_SIZE"
    return 1
  }
  desired_human="$SWAP_SIZE"

  # Ошибка чтения списка не означает отсутствие swap: ничего не меняем.
  if ! active_output=$(swapon --show=NAME,SIZE,TYPE --bytes --noheadings); then
    error "Не удалось определить активные swap-источники; swap не изменён"
    return 1
  fi
  while read -r source size_bytes type; do
    [ -n "$source" ] || continue
    if ! [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
      error "Не удалось разобрать размер swap: $source; swap не изменён"
      return 1
    fi
    if [ "$source" = /swapfile ]; then
      own_bytes="$size_bytes"
    else
      foreign_count=$((foreign_count + 1))
      info "Чужой swap-источник: $source — $size_bytes байт ($type); оставлен без изменений"
    fi
  done <<< "$active_output"

  if [ "$own_bytes" -gt 0 ]; then
    # mkswap резервирует одну страницу под заголовок.
    local page_size
    page_size=$(getconf PAGESIZE 2>/dev/null || echo 4096)
    [[ "$page_size" =~ ^[1-9][0-9]*$ ]] || page_size=4096
    if [ "$own_bytes" -le "$desired_bytes" ] &&
       [ "$((desired_bytes - own_bytes))" -le "$page_size" ]; then
      ok "Размер /swapfile соответствует $desired_human — ничего не меняем"
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
    ram="$(LC_ALL=C free -m | awk '/^Mem:/ {print $2}')"
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
  if [ "$own_bytes" -gt 0 ] && ! swapoff /swapfile; then
    error "Не удалось отключить /swapfile"
    return 1
  fi
  [ ! -f /swapfile ] || rm -f -- /swapfile || {
    error "Не удалось удалить старый /swapfile"
    return 1
  }

  # Создаём новый swap-файл. fallocate быстрее; dd — запасной вариант для FS,
  # где fallocate создаёт неподходящий файл.
  if ! fallocate -l "$SWAP_SIZE" /swapfile; then
    local count_mb=$((desired_bytes / 1048576))
    if [ "$count_mb" -lt 1 ]; then count_mb=1; fi
    if ! dd if=/dev/zero of=/swapfile bs=1M count="$count_mb" status=progress; then
      error "Не удалось создать /swapfile"
      rm -f /swapfile
      return 1
    fi
  fi

  chmod 600 /swapfile || { error "Не удалось установить права 600 на /swapfile"; return 1; }
  if ! mkswap /swapfile >/dev/null; then
    error "mkswap завершился с ошибкой"
    rm -f /swapfile
    return 1
  fi
  if ! swapon /swapfile; then
    error "swapon завершился с ошибкой"
    rm -f /swapfile
    return 1
  fi

  # Нормализуем только записи swap с первым полем /swapfile.
  # Чужие строки, включая комментарии, сохраняются дословно.
  sed -Ei '\@^[[:space:]]*/swapfile[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$)@d' /etc/fstab || {
    error "Не удалось обновить /etc/fstab"
    return 1
  }
  printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab || {
    error "Не удалось записать /swapfile в /etc/fstab; /swapfile может быть активен в текущей сессии, но автоподключение после перезагрузки не настроено"
    return 1
  }

  if swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null | awk '$1 == "/swapfile" && $2 > 0 {found=1} END {exit !found}'; then
    ok "Swap $desired_human создан и активирован"
  else
    error "Swap создан, но проверка активации не пройдена"
    return 1
  fi
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
  if [ ! -f "$file" ]; then
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
  # ЗАМЕЧАНИЕ 2: проверяем создание директории
  if ! mkdir -p "$sshdir"; then
    error "Не удалось создать $sshdir"
    return 1
  fi

  # Атомарная запись через временный файл с проверками
  local tmp_keys="${keys}.tmp.$$"
  if [ "$is_new" = true ] || [ "$replace_mode" = true ]; then
    if ! printf '%s\n' "$public_key" > "$tmp_keys"; then
      rm -f "$tmp_keys"
      error "Не удалось записать ключ во временный файл"
      return 1
    fi
  else
    if ! (
      if [ -e "$keys" ]; then
        cat "$keys" || exit 1
        # Отделяем новый ключ, даже если последняя запись не заканчивается LF.
        printf '\n' || exit 1
      fi
      printf '%s\n' "$public_key"
    ) > "$tmp_keys"; then
      rm -f "$tmp_keys"
      error "Не удалось записать ключ во временный файл"
      return 1
    fi
  fi
  if ! chmod 600 "$tmp_keys"; then
    error "Не удалось установить права 600 на $tmp_keys"
    rm -f "$tmp_keys"
    return 1
  fi

  # ЗАМЕЧАНИЕ 2: проверяем атомарную замену
  if ! mv -f "$tmp_keys" "$keys"; then
    error "Не удалось записать ключ в $keys"
    rm -f "$tmp_keys"
    return 1
  fi

  if ! chown -R "$PIN_USER:$PIN_USER" "$sshdir"; then
    error "Не удалось установить владельца для $sshdir"
    return 1
  fi
  if ! chmod 700 "$sshdir"; then
    error "Не удалось установить права 700 на $sshdir"
    return 1
  fi
  if ! chmod 600 "$keys"; then
    error "Не удалось установить права 600 на $keys"
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

  info "UFW активен — заранее разрешаем SSH-порт $SSH_PORT/tcp"
  if ! ufw allow "$SSH_PORT/tcp" comment 'SSH'; then
    error "Не удалось разрешить $SSH_PORT/tcp в UFW"
    return 1
  fi

  if ! status_output="$(LC_ALL=C ufw status)"; then
    error "Не удалось проверить статус UFW после добавления SSH-правила"
    return 2
  fi
  if awk -v port="$SSH_PORT/tcp" '$1 == port && $2 == "ALLOW" {found=1} END {exit !found}' <<< "$status_output"; then
    ok "UFW разрешает $SSH_PORT/tcp"
  else
    error "После изменения UFW правило ALLOW для $SSH_PORT/tcp не найдено"
    return 1
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
  local name="$1" value="$2" status
  if grep -qE "^#?$name[[:space:]]+" /etc/ssh/sshd_config; then
    sed -Ei "s|^#?$name[[:space:]]+.*|$name $value|" /etc/ssh/sshd_config || {
      error "Не удалось обновить $name в /etc/ssh/sshd_config"
      return 1
    }
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      error "Не удалось проверить $name в /etc/ssh/sshd_config"
      return 1
    fi
    echo "$name $value" >> /etc/ssh/sshd_config || {
      error "Не удалось добавить $name в /etc/ssh/sshd_config"
      return 1
    }
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
  if ! ensure_ufw_ssh_port; then
    error "Новый SSH-порт не подтверждён в UFW — конфигурация SSH не изменена"
    return 1
  fi

  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)" || {
    error "Не удалось создать резервную копию sshd_config"
    return 1
  }

  if ! set_sshd_line Port "$SSH_PORT"; then
    error "Не удалось настроить Port в sshd_config"
    return 1
  fi
  mkdir -p /etc/ssh/sshd_config.d || {
    error "Не удалось создать /etc/ssh/sshd_config.d"
    return 1
  }

  if ! cat > /etc/ssh/sshd_config.d/00-vps-hardening.conf <<EOF
# VPS hardening settings (создано tunevps.sh)
# Этот файл загружается ПЕРВЫМ (номер 00), чтобы переопределить
# настройки из 50-cloud-init.conf и других файлов.

# Сетевой порт и аутентификация
Port $SSH_PORT
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

  if ! sshd -t; then
    error "Ошибка sshd_config. Конфиг не перезапущен."
    return 1
  fi

  if ! sshd -T | awk -v port="$SSH_PORT" '$1 == "port" && $2 == port {found=1} END {exit !found}'; then
    error "sshd не принял порт $SSH_PORT; проверьте /etc/ssh/sshd_config и *.d"
    return 1
  fi

  mkdir -p /etc/systemd/system/ssh.socket.d || {
    error "Не удалось создать /etc/systemd/system/ssh.socket.d"
    return 1
  }
  if ! cat > /etc/systemd/system/ssh.socket.d/99-vps-port.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:$SSH_PORT
ListenStream=[::]:$SSH_PORT
EOF
  then
    error "Не удалось записать /etc/systemd/system/ssh.socket.d/99-vps-port.conf"
    return 1
  fi

  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
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
    error "Порт $SSH_PORT не слушается; текущую сессию не закрывайте"
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
    actual=$(awk -v field="$field" '$1 == field {print $2}' <<< "$effective")
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
  as_current_user tee "$managed_dir/zshrc" >/dev/null <<'EOF'
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

  # Python is installed by install_packages(). Preserve user bytes, including
  # CRLF and a missing final newline; never interpret the user's shell code.
  if ! as_current_user python3 - "$USER_HOME/.zshrc" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
original = path.read_bytes() if path.exists() else b""
begin = b"# >>> tunevps managed block >>>"
end = b"# <<< tunevps managed block <<<"
block = (begin + b'\nsource "$HOME/.config/tunevps/zshrc"\n' + end + b"\n")
lines = original.splitlines(keepends=True)
starts = [i for i, line in enumerate(lines) if line.rstrip(b"\r\n") == begin]
ends = [i for i, line in enumerate(lines) if line.rstrip(b"\r\n") == end]
if not starts and not ends:
    # Put defaults first so the user's settings can override them afterwards.
    updated = block + original
elif len(starts) == len(ends) == 1 and starts[0] < ends[0]:
    updated = b"".join(lines[:starts[0]]) + block + b"".join(lines[ends[0] + 1:])
else:
    sys.exit("Invalid or duplicate tunevps managed markers; .zshrc unchanged")
if updated != original:
    path.write_bytes(updated)
PY
  then
    error "Не удалось обновить managed block в $USER_HOME/.zshrc"
    return 1
  fi
  ok "Zsh и P10K настроены для $CURRENT_USER"
  info "После нового SSH-входа под $CURRENT_USER мастер P10K стартует автоматически."
}

final_check() {
  local failed=0
  section "ФИНАЛЬНАЯ ПРОВЕРКА"

  install -d -m 0755 /run/sshd 2>/dev/null || true

  if check_ssh_port; then
    ok "SSH слушает порт $SSH_PORT ✓"
  else
    error "SSH НЕ слушает порт $SSH_PORT! ⚠️"
    failed=1
  fi

  if systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket; then
    ok "SSH активен (service или socket) ✓"
  else
    error "SSH НЕ активен! ⚠️"
    failed=1
  fi

  if sshd -t 2>/dev/null; then
    ok "Синтаксис sshd_config корректен ✓"
  else
    error "Ошибка синтаксиса sshd_config! ⚠️"
    failed=1
  fi

  local pass_auth pubkey_auth root_login
  pass_auth=$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}')
  pubkey_auth=$(sshd -T 2>/dev/null | awk '$1 == "pubkeyauthentication" {print $2}')
  root_login=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2}')

  if [ "$pass_auth" = "no" ]; then
    ok "PasswordAuthentication=no ✓"
  else
    error "PasswordAuthentication=$pass_auth (должно быть 'no')!"
    failed=1
  fi
  if [ "$pubkey_auth" = "yes" ]; then
    ok "PubkeyAuthentication=yes ✓"
  else
    warn "PubkeyAuthentication=$pubkey_auth"
  fi
  if [ "$root_login" = "no" ]; then
    ok "PermitRootLogin=no ✓"
  else
    warn "PermitRootLogin=$root_login"
  fi

  local bbr
  bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
  if [ "$bbr" = "bbr" ]; then
    ok "BBR включён ✓"
  else
    info "Алгоритм контроля перегрузки: $bbr"
  fi

  if swapon --show --noheadings | grep -q .; then
    ok "Swap настроен ✓"
  else
    info "Swap не настроен (RAM > ${SWAP_RAM_THRESHOLD_MB}MB)"
  fi

  if command -v ufw >/dev/null 2>&1; then
    if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
      ok "UFW активен ✓"
    else
      warn "UFW НЕ активен"
    fi
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

  # ЗАМЕЧАНИЕ 1: проверяем, что systemd реально использует лимит (не просто наличие файла)
  local default_nofile
  default_nofile=$(systemctl show --property=DefaultLimitNOFILE --value 2>/dev/null || true)
  if [ "$default_nofile" = "1048576" ]; then
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
  ask "Выбор: " choice
  case "$choice" in
    1) bash <(wget -qO- https://ipregion.vrnt.xyz) ;;
    2) bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode geoblock ;;
    3) bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi ;;
    4) bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh) ;;
    5) curl -sL yabs.sh | bash -s -- -4 ;;
    6) bash <(curl -Ls IP.Check.Place) -l en ;;
    7) wget -qO- bench.sh | bash ;;
    8) bash <(curl -Ls https://Check.Place) -EI ;;
    9) sysbench cpu run --threads=1 ;;
    0) return ;;
    *) warn "Неверный выбор" ;;
  esac
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
    3) part3_tests ;;
    0) exit 0 ;;
    *) warn "Неверный выбор" ;;
  esac
  pause || { error "Не удалось прочитать ответ для продолжения"; exit 1; }
done
