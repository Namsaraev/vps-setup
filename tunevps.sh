#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# ============================================
# НАСТРОЙКИ (меняйте здесь)
# ============================================
SSH_PORT=5829
NEW_USER="pin"
SWAP_RAM_THRESHOLD_MB=2048
SWAP_SIZE="2G"

# ============================================
# ЦВЕТА И УТИЛИТЫ
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

ask_input() {
    local prompt="$1"
    local var_name="$2"
    echo -n "$prompt" > /dev/tty
    read -r "$var_name" < /dev/tty
}

ask_password() {
    local prompt="$1"
    local var_name="$2"
    read -s -p "$prompt" "$var_name" < /dev/tty
    echo "" > /dev/tty
}

pause() {
    local prompt="${1:-Нажмите Enter для продолжения...}"
    echo -n "$prompt" > /dev/tty
    read -r < /dev/tty
}

# ============================================
# АВТО-ПОВЫШЕНИЕ ДО ROOT
# ============================================
if [ "$EUID" -ne 0 ]; then
    print_info "Требуются права root. Перезапускаем через sudo..."
    exec sudo bash "$0" "$@"
fi

# ============================================
# ОПРЕДЕЛЕНИЕ ОС
# ============================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    UBUNTU_VERSION="$VERSION_ID"
    UBUNTU_CODENAME="$VERSION_CODENAME"
else
    print_error "Не удалось определить ОС"
    exit 1
fi

# ============================================
# УЛУЧШЕННОЕ ОПРЕДЕЛЕНИЕ MINIMIZED (4 признака)
# ============================================
detect_minimized() {
    if [ -f /etc/dpkg/dpkg.cfg.d/excludes ]; then
        if grep -qE "path-exclude" /etc/dpkg/dpkg.cfg.d/excludes 2>/dev/null; then
            return 0
        fi
    fi
    if [ -f /etc/dpkg/origins/ubuntu-minimized ]; then
        return 0
    fi
    if ! command -v man >/dev/null 2>&1 && ! command -v less >/dev/null 2>&1; then
        return 0
    fi
    if command -v dpkg-query >/dev/null 2>&1; then
        if dpkg-query -W -f='${Status}' ubuntu-minimal 2>/dev/null | grep -q "install ok installed"; then
            if ! dpkg-query -W -f='${Status}' ubuntu-standard 2>/dev/null | grep -q "install ok installed"; then
                return 0
            fi
        fi
    fi
    return 1
}

IS_MINIMIZED=false
detect_minimized && IS_MINIMIZED=true

ARCH=$(uname -m)
print_info "ОС: $PRETTY_NAME"
print_info "Версия: $UBUNTU_VERSION ($UBUNTU_CODENAME)"
print_info "Архитектура: $ARCH"

if [ "$IS_MINIMIZED" = true ]; then
    print_warning "Вариант: MINIMIZED ⚠️"
    [ -f /etc/dpkg/dpkg.cfg.d/excludes ] && print_info "  ├─ Найден /etc/dpkg/dpkg.cfg.d/excludes"
    [ -f /etc/dpkg/origins/ubuntu-minimized ] && print_info "  ├─ Найден маркер минимизации"
    ! command -v man >/dev/null 2>&1 && print_info "  ├─ Отсутствует команда man"
    ! command -v less >/dev/null 2>&1 && print_info "  └─ Отсутствует команда less"
else
    print_success "Вариант: Standard (полная система) ✓"
fi

# ============================================
# ВАЖНО: ЯВНЫЙ ВЫБОР ПОЛЬЗОВАТЕЛЯ
# ============================================
print_section "ОПРЕДЕЛЕНИЕ ПОЛЬЗОВАТЕЛЯ"

VALID_USERS=()
while IFS=: read -r username _ uid _ _ homedir shell; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ] && [ -d "$homedir" ]; then
        VALID_USERS+=("$username")
    fi
done < /etc/passwd

echo "Какого пользователя настроить как основного рабочего?"
echo "  1) root (системный администратор)"

USER_IDX=2
declare -A USER_MAP
USER_MAP[1]="root"
for u in "${VALID_USERS[@]}"; do
    echo "  $USER_IDX) $u"
    USER_MAP[$USER_IDX]="$u"
    USER_IDX=$((USER_IDX + 1))
done
echo "  $USER_IDX) Другой пользователь (ввести вручную)"
echo "  0) Пропустить (настроить только систему)"
echo ""

ask_input "Ваш выбор: " USER_CHOICE

if [ "$USER_CHOICE" = "0" ]; then
    CURRENT_USER=""
    USER_HOME=""
    print_warning "Пропускаем настройку пользователя"
elif [ "$USER_CHOICE" = "$USER_IDX" ]; then
    ask_input "Введите имя пользователя: " CURRENT_USER
    if [ "$CURRENT_USER" = "root" ]; then
        USER_HOME="/root"
    else
        USER_HOME="/home/$CURRENT_USER"
    fi
    if [ "$CURRENT_USER" != "root" ] && ! id -u "$CURRENT_USER" &>/dev/null; then
        print_warning "Пользователь $CURRENT_USER не существует"
    fi
elif [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] && [ -n "${USER_MAP[$USER_CHOICE]}" ]; then
    CURRENT_USER="${USER_MAP[$USER_CHOICE]}"
    if [ "$CURRENT_USER" = "root" ]; then
        USER_HOME="/root"
    else
        USER_HOME="/home/$CURRENT_USER"
    fi
else
    print_error "Неверный выбор, используем root"
    CURRENT_USER="root"
    USER_HOME="/root"
fi

if [ -n "$CURRENT_USER" ]; then
    print_info "Настройка будет выполнена для: $CURRENT_USER"
    print_info "Домашняя директория: $USER_HOME"
fi

# ============================================
# ГЛАВНОЕ МЕНЮ
# ============================================
show_menu() {
    clear
    echo -e "${MAGENTA}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║           🚀 VPS SETUP - Меню действий 🚀            ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  1) Первое обновление системы                         ║
║     └─ unminimize (если нужно) + apt update/upgrade  ║
║                                                      ║
║  2) Настройка рабочего пространства                  ║
║     └─ Утилиты, Zsh, SSH, UFW                        ║
║                                                      ║
║  3) Тесты и диагностика                              ║
║     └─ iPerf, YABS, Speedtest, IP-check              ║
║                                                      ║
║  4) Полный цикл (1 → reboot → 2)                     ║
║                                                      ║
║  0) Выход                                            ║
║                                                      ║
╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    [ "$IS_MINIMIZED" = true ] && print_warning "⚠️  MINIMIZED СИСТЕМА — начните с пункта 1!"
}

# ============================================
# ЧАСТЬ 1: ПЕРВОЕ ОБНОВЛЕНИЕ + UNMINIMIZE
# ============================================
part1_update() {
    print_section "ЧАСТЬ 1: ПЕРВОЕ ОБНОВЛЕНИЕ СИСТЕМЫ"

    if [ "$IS_MINIMIZED" = true ]; then
        print_warning "⚠️  ОБНАРУЖЕНА MINIMIZED ВЕРСИЯ UBUNTU!"
        print_info "Рекомендуется восстановить полную версию Ubuntu (2-5 минут)"
        ask_input "Выполнить unminimize? [Y/n]: " DO_UNMINIMIZE

        if [[ ! "$DO_UNMINIMIZE" =~ ^[Nn]$ ]]; then
            apt-get update -y
            command -v unminimize >/dev/null 2>&1 || apt-get install -y unminimize
            set +e
            yes | unminimize 2>&1 | tee /tmp/unminimize.log
            [ ${PIPESTATUS[1]} -eq 0 ] && { print_success "Система восстановлена ✓"; IS_MINIMIZED=false; }
            set -e
        fi
    else
        print_success "Система уже полная Ubuntu ✓"
    fi

    apt-get update -y
    apt-get upgrade -y
    apt-get autoremove -y
    print_success "Система обновлена!"

    ask_input "Перезагрузить сервер? [Y/n]: " REBOOT_NOW
    [[ "$REBOOT_NOW" =~ ^[Nn]$ ]] || { sleep 3; reboot; }
}

# ============================================
# ЧАСТЬ 2: НАСТРОЙКА РАБОЧЕГО ПРОСТРАНСТВА
# ============================================
part2_setup() {
    print_section "ЧАСТЬ 2: НАСТРОЙКА РАБОЧЕГО ПРОСТРАНСТВА"

    if [ -z "$CURRENT_USER" ]; then
        print_error "Пользователь не выбран"
        return 1
    fi

    if [ "$IS_MINIMIZED" = true ]; then
        print_error "⚠️  MINIMIZED система! Рекомендуется сначала пункт 1"
        ask_input "Продолжить? [y/N]: " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || return 1
    fi

    # 2.1 Часовой пояс
    print_section "2.1 ЧАСОВОЙ ПОЯС"
    timedatectl set-timezone Asia/Irkutsk
    print_success "Часовой пояс: $(LC_ALL=C timedatectl | grep 'Time zone')"

    # 2.2 Локаль
    print_section "2.2 ЛОКАЛЬ"
    apt-get install -y language-pack-ru locales 2>/dev/null || apt-get install -y locales
    locale-gen ru_RU.UTF-8
    locale-gen en_US.UTF-8
    sed -i '/^LC_ALL/d' /etc/default/locale /etc/environment 2>/dev/null || true
    update-locale LANG=ru_RU.UTF-8 LC_MESSAGES=ru_RU.UTF-8 LC_TIME=ru_RU.UTF-8
    print_success "Русская локаль установлена"

    # 2.3 Восстановление minimized
    if [ "$IS_MINIMIZED" = true ]; then
        apt-get install -y ubuntu-standard man-db bsdmainutils || true
    fi

    # 2.4 Базовые утилиты
    print_section "2.4 БАЗОВЫЕ УТИЛИТЫ"
    apt-get install -y \
        nano git curl wget unzip jq htop tmux net-tools dnsutils \
        bat eza fd-find ripgrep fzf \
        python3 python3-pip python3-venv build-essential \
        btop mtr iperf3 zsh sysbench \
        software-properties-common apt-transport-https ca-certificates gnupg \
        bsdmainutils ncdu iotop
    print_success "Базовые утилиты установлены"

    # 2.5 Zoxide
    print_section "2.5 ZOXIDE"
    if ! command -v zoxide >/dev/null 2>&1; then
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash -s -- --install-dir /usr/local/bin
        print_success "zoxide установлен"
    fi

    # 2.6 Системные улучшения
    print_section "2.6 СИСТЕМНЫЕ УЛУЧШЕНИЯ"
    apt-get install -y haveged 2>/dev/null || apt-get install -y rng-tools5 2>/dev/null || true
    
    apt-get install -y unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTOUPGRADE'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE
    
    apt-get install -y needrestart
    sed -i 's/#\$nrconf{restart} =.*/\$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf 2>/dev/null || true

    cat > /etc/sysctl.d/99-vps-tuning.conf << 'SYSCTL'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
kernel.pid_max = 65536
SYSCTL
    sysctl --system > /dev/null 2>&1

    cat > /etc/security/limits.d/99-vps.conf << 'LIMITS'
* soft nofile 524288
* hard nofile 1048576
root soft nofile 524288
root hard nofile 1048576
LIMITS
    print_success "Системные улучшения применены"

    # 2.7 Swap
    print_section "2.7 SWAP"
    if [ "$(swapon --show | wc -l)" -eq 0 ]; then
        RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
        if [ "$RAM_MB" -lt "$SWAP_RAM_THRESHOLD_MB" ]; then
            fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
            chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            print_success "Swap ${SWAP_SIZE} создан"
        fi
    fi

    # 2.8 Симлинки
    ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
    ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true

    # 2.9 Sudoers
    SUDOERS_LINE="$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw, /usr/bin/journalctl, /usr/bin/systemctl"
    grep -qF "$SUDOERS_LINE" /etc/sudoers 2>/dev/null || echo "$SUDOERS_LINE" | EDITOR='tee -a' visudo > /dev/null

    # 2.10 Создание пользователя pin
    print_section "2.10 ПОЛЬЗОВАТЕЛЬ $NEW_USER"
    if ! id -u "$NEW_USER" &>/dev/null; then
        adduser --disabled-password --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        print_success "Пользователь $NEW_USER создан"
    fi

    ask_input "Установить/изменить пароль для $NEW_USER? [Y/n]: " SET_PIN_PASS
    if [[ ! "$SET_PIN_PASS" =~ ^[Nn]$ ]]; then
        while true; do
            ask_password "Пароль для $NEW_USER: " PIN_PASS
            ask_password "Повторите: " PIN_PASS2
            if [ "$PIN_PASS" = "$PIN_PASS2" ] && [ -n "$PIN_PASS" ]; then
                echo "$NEW_USER:$PIN_PASS" | chpasswd
                print_success "Пароль установлен"
                break
            fi
            print_error "Пароли не совпадают или пусты"
        done
    fi

    # 2.11 SSH-ключ
    print_section "2.11 SSH-КЛЮЧ ДЛЯ $NEW_USER"
    PIN_SSH_DIR="/home/$NEW_USER/.ssh"
    PIN_AUTH_KEYS="$PIN_SSH_DIR/authorized_keys"
    
    ask_input "Добавить SSH-ключ для $NEW_USER? [Y/n]: " ADD_KEY
    if [[ ! "$ADD_KEY" =~ ^[Nn]$ ]]; then
        print_info "Вставьте публичный ключ:"
        read -r PUB_KEY < /dev/tty
        if [ -n "$PUB_KEY" ]; then
            mkdir -p "$PIN_SSH_DIR"
            echo "$PUB_KEY" >> "$PIN_AUTH_KEYS"
            chown -R "$NEW_USER:$NEW_USER" "$PIN_SSH_DIR"
            chmod 700 "$PIN_SSH_DIR"
            chmod 600 "$PIN_AUTH_KEYS"
            print_success "SSH-ключ добавлен"
        fi
    fi

    # 2.12 UFW
    print_section "2.12 UFW"
    command -v ufw >/dev/null 2>&1 || apt-get install -y ufw
    if ! LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        ufw allow 8443/tcp comment 'HTTPS'
        ufw allow "$SSH_PORT/tcp" comment 'SSH'
        ufw allow 5201/tcp comment 'iperf3'
        ufw allow 5201/udp comment 'iperf3'
        ask_input "Активировать UFW? [Y/n]: " ENABLE_UFW
        [[ "$ENABLE_UFW" =~ ^[Nn]$ ]] || { ufw --force enable; print_success "UFW активирован"; }
    fi

    # 2.13 SSH hardening
    print_section "2.13 SSH"
    SSHD_CONFIG="/etc/ssh/sshd_config"
    SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
    BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

    if ! ss -tuln | grep -q "0.0.0.0:$SSH_PORT "; then
        print_warning "SSH требует настройки"
        ask_input "Применить настройки SSH? [Y/n]: " APPLY_SSH
        if [[ ! "$APPLY_SSH" =~ ^[Nn]$ ]]; then
            cp "$SSHD_CONFIG" "$BACKUP_FILE"
            
            if [ -d "$SSHD_CONFIG_DIR" ]; then
                for f in "$SSHD_CONFIG_DIR"/*.conf; do
                    [ -f "$f" ] && grep -qE "^PasswordAuthentication yes" "$f" 2>/dev/null && \
                        { cp "$f" "$f.bak"; sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$f"; }
                done
                cat > "$SSHD_CONFIG_DIR/99-hardening.conf" << 'HARD'
PasswordAuthentication no
KbdInteractiveAuthentication no
HARD
            fi

            set_ssh() {
                grep -qE "^#?$1 " "$SSHD_CONFIG" && sed -i "s/^#\?$1 .*/$1 $2/" "$SSHD_CONFIG" || echo "$1 $2" >> "$SSHD_CONFIG"
            }

            set_ssh "Port" "$SSH_PORT"
            set_ssh "PermitRootLogin" "no"
            set_ssh "PasswordAuthentication" "no"
            set_ssh "PermitEmptyPasswords" "no"
            set_ssh "PubkeyAuthentication" "yes"
            set_ssh "KbdInteractiveAuthentication" "no"
            set_ssh "MaxAuthTries" "3"
            set_ssh "LogLevel" "VERBOSE"
            set_ssh "PermitUserEnvironment" "no"

            # Надёжное отключение socket activation
            if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
                systemctl stop ssh.socket 2>/dev/null || true
                systemctl disable ssh.socket 2>/dev/null || true
                [ -d /run/systemd/generator/ssh.socket.d ] && rm -rf /run/systemd/generator/ssh.socket.d
                [ -d /etc/systemd/system/ssh.socket.d ] && rm -rf /etc/systemd/system/ssh.socket.d
                systemctl mask ssh.socket
                systemctl daemon-reload
                systemctl reset-failed 2>/dev/null || true
                systemctl stop ssh.service 2>/dev/null || true
                sleep 2
                systemctl enable ssh.service
                systemctl start ssh.service
                sleep 5
                systemctl daemon-reload
                sleep 2
                print_success "ssh.socket замаскирован, классический SSH активен"
            else
                systemctl daemon-reload
                systemctl restart ssh.service
                sleep 3
            fi

            sshd -t && print_success "SSH настроен ✓" || { cp "$BACKUP_FILE" "$SSHD_CONFIG"; print_error "Ошибка, откат"; }
        fi
    fi

    # 2.14-2.18 Zsh + Oh My Zsh + P10k + плагины
    print_section "2.14 ZSH + OMZ + P10K"
    
    [[ "$(getent passwd "$CURRENT_USER" | cut -d: -f7)" == *"zsh"* ]] || chsh -s "$(which zsh)" "$CURRENT_USER"

    if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
        if [ "$CURRENT_USER" = "root" ]; then
            RUNZSH=no KEEP_ZSHRC=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        else
            [ -d "$USER_HOME" ] || { mkdir -p "$USER_HOME"; chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME"; }
            sudo -u "$CURRENT_USER" RUNZSH=no KEEP_ZSHRC=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        fi
    fi

    ZSH_CUSTOM="$USER_HOME/.oh-my-zsh/custom"
    [ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ] && {
        if [ "$CURRENT_USER" = "root" ]; then
            git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM/themes/powerlevel10k"
        else
            sudo -u "$CURRENT_USER" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM/themes/powerlevel10k"
        fi
    }

    clone_plugin() {
        [ -d "$ZSH_CUSTOM/plugins/$1" ] || {
            if [ "$CURRENT_USER" = "root" ]; then
                git clone "$2" "$ZSH_CUSTOM/plugins/$1"
            else
                sudo -u "$CURRENT_USER" git clone "$2" "$ZSH_CUSTOM/plugins/$1"
            fi
        }
    }
    clone_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
    clone_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"
    clone_plugin "zsh-completions" "https://github.com/zsh-users/zsh-completions"

    # ============================================
    # 2.19 .zshrc — ИСПРАВЛЕННАЯ ВЕРСИЯ
    # Все переменные переименованы, чтобы не конфликтовать
    # со специальными переменными zsh (path, fpath, etc.)
    # ============================================
    print_section "2.19 .zshrc (ИСПРАВЛЕННАЯ ВЕРСИЯ)"
    
    [ "$CURRENT_USER" = "root" ] && LOCAL_BIN="/root/.local/bin" || LOCAL_BIN="/home/$CURRENT_USER/.local/bin"

    TMP_ZSHRC=$(mktemp)
    cat > "$TMP_ZSHRC" << 'ZSHRC_TEMPLATE'
# ============================================================
# КРИТИЧЕСКИ ВАЖНО: PATH устанавливается В САМОМ НАЧАЛЕ!
# Это гарантирует что все команды будут найдены ДО того,
# как p10k instant prompt или setup_fzf их вызовут
# ============================================================
export PATH="__LOCAL_BIN__:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Fallback: если PATH всё ещё сломан — принудительно восстанавливаем
if ! command -v uname >/dev/null 2>&1; then
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
fi

# Powerlevel10k instant prompt (ПОСЛЕ установки PATH!)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# ВАЖНО: БЕЗ плагина fzf из OMZ! Он ломает minimized Ubuntu
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-completions
  sudo
  extract
  docker
)

source $ZSH/oh-my-zsh.sh

# === Алиасы ===
alias cat="bat --paging=never"
alias ls="eza --icons"
alias ll="eza -la --icons --git"
alias lt="eza --tree --icons --level=2"
alias grep="rg"
alias fd="fd"
alias cd="z"
alias top="btop"
alias ..="cd .."
alias ...="cd ../.."
alias ports="ss -tulnp"
alias myip="curl -s ifconfig.me"
alias reload="source ~/.zshrc"
alias ufwv="sudo ufw status verbose"
alias ufwn="sudo ufw status numbered"
alias sshlog="sudo journalctl -u ssh -n 50 --no-pager"
alias sshcheck="sudo sshd -t && echo 'SSH config OK'"
alias iotop="sudo iotop"
alias ncdu="ncdu --color dark"

# === FZF — ИСПРАВЛЕННАЯ ВЕРСИЯ ===
# КРИТИЧЕСКИ ВАЖНО: НЕ используем переменную `path` — она специальная в zsh!
# В zsh `path` автоматически синхронизирована с `PATH`, и её перезапись
# в цикле for ломает PATH для всей сессии.
# Используем безопасные имена: fzf_file, fzf_search_paths, fzf_tmp, fzf_comp
setup_fzf() {
  command -v fzf >/dev/null 2>&1 || return 0

  local fzf_ver
  # Используем абсолютный путь к awk, sort, head, grep для надёжности
  fzf_ver=$(fzf --version 2>/dev/null | /usr/bin/awk '{print $1}')

  # Если fzf >= 0.48.0 — встроенная интеграция
  if [[ -n "$fzf_ver" ]] && printf '%s\n%s' "0.48.0" "$fzf_ver" | /usr/bin/sort -V | /usr/bin/head -n1 | /usr/bin/grep -q "^0.48.0$"; then
    eval "$(fzf --zsh 2>/dev/null)" && return 0
  fi

  # Массив путей для поиска
  local fzf_search_paths=(
    "/usr/share/doc/fzf/examples/key-bindings.zsh"
    "/usr/share/fzf/key-bindings.zsh"
    "/usr/local/share/fzf/key-bindings.zsh"
  )
  
  # ИСПРАВЛЕНО: используем `fzf_file` вместо `path`!
  local fzf_file
  for fzf_file in "${fzf_search_paths[@]}"; do
    if [[ -f "$fzf_file" ]]; then
      source "$fzf_file" 2>/dev/null
      local fzf_comp="${fzf_file%/*}/completion.zsh"
      [[ -f "$fzf_comp" ]] && source "$fzf_comp" 2>/dev/null
      return 0
    fi
  done

  # Fallback: скачиваем с GitHub (используем абсолютные пути)
  local fzf_tmp
  fzf_tmp=$(/bin/mktemp 2>/dev/null || echo "/tmp/fzf_kb_$$")
  /usr/bin/curl -fsSL https://raw.githubusercontent.com/junegunn/fzf/master/shell/key-bindings.zsh -o "$fzf_tmp" 2>/dev/null && source "$fzf_tmp" 2>/dev/null
  /bin/rm -f "$fzf_tmp" 2>/dev/null
}
setup_fzf
unfunction setup_fzf 2>/dev/null || unset -f setup_fzf

# === Zoxide ===
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
else
  alias z="cd"
fi

# Подавляем warning p10k о console output
typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

# === Powerlevel10k config ===
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
ZSHRC_TEMPLATE

    sed "s|__LOCAL_BIN__|${LOCAL_BIN}|g" "$TMP_ZSHRC" > "$USER_HOME/.zshrc"
    rm -f "$TMP_ZSHRC"

    if [ "$CURRENT_USER" != "root" ]; then
        chown -R "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.oh-my-zsh" 2>/dev/null || true
        chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc" 2>/dev/null || true
    fi
    chmod 644 "$USER_HOME/.zshrc"
    print_success ".zshrc создан для $CURRENT_USER (с исправленным FZF)"

    # ============================================
    # ФИНАЛ
    # ============================================
    print_section "ФИНАЛЬНАЯ ПРОВЕРКА"
    ss -tuln | grep -q "0.0.0.0:$SSH_PORT " && print_success "SSH: $SSH_PORT ✓" || print_error "SSH НЕ слушает $SSH_PORT!"
    ss -tuln | grep -q "\[::\]:$SSH_PORT " && print_success "SSH IPv6: $SSH_PORT ✓"
    systemctl is-active --quiet ssh && print_success "SSH сервис активен ✓"
    LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active" && print_success "UFW активен ✓"

    print_success "ЧАСТЬ 2 ЗАВЕРШЕНА!"
    echo ""
    echo "=========================================="
    print_info "Следующие шаги:"
    echo "  1. exit (выйти из сессии)"
    echo "  2. ssh -p $SSH_PORT $CURRENT_USER@YOUR_IP"
    echo "  3. p10k configure (настроить p10k)"
    echo ""
    print_error "⚠️  ВХОД ТОЛЬКО ПО SSH-КЛЮЧУ!"
}

# ============================================
# ЧАСТЬ 3: ТЕСТЫ
# ============================================
part3_tests() {
    print_section "ЧАСТЬ 3: ТЕСТЫ"
    cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║  1) 📊 Мой iPerf3 Monitor    7) 🚫 IP блокировки     ║
║  2) 🌍 IP Region (IPv4)      8) ⚡ Bench.sh           ║
║  3) 🔒 Censorcheck (гео)     9) 🎯 IPQuality         ║
║  4) 🇷🇺 Censorcheck (DPI)   10) 💻 Sysbench CPU      ║
║  5) 🚀 iPerf3 РФ сервера    11) 🔁 Все тесты         ║
║  6) 📈 YABS                  0) Назад                ║
╚══════════════════════════════════════════════════════╝
EOF
    ask_input "Выбор: " T
    case "$T" in
        1) curl -fsSL https://raw.githubusercontent.com/Namsaraev/vps-setup/main/iperf_real_monitor.sh | bash ;;
        2) bash <(wget -qO- https://ipregion.vrnt.xyz) -4 ;;
        3) bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode geoblock ;;
        4) bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi ;;
        5) bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh) ;;
        6) curl -sL yabs.sh | bash -s -- -4 ;;
        7) bash <(curl -Ls IP.Check.Place) -l en ;;
        8) wget -qO- bench.sh | bash ;;
        9) bash <(curl -Ls https://Check.Place) -EI ;;
        10) sysbench cpu run --threads=1 ;;
        11) bash <(wget -qO- https://ipregion.vrnt.xyz) -4; curl -sL yabs.sh | bash -s -- -4 ;;
    esac
    pause
}

# ============================================
# ГЛАВНЫЙ ЦИКЛ
# ============================================
while true; do
    show_menu
    ask_input "Выберите действие [0-4]: " C
    case "$C" in
        1) part1_update ;;
        2) part2_setup ;;
        3) part3_tests ;;
        4) part1_update; print_warning "После reboot запустите пункт 2"; exit 0 ;;
        0) exit 0 ;;
        *) print_error "Неверный выбор" ;;
    esac
    pause
done
