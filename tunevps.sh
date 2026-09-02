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

if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

# Это именно пользователь, который вызвал sudo, а не root.
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
  # ubuntu-minimized origin может оставаться после unminimize, поэтому
  # он не является достаточным признаком. Главный критерий — ubuntu-standard.
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
      # При pipefail команда yes получает SIGPIPE, когда unminimize закончил чтение.
      # Поэтому берём код именно unminimize, а затем проверяем реальное состояние.
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
  apt-get upgrade -y
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
  apt-get update
  apt-get install -y nano git curl wget unzip jq htop tmux net-tools dnsutils \
    bat fd-find ripgrep fzf python3 python3-pip python3-venv build-essential \
    btop mtr-tiny iperf3 zsh sysbench ca-certificates gnupg \
    ncdu iotop ufw unattended-upgrades needrestart locales
  
  # rng-tools5 только при наличии аппаратного RNG
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
  
  # Проверка и включение timer'ов
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

  # Настраиваем автоматическую очистку при unattended-upgrades
  cat > /etc/apt/apt.conf.d/50auto-remove <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF

  # Проверяем текущее состояние
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

  ok "Автоочистка настроена (будет работать при unattended-upgrades)"
}

configure_needrestart() {
  section "NEEDRESTART (ПЕРЕЗАПУСК СЛУЖБ ПОСЛЕ ОБНОВЛЕНИЙ)"
  info "needrestart установлен в режиме отчёта (без автоперезапуска)"
  info "Это безопасно: службы не будут перезапускаться автоматически"
  info "Для включения автоматического режима выполните:"
  info "  sudo sed -i 's/#\\\$nrconf{restart} =.*/\\\$nrconf{restart} = \"a\";/' /etc/needrestart/needrestart.conf"
  
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
# rp_filter, tcp_fastopen и агрессивные TCP-переменные намеренно не задаются.
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
  if sysctl --system >/dev/null; then
    ok "Безопасные sysctl применены"
  else
    warn "Некоторые sysctl не применились; проверьте: sysctl --system"
  fi
  cat > /etc/security/limits.d/99-vps.conf <<'EOF'
* soft nofile 524288
* hard nofile 1048576
root soft nofile 524288
root hard nofile 1048576
EOF
}

configure_swap() {
  section "SWAP"
  if swapon --show --noheadings | grep -q .; then
    info "Swap уже настроен"
    return
  fi
  local ram
  ram="$(LC_ALL=C free -m | awk '/^Mem:/ {print $2}')"
  if ! [[ "$ram" =~ ^[0-9]+$ ]]; then
    error "Не удалось определить объём RAM; swap не изменён"
    return 1
  fi
  if [ "$ram" -gt "$SWAP_RAM_THRESHOLD_MB" ]; then
    info "RAM больше $SWAP_RAM_THRESHOLD_MB MB — swap не нужен"
    return
  fi
  info "RAM не более $SWAP_RAM_THRESHOLD_MB MB — создаём swap $SWAP_SIZE"
  rm -f /swapfile
  if ! fallocate -l "$SWAP_SIZE" /swapfile; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap создан"
}

configure_pin() {
  section "ПОСТОЯННЫЙ ПОЛЬЗОВАТЕЛЬ $PIN_USER"
  local home sshdir keys action answer method public_key keyfile is_new=false
  if id "$PIN_USER" >/dev/null 2>&1; then
    home="$(getent passwd "$PIN_USER" | cut -d: -f6)"
    sshdir="$home/.ssh"; keys="$sshdir/authorized_keys"
    info "$PIN_USER уже существует; ключей: $(test -s "$keys" && wc -l < "$keys" || echo 0)"
    echo "Enter) Ничего не менять (по умолчанию)"
    echo "1) Сменить пароль"
    echo "2) Добавить публичный ключ"
    echo "3) Заменить все публичные ключи"
    ask "Ваш выбор: " action
    case "$action" in
      "") info "Пользователь $PIN_USER оставлен без изменений"; return ;;
      1) set_pin_password; return ;;
      2|3) ;;
      *) warn "Неизвестный выбор — ничего не меняем"; return ;;
    esac
    [ "$action" = 3 ] && rm -f "$keys"
  else
    ask "Создать $PIN_USER и добавить в группу sudo? [Y/n]: " answer
    if ! yes_by_default "$answer"; then
      warn "Создание $PIN_USER пропущено"
      return
    fi
    adduser --disabled-password --gecos "" "$PIN_USER"
    usermod -aG sudo "$PIN_USER"
    home="$(getent passwd "$PIN_USER" | cut -d: -f6)"
    sshdir="$home/.ssh"; keys="$sshdir/authorized_keys"; is_new=true
    ok "Пользователь $PIN_USER создан"
    info "Задайте пароль $PIN_USER (ввод и подтверждение не отображаются):"
    set_pin_password
  fi

  if [ "$is_new" = true ]; then
    info "Вставьте публичный SSH-ключ для $PIN_USER одной строкой (Enter — пропустить):"
    read -r public_key < /dev/tty
    if [ -z "$public_key" ]; then
      warn "Ключ не добавлен. До отключения паролей добавьте его вручную."
      return
    fi
    mkdir -p "$sshdir"; printf '%s\n' "$public_key" > "$keys"
  else
    echo "1) Вставить публичный ключ"
    echo "2) Скопировать ключ из файла на сервере"
    echo "3) Пропустить"
    ask "Способ добавления ключа [1/2/3]: " method
    case "$method" in
      1)
        info "Вставьте один публичный ключ:"
        read -r public_key < /dev/tty
        [ -n "$public_key" ] || { warn "Пустой ключ — пропуск"; return; }
        mkdir -p "$sshdir"; printf '%s\n' "$public_key" >> "$keys" ;;
      2)
        ask "Путь к файлу публичного ключа: " keyfile
        [ -f "$keyfile" ] || { error "Файл не найден"; return 1; }
        mkdir -p "$sshdir"; cat "$keyfile" >> "$keys" ;;
      *) info "Ключ не изменён"; return ;;
    esac
  fi
  chown -R "$PIN_USER:$PIN_USER" "$sshdir"
  chmod 700 "$sshdir"; chmod 600 "$keys"
  ok "Ключ для $PIN_USER установлен"
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

# ============================================
# НАСТРОЙКА SSH — ИСПРАВЛЕННАЯ ВЕРСИЯ
# ============================================
# КРИТИЧЕСКИ ВАЖНО:
# 1. В Ubuntu 24.04 cloud-init создаёт /etc/ssh/sshd_config.d/50-cloud-init.conf
#    с PasswordAuthentication yes. В OpenSSH при Include используется ПЕРВОЕ
#    встреченное значение, поэтому наш 99-файл игнорируется!
# 2. Решение: создаём 00-vps-hardening.conf (загружается первым)
# 3. Дополнительно удаляем конфликтующие параметры из других файлов в sshd_config.d
configure_ssh() {
  section "SSH: ПОРТ, КЛЮЧИ И SOCKET ACTIVATION"
  local answer
  echo "Будет включён порт $SSH_PORT, а парольный вход — отключён."
  echo "root разрешён только по ключу."
  echo "Сессия разрывается после 180с неактивности (60с × 3)."
  warn "Не закрывайте текущую сессию до успешной проверки нового входа."
  ask "Применить настройки SSH? [Y/n]: " answer
  yes_by_default "$answer" || return

  # Резервная копия главного конфига
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

  # Устанавливаем порт в основном конфиге
  set_sshd_line Port "$SSH_PORT"
  mkdir -p /etc/ssh/sshd_config.d

  # ============================================
  # КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: файл с номером 00
  # Загружается ПЕРВЫМ, поэтому его значения имеют приоритет
  # ============================================
  cat > /etc/ssh/sshd_config.d/00-vps-hardening.conf <<'EOF'
# VPS hardening settings (создано tunevps.sh)
# Этот файл загружается ПЕРВЫМ (номер 00), чтобы переопределить
# настройки из 50-cloud-init.conf и других файлов

# Аутентификация
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no

# Защита от brute-force
MaxAuthTries 3

# Безопасность окружения
PermitUserEnvironment no

# PAM (обязательно включить при отключённых паролях)
UsePAM yes

# Keepalive: клиент отключается через 60*3 = 180 секунд неактивности
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3

LogLevel VERBOSE
EOF

  # ============================================
  # УДАЛЕНИЕ КОНФЛИКТУЮЩИХ ПАРАМЕТРОВ из других файлов
  # Например, 50-cloud-init.conf часто содержит "PasswordAuthentication yes"
  # ============================================
  local conflicting_params="PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|KbdInteractiveAuthentication|PermitEmptyPasswords|MaxAuthTries|PermitUserEnvironment|UsePAM|TCPKeepAlive|ClientAliveInterval|ClientAliveCountMax|Port"

  for conf in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$conf" ] || continue
    # Пропускаем наш файл
    [ "$(basename "$conf")" = "00-vps-hardening.conf" ] && continue

    # Проверяем, есть ли конфликтующие параметры
    if grep -qEi "^($conflicting_params)[[:space:]]" "$conf" 2>/dev/null; then
      info "Удаляем конфликтующие параметры из: $(basename "$conf")"
      cp "$conf" "$conf.backup.$(date +%Y%m%d_%H%M%S)"
      sed -i -E "/^($conflicting_params)[[:space:]]/Id" "$conf"
    fi
  done

  # Проверка синтаксиса
  if ! sshd -t; then
    error "Ошибка sshd_config. Конфиг не перезапущен."
    return 1
  fi
  if ! sshd -T | awk -v port="$SSH_PORT" '$1 == "port" && $2 == port {found=1} END {exit !found}'; then
    error "sshd не принял порт $SSH_PORT; проверьте /etc/ssh/sshd_config и *.d"
    return 1
  fi

  # Явный override сохраняет socket activation, но очищает ListenStream :22
  # и задаёт только 5829. Работает на Ubuntu 24.04 и на системах без генератора.
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

  # Проверка порта
  if ss -ltn | grep -qE "[:.]$SSH_PORT[[:space:]]"; then
    ok "SSH слушает $SSH_PORT"
  else
    error "Порт $SSH_PORT не слушается; текущую сессию не закрывайте"
    systemctl status ssh.socket ssh.service --no-pager || true
  fi
  if ss -ltn | grep -qE "[:.]22[[:space:]]"; then
    warn "Порт 22 всё ещё слушается; покажите: systemctl cat ssh.socket"
  fi

  # ============================================
  # ПРОВЕРКА ИТОГОВОЙ КОНФИГУРАЦИИ через sshd -T
  # Это единственный надёжный способ увидеть, что реально применено
  # ============================================
  info "Итоговая конфигурация SSH (sshd -T):"
  echo ""
  sshd -T 2>/dev/null | grep -E "^(port|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|permituserenvironment|usepam|tcpkeepalive|clientaliveinterval|clientalivecountmax|maxauthtries) " | sort

  echo ""

  # Проверка критичных параметров
  local pass_auth pubkey_auth root_login
  pass_auth=$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}')
  pubkey_auth=$(sshd -T 2>/dev/null | awk '$1 == "pubkeyauthentication" {print $2}')
  root_login=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2}')

  if [ "$pass_auth" = "no" ]; then
    ok "PasswordAuthentication=no применён ✓"
  else
    error "PasswordAuthentication=$pass_auth (должно быть 'no')!"
    error "Проверьте файлы: grep -rEi '^PasswordAuthentication' /etc/ssh/"
  fi

  if [ "$pubkey_auth" = "yes" ]; then
    ok "PubkeyAuthentication=yes применён ✓"
  else
    warn "PubkeyAuthentication=$pubkey_auth"
  fi

  if [ "$root_login" = "prohibit-password" ] || [ "$root_login" = "without-password" ]; then
    ok "PermitRootLogin=$root_login применён ✓ (только по ключу)"
  else
    warn "PermitRootLogin=$root_login"
  fi
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
if (( $+commands[bat] )); then
  alias cat='bat --paging=never'
fi
if (( $+commands[eza] )); then
  alias ls='eza --icons'
  alias ll='eza -la --icons --git'
  alias lt='eza --tree --icons --level=2'
fi
if (( $+commands[rg] )); then
  alias grep='rg'
fi
if (( $+commands[fd] )); then
  alias fd='fd'
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

# === FZF ===
# Ctrl+R: история команд; Ctrl+T: поиск файлов; Alt+C: переход в каталог.
setup_fzf() {
  (( $+commands[fzf] )) || return 0

  # В новых версиях fzf эта команда сразу задаёт Ctrl+R, Ctrl+T и Alt+C.
  if fzf --zsh >/dev/null 2>&1; then
    eval "$(fzf --zsh)"
    return 0
  fi

  # Совместимость с пакетами fzf из Ubuntu 24.04/26.04.
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

# Zoxide добавляет команду z; обычный cd не переопределяется.
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
  
  # SSH порт (проверяем и socket, и service)
  if ss -ltn | grep -qE "[:.]$SSH_PORT[[:space:]]"; then
    ok "SSH слушает порт $SSH_PORT ✓"
  else
    error "SSH НЕ слушает порт $SSH_PORT! ⚠️"
  fi
  
  # SSH активен (service или socket)
  if systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket; then
    ok "SSH активен (service или socket) ✓"
  else
    error "SSH НЕ активен! ⚠️"
  fi
  
  # Проверка синтаксиса sshd_config
  if sshd -t 2>/dev/null; then
    ok "Синтаксис sshd_config корректен ✓"
  else
    error "Ошибка синтаксиса sshd_config! ⚠️"
  fi

  # КРИТИЧНЫЕ параметры SSH через sshd -T (итоговая конфигурация)
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

  if [ "$root_login" = "prohibit-password" ] || [ "$root_login" = "without-password" ]; then
    ok "PermitRootLogin=$root_login ✓ (только по ключу)"
  else
    warn "PermitRootLogin=$root_login"
  fi

  # BBR
  local bbr
  bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
  if [ "$bbr" = "bbr" ]; then
    ok "BBR включён ✓"
  else
    warn "BBR не включён (текущий: $bbr)"
  fi
  
  # Swap
  if swapon --show --noheadings | grep -q .; then
    ok "Swap настроен ✓"
  else
    info "Swap не настроен (RAM > ${SWAP_RAM_THRESHOLD_MB}MB)"
  fi
  
  # UFW
  if command -v ufw >/dev/null 2>&1; then
    if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
      ok "UFW активен ✓"
    else
      warn "UFW НЕ активен"
    fi
  else
    warn "UFW не установлен"
  fi
  
  # Zoxide
  if command -v zoxide >/dev/null 2>&1; then
    ok "zoxide установлен ✓"
  else
    warn "zoxide НЕ установлен — алиас z будет работать как cd"
  fi
  
  # Powerlevel10k (проверяем каталог темы)
  if [ -d "$USER_HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]; then
    ok "Powerlevel10k установлен ✓"
  else
    warn "Powerlevel10k не найден"
  fi
  
  # .zshrc
  if [ -f "$USER_HOME/.zshrc" ]; then
    ok ".zshrc создан для $CURRENT_USER ✓"
  else
    error ".zshrc НЕ найден! ⚠️"
  fi
  
  # Minimized
  if [ "$IS_MINIMIZED" = true ]; then
    warn "⚠️  Система осталась в minimized состоянии"
  fi
}

part2_setup() {
  section "ЧАСТЬ 2: ОКРУЖЕНИЕ"
  install_packages
  configure_locale_time
  configure_unattended_upgrades
  configure_autoremove
  configure_needrestart
  configure_safe_sysctl
  configure_swap
  configure_pin
  configure_ufw
  configure_ssh
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
