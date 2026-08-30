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
  if ! ufw status | grep -q 'Status: active'; then
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
  echo "Будет включён порт $SSH_PORT, а парольный вход — отключён."
  echo "root разрешён только по ключу; ClientAliveInterval=0 отключает server-side idle timeout."
  warn "Не закрывайте текущую сессию до успешной проверки нового входа."
  ask "Применить настройки SSH? [Y/n]: " answer
  yes_by_default "$answer" || return

  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
  set_sshd_line Port "$SSH_PORT"
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-vps-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
LogLevel VERBOSE
PermitUserEnvironment no
ClientAliveInterval 0
TCPKeepAlive yes
EOF
  if ! sshd -t; then
    error "Ошибка sshd_config. Конфиг не перезапущен."
    return 1
  fi
  if ! sshd -T | awk '$1 == "port" && $2 == 5829 {found=1} END {exit !found}'; then
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
  if ss -ltn | grep -qE "[:.]$SSH_PORT[[:space:]]"; then
    ok "SSH слушает $SSH_PORT"
  else
    error "Порт $SSH_PORT не слушается; текущую сессию не закрывайте"
    systemctl status ssh.socket ssh.service --no-pager || true
  fi
  if ss -ltn | grep -qE "[:.]22[[:space:]]"; then
    warn "Порт 22 всё ещё слушается; покажите: systemctl cat ssh.socket"
  fi
  sshd -T | grep -E '^(port|passwordauthentication|permitrootlogin|clientaliveinterval) '
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
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
if [[ -r "$HOME/.cache/p10k-instant-prompt-$USER.zsh" ]]; then
  source "$HOME/.cache/p10k-instant-prompt-$USER.zsh"
fi
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-completions sudo extract)
source "$ZSH/oh-my-zsh.sh"

# Первый интерактивный вход запускает мастер P10K, если конфигурации ещё нет.
if [[ -o interactive && ! -r "$HOME/.p10k.zsh" ]] && (( $+functions[p10k] )); then
  p10k configure
fi

alias cat='bat --paging=never'
alias ls='eza --icons'
alias ll='eza -la --icons --git'
alias grep='rg'
alias fd='fd'
alias ports='ss -tulnp'
alias reload='source ~/.zshrc'
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi
[[ ! -r "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"
EOF
  chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc"
  chmod 644 "$USER_HOME/.zshrc"
  ok "Zsh и P10K настроены для $CURRENT_USER"
  info "После нового SSH-входа под $CURRENT_USER мастер P10K стартует автоматически."
}

part2_setup() {
  section "ЧАСТЬ 2: ОКРУЖЕНИЕ"
  configure_locale_time
  install_packages
  configure_safe_sysctl
  configure_swap
  configure_pin
  configure_ufw
  configure_ssh
  configure_shell
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
