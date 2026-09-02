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

ask() { echo -n "$1" > /dev/tty; read -r "$2" < /dev/tty; }
ask_password() {
  local prompt="$1" variable="$2"
  printf '%s' "$prompt" > /dev/tty
  IFS= read -r -s "$variable" < /dev/tty
  printf '\n' > /dev/tty
}
set_pin_password() {
  local password password_confirm
  while true; do
    ask_password "Введите пароль для $PIN_USER: " password
    ask_password "Повторите пароль: " password_confirm
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
USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
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

detect_minimized() {
  dpkg-query -W -f='${db:Status-Status}' ubuntu-standard 2>/dev/null | grep -qx installed && return 1
  [ -f /etc/dpkg/dpkg.cfg.d/excludes ] && grep -q 'path-exclude' /etc/dpkg/dpkg.cfg.d/excludes && return 0
  ! command -v man >/dev/null 2>&1 && ! command -v less >/dev/null 2>&1
}
IS_MINIMIZED=false
detect_minimized && IS_MINIMIZED=true

part1_update() {
  section "ЧАСТЬ 1: ОБНОВЛЕНИЕ И UNMINIMIZE"
  if [ "$IS_MINIMIZED" = true ]; then
    warn "Обнаружена Ubuntu minimized"
    local answer
    ask "Преобразовать в обычную Ubuntu через unminimize? [Y/n]: " answer
    if yes_by_default "$answer"; then
      apt-get update
      if ! command -v unminimize >/dev/null 2>&1; then
        apt-get install -y unminimize
      fi
      set +o pipefail
      yes | unminimize
      unminimize_status="${PIPESTATUS[1]}"
      set -o pipefail
      if [ "$unminimize_status" -eq 0 ] || ! detect_minimized; then
        IS_MINIMIZED=false
        ok "unminimize завершён"
      else
        error "unminimize завершился с кодом $unminimize_status"
        warn "Проверьте: dpkg-query -W ubuntu-standard; cat /etc/dpkg/dpkg.cfg.d/excludes"
        return 1
      fi
    fi
  fi

  apt-get update

  if [ ! -f "$FIRST_UPDATE_MARKER" ]; then
    info "ПЕРВОЕ обновление системы — используем full-upgrade"
    apt-get full-upgrade -y
    mkdir -p "$(dirname "$FIRST_UPDATE_MARKER")" 2>/dev/null
    touch "$FIRST_UPDATE_MARKER"
  else
    info "ПОВТОРНОЕ обновление системы — используем upgrade"
    apt-get upgrade -y
  fi

  apt-get autoremove -y
  ok "Пакеты обновлены"
  local answer
  ask "Перезагрузить сервер сейчас? [Y/n]: " answer
  if yes_by_default "$answer"; then
    warn "Перезагрузка через 5 секунд"
    sleep 5
    reboot
  else
    info "Перезагрузка отложена по вашему выбору"
  fi
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
    apt-get install -y rng-tools5
  else
    info "Аппаратный RNG не обнаружен — rng-tools5 не требуется"
  fi

  for package in eza zoxide; do
    if apt-cache show "$package" >/dev/null 2>&1; then
      apt-get install -y "$package"
    else
      warn "Пакет $package отсутствует в этом репозитории Ubuntu; пропуск"
    fi
  done
  ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
  ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
  return 0
}

configure_locale_time() {
  section "ВРЕМЯ И ЛОКАЛЬ"
  timedatectl set-timezone Asia/Irkutsk
  locale-gen ru_RU.UTF-8 en_US.UTF-8
  update-locale LANG=ru_RU.UTF-8
  ok "Часовой пояс и локаль настроены"
}

configure_unattended_upgrades() {
  section "АВТО-ОБНОВЛЕНИЯ БЕЗОПАСНОСТИ"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

  local timers_ok=true
  for timer in apt-daily.timer apt-daily-upgrade.timer; do
    if ! systemctl is-enabled "$timer" >/dev/null 2>&1; then
      systemctl enable "$timer" 2>/dev/null || timers_ok=false
    fi
  done

  if [ "$timers_ok" = true ]; then
    ok "Авто-обновления безопасности включены"
  else
    warn "Не удалось включить некоторые timer'ы; проверьте: systemctl list-timers"
  fi
}

configure_autoremove() {
  section "АВТООЧИСТКА НЕИСПОЛЬЗУЕМЫХ ПАКЕТОВ"

  # Автоудаление зависимостей ОТКЛЮЧЕНО для безопасности сервера
  cat > /etc/apt/apt.conf.d/50auto-remove <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
EOF
  ok "Автоудаление зависимостей отключено (безопасно для Xray/3x-ui/Docker)"

  local packages
  packages=$(apt-get --dry-run autoremove 2>/dev/null | grep -E "^Remv " | wc -l)
  if [ "$packages" -gt 0 ]; then
    info "Найдено $packages пакетов для удаления:"
    apt-get --dry-run autoremove 2>/dev/null | grep -E "^Remv " | awk '{print "  - " $2}' | head -20
    [ "$packages" -gt 20 ] && info "  ... и ещё $((packages - 20))"
    local answer
    ask "Удалить эти пакеты сейчас? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      apt-get autoremove -y --purge
      ok "Удалено $packages пакетов"
    else
      info "Пропущено. Для ручного удаления: sudo apt autoremove --purge"
    fi
  else
    ok "Нет пакетов для удаления"
  fi
}

configure_needrestart() {
  section "NEEDRESTART (ПЕРЕЗАПУСК СЛУЖБ ПОСЛЕ ОБНОВЛЕНИЙ)"
  info "needrestart установлен в режиме отчёта (без автоперезапуска)"

  local answer
  ask "Включить автоматический перезапуск служб после обновлений? [y/N]: " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    warn "ВНИМАНИЕ: Автоматический перезапуск может прервать активные соединения"
    ask "Вы уверены? Это может остановить SSH, nginx, БД [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      sed -i 's/#\$nrconf{restart} =.*/\$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf 2>/dev/null || true
      ok "Автоматический перезапуск включён"
    else
      info "Оставлен режим отчёта"
    fi
  else
    ok "Оставлен режим отчёта (безопасно)"
  fi
}

configure_safe_sysctl() {
  section "БЕЗОПАСНЫЕ SYSCTL"
  cat > /etc/sysctl.d/99-vps-tuning.conf <<'EOF'
# Совместимо с VPN, policy routing, туннелями и proxy.
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
EOF

  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    ok "BBR доступен в ядре"
  else
    warn "BBR недоступен в этом ядре — удаляем строки BBR/fq из конфига"
    sed -i '/tcp_congestion_control = bbr/d' /etc/sysctl.d/99-vps-tuning.conf
    sed -i '/default_qdisc = fq/d' /etc/sysctl.d/99-vps-tuning.conf
  fi

  if sysctl --system >/dev/null; then
    ok "Безопасные sysctl применены"
  else
    error "Не удалось применить некоторые sysctl"
    return 1
  fi

  cat > /etc/security/limits.d/99-vps.conf <<'EOF'
* soft nofile 524288
* hard nofile 1048576
root soft nofile 524288
root hard nofile 1048576
EOF
  return 0
}

# Глобальный лимит для systemd-сервисов
configure_systemd_limits() {
  section "ЛИМИТЫ ДЛЯ SYSTEMD-СЕРВИСОВ"
  info "limits.d применяется только к интерактивным сессиям (через PAM)."
  info "Для системных сервисов (Xray, 3x-ui, Docker) задаём глобальный лимит."
  mkdir -p /etc/systemd/system.conf.d || { error "Не удалось создать /etc/systemd/system.conf.d"; return 1; }
  cat > /etc/systemd/system.conf.d/99-nofile.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
  if systemctl daemon-reexec; then
    ok "DefaultLimitNOFILE=1048576 применён ко всем сервисам"
  else
    error "Не удалось выполнить systemctl daemon-reexec"
    return 1
  fi
}

configure_swap() {
  section "SWAP"
  if swapon --show --noheadings | grep -q .; then
    info "Swap уже настроен"
    return 0
  fi
  local ram
  ram="$(LC_ALL=C free -m | awk '/^Mem:/ {print $2}')"
  if ! [[ "$ram" =~ ^[0-9]+$ ]]; then
    error "Не удалось определить объём RAM; swap не изменён"
    return 1
  fi
  if [ "$ram" -gt "$SWAP_RAM_THRESHOLD_MB" ]; then
    info "RAM больше $SWAP_RAM_THRESHOLD_MB MB — swap не нужен"
    return 0
  fi
  info "RAM не более $SWAP_RAM_THRESHOLD_MB MB — создаём swap $SWAP_SIZE"

  if [ -f /swapfile ]; then
    warn "Файл /swapfile уже существует, но не используется как swap. Пересоздаём."
  fi
  rm -f /swapfile

  if ! fallocate -l "$SWAP_SIZE" /swapfile; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress || { error "dd завершился с ошибкой"; return 1; }
  fi
  chmod 600 /swapfile
  mkswap /swapfile || { error "mkswap завершился с ошибкой"; return 1; }
  swapon /swapfile || { error "swapon завершился с ошибкой"; return 1; }
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap создан"
  return 0
}

# Безопасное управление ключами pin
configure_pin() {
  section "ПОСТОЯННЫЙ ПОЛЬЗОВАТЕЛЬ $PIN_USER"
  local home sshdir keys action answer method public_key keyfile
  local is_new=false replace_mode=false use_file=false

  if id "$PIN_USER" >/dev/null 2>&1; then
    home="$(getent passwd "$PIN_USER" | cut -d: -f6)"
    sshdir="$home/.ssh"; keys="$sshdir/authorized_keys"
    local key_count
    key_count=$(test -s "$keys" && wc -l < "$keys" || echo 0)
    info "$PIN_USER уже существует; ключей: $key_count"
    [ "$key_count" -gt 0 ] && PIN_HAS_KEY=true

    echo "Enter) Ничего не менять (по умолчанию)"
    echo "1) Сменить пароль"
    echo "2) Добавить публичный ключ"
    echo "3) Заменить все публичные ключи"
    ask "Ваш выбор: " action
    case "$action" in
      "") info "Пользователь $PIN_USER оставлен без изменений"; return 0 ;;
      1) set_pin_password; return 0 ;;
      2|3) [ "$action" = 3 ] && replace_mode=true ;;
      *) warn "Неизвестный выбор — ничего не меняем"; return 0 ;;
    esac
  else
    ask "Создать $PIN_USER и добавить в группу sudo? [Y/n]: " answer
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

    home="$(getent passwd "$PIN_USER" | cut -d: -f6)"
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
    ask "Способ добавления ключа [1/2/3]: " method
    case "$method" in
      1) use_file=false ;;
      2) use_file=true ;;
      *) info "Ключ не изменён"; return 0 ;;
    esac
  fi

  if [ "$use_file" = true ]; then
    ask "Путь к файлу публичного ключа: " keyfile
    # ЗАМЕЧАНИЕ 2: файл не найден — это ОШИБКА, а не успех
    if [ ! -f "$keyfile" ]; then
      error "Файл не найден: $keyfile"
      return 1
    fi
    public_key=$(cat "$keyfile")
  else
    info "Вставьте публичный SSH-ключ одной строкой:"
    read -r public_key < /dev/tty
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

  # Валидация формата ключа
  case "$public_key" in
    ssh-ed25519*|ssh-rsa*|ecdsa-sha2-*|ssh-dss*|sk-ssh-ed25519*|sk-ecdsa-sha2-*)
      ;;
    *)
      warn "Строка не похожа на публичный SSH-ключ. Ключ не добавлен."
      return 0
      ;;
  esac

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
    if ! { cat "$keys" 2>/dev/null; printf '%s\n' "$public_key"; } > "$tmp_keys"; then
      rm -f "$tmp_keys"
      error "Не удалось записать ключ во временный файл"
      return 1
    fi
  fi
  chmod 600 "$tmp_keys"

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
  chmod 700 "$sshdir"; chmod 600 "$keys"

  PIN_HAS_KEY=true
  ok "Ключ для $PIN_USER установлен"
  return 0
}

configure_ufw() {
  section "UFW"
  local answer action source_ip
  if ! LC_ALL=C ufw status 2>/dev/null | grep -q 'Status: active'; then
    ask "Настроить и активировать UFW? [Y/n]: " answer
    if yes_by_default "$answer"; then
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow "$SSH_PORT/tcp" comment 'SSH'
      ufw allow 80/tcp comment 'HTTP'
      ufw allow 443/tcp comment 'HTTPS'
      ufw --force enable
      ok "UFW включён: SSH $SSH_PORT, HTTP/HTTPS"
    fi
  fi
  echo "iPerf3: Enter) не менять; 1) открыть всем; 2) открыть одному IP; 3) закрыть общие правила"
  ask "Правило для порта 5201: " action
  case "$action" in
    1) ufw allow 5201/tcp comment 'temporary iperf3'; ufw allow 5201/udp comment 'temporary iperf3'; warn "Закройте 5201 после теста: выберите пункт 3" ;;
    2)
      ask "IPv4 или IPv6-адрес клиента: " source_ip
      if [[ "$source_ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        ufw allow from "$source_ip" to any port 5201 proto tcp
        ufw allow from "$source_ip" to any port 5201 proto udp
        ok "iPerf3 разрешён только для $source_ip"
      else
        error "Некорректный IP"; fi ;;
    3) ufw --force delete allow 5201/tcp 2>/dev/null || true; ufw --force delete allow 5201/udp 2>/dev/null || true; ok "Общие правила 5201 удалены" ;;
    *) info "Правила iPerf3 не изменены" ;;
  esac
}

set_sshd_line() {
  local name="$1" value="$2"
  if grep -qE "^#?$name[[:space:]]+" /etc/ssh/sshd_config; then
    sed -Ei "s|^#?$name[[:space:]]+.*|$name $value|" /etc/ssh/sshd_config
  else
    echo "$name $value" >> /etc/ssh/sshd_config
  fi
}

configure_ssh() {
  section "SSH: ПОРТ, КЛЮЧИ И SOCKET ACTIVATION"
  local answer

  # Определяем состояние ключа непосредственно перед отключением паролей
  local keys_file="/home/$PIN_USER/.ssh/authorized_keys"
  if [ -f "$keys_file" ] && [ -s "$keys_file" ]; then
    PIN_HAS_KEY=true
  else
    PIN_HAS_KEY=false
  fi

  if [ "$PIN_HAS_KEY" != "true" ]; then
    error "У $PIN_USER НЕТ SSH-ключа."
    error "Нельзя отключать пароли без ключа — вы потеряете доступ."
    error "Добавьте ключ и перезапустите настройку."
    return 1
  fi
  ok "SSH-ключ для $PIN_USER найден — можно безопасно отключать пароли"

  echo "Будет включён порт $SSH_PORT, а парольный вход — отключён."
  echo "Вход под root будет ПОЛНОСТЬЮ запрещён (PermitRootLogin no)."
  echo "Сессия разрывается после 180с неактивности (60с × 3)."
  warn "Не закрывайте текущую сессию до успешной проверки нового входа."
  ask "Применить настройки SSH? [Y/n]: " answer
  yes_by_default "$answer" || return

  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

  set_sshd_line Port "$SSH_PORT"

  mkdir -p /etc/ssh/sshd_config.d

  cat > /etc/ssh/sshd_config.d/00-vps-hardening.conf <<'EOF'
# VPS hardening settings (создано tunevps.sh)
# Этот файл загружается ПЕРВЫМ (номер 00), чтобы переопределить
# настройки из 50-cloud-init.conf и других файлов

# Аутентификация
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

  # Конфликтующие параметры из чужих файлов НЕ удаляем.
  # Приоритет обеспечивается файлом 00-*. + итоговая проверка через `sshd -T`.

  if ! sshd -t; then
    error "Ошибка sshd_config. Конфиг не перезапущен."
    return 1
  fi

  if ! sshd -T | awk -v port="$SSH_PORT" '$1 == "port" && $2 == port {found=1} END {exit !found}'; then
    error "sshd не принял порт $SSH_PORT; проверьте /etc/ssh/sshd_config и *.d"
    return 1
  fi

  mkdir -p /etc/systemd/system/ssh.socket.d
  cat > /etc/systemd/system/ssh.socket.d/99-vps-port.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:$SSH_PORT
ListenStream=[::]:$SSH_PORT
EOF

  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    systemctl daemon-reload
    systemctl restart ssh.socket
  else
    systemctl reload ssh.service || systemctl restart ssh.service
  fi
  sleep 2

  # Надёжная проверка порта через awk
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

  info "Итоговая конфигурация SSH (sshd -T):"
  echo ""
  sshd -T 2>/dev/null | grep -E "^(port|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|permituserenvironment|usepam|tcpkeepalive|clientaliveinterval|clientalivecountmax|maxauthtries|loglevel) " | sort
  echo ""

  local pass_auth pubkey_auth root_login
  pass_auth=$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}')
  pubkey_auth=$(sshd -T 2>/dev/null | awk '$1 == "pubkeyauthentication" {print $2}')
  root_login=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2}')

  if [ "$pass_auth" = "no" ]; then
    ok "PasswordAuthentication=no применён ✓"
  else
    error "PasswordAuthentication=$pass_auth (должно быть 'no')!"
    return 1
  fi

  if [ "$pubkey_auth" = "yes" ]; then
    ok "PubkeyAuthentication=yes применён ✓"
  else
    warn "PubkeyAuthentication=$pubkey_auth"
  fi

  if [ "$root_login" = "no" ]; then
    ok "PermitRootLogin=no применён ✓"
  else
    warn "PermitRootLogin=$root_login (должно быть 'no')"
  fi

  return 0
}

as_current_user() {
  sudo -H -u "$CURRENT_USER" env HOME="$USER_HOME" "$@"
}

configure_shell() {
  section "ZSH, OH MY ZSH И POWERLEVEL10K"
  chsh -s "$(command -v zsh)" "$CURRENT_USER"
  if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
    as_current_user git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$USER_HOME/.oh-my-zsh"
  fi
  local custom="$USER_HOME/.oh-my-zsh/custom"
  if [ ! -d "$custom/themes/powerlevel10k" ]; then
    as_current_user git clone --depth=1 --recurse-submodules "$P10K_REPOSITORY" "$custom/themes/powerlevel10k"
  fi
  for spec in \
    "zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git" \
    "zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git" \
    "zsh-completions https://github.com/zsh-users/zsh-completions.git"; do
    set -- $spec
    [ -d "$custom/plugins/$1" ] || as_current_user git clone --depth=1 "$2" "$custom/plugins/$1"
  done

  cat > "$USER_HOME/.zshrc" <<'EOF'
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
alias myip='curl -s ifconfig.me'
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
  chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc"
  chmod 644 "$USER_HOME/.zshrc"
  ok "Zsh и P10K настроены для $CURRENT_USER"
  info "После нового SSH-входа под $CURRENT_USER мастер P10K стартует автоматически."
}

final_check() {
  section "ФИНАЛЬНАЯ ПРОВЕРКА"

  if check_ssh_port; then
    ok "SSH слушает порт $SSH_PORT ✓"
  else
    error "SSH НЕ слушает порт $SSH_PORT! ⚠️"
  fi

  if systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket; then
    ok "SSH активен (service или socket) ✓"
  else
    error "SSH НЕ активен! ⚠️"
  fi

  if sshd -t 2>/dev/null; then
    ok "Синтаксис sshd_config корректен ✓"
  else
    error "Ошибка синтаксиса sshd_config! ⚠️"
  fi

  local pass_auth pubkey_auth root_login
  pass_auth=$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}')
  pubkey_auth=$(sshd -T 2>/dev/null | awk '$1 == "pubkeyauthentication" {print $2}')
  root_login=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2}')

  if [ "$pass_auth" = "no" ]; then
    ok "PasswordAuthentication=no ✓"
  else
    error "PasswordAuthentication=$pass_auth (должно быть 'no')!"
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
}

part2_setup() {
  section "ЧАСТЬ 2: ОКРУЖЕНИЕ"

  # КРИТИЧНЫЕ ЭТАПЫ с контролем ошибок
  if ! install_packages; then
    error "Не удалось установить базовые пакеты — останавливаюсь"
    return 1
  fi

  configure_locale_time

  configure_unattended_upgrades

  # Менее критичные этапы (без остановки при ошибке)
  configure_autoremove
  configure_needrestart

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

  # Сначала настраиваем SSH, затем файрвол,
  # чтобы не открыть порт в файрволе до реального переключения
  if ! configure_ssh; then
    error "Настройка SSH завершилась ошибкой — останавливаюсь"
    error "Доступ по текущей сессии сохранён, проверьте логи выше"
    return 1
  fi

  configure_ufw
  configure_shell
  final_check
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
  ask "Выберите действие [0-3]: " choice
  case "$choice" in
    1) part1_update ;;
    2) part2_setup ;;
    3) part3_tests ;;
    0) exit 0 ;;
    *) warn "Неверный выбор" ;;
  esac
  pause
done
