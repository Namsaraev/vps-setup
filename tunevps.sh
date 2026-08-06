#!/bin/bash

set -e

# Отключаем интерактивные запросы debconf (КРИТИЧЕСКИ ВАЖНО для автоматизации)
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Автоматический перезапуск через sudo
if [ "$EUID" -ne 0 ]; then
    print_info "Требуются права root. Перезапускаем скрипт через sudo..."
    exec sudo bash "$0" "$@"
fi

print_info "Скрипт запущен от имени root"
CURRENT_USER="${SUDO_USER:-root}"
if [ "$CURRENT_USER" = "root" ]; then
    USER_HOME="/root"
else
    USER_HOME="/home/$CURRENT_USER"
fi

print_info "Настройка будет выполнена для пользователя: $CURRENT_USER"
echo ""

# ============================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================
print_info "Обновление системы..."
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y
print_success "Система обновлена"

# ============================================
# 2. ЧАСОВОЙ ПОЯС
# ============================================
print_info "Настройка часового пояса: Asia/Irkutsk"
timedatectl set-timezone Asia/Irkutsk
print_success "Часовой пояс установлен: $(timedatectl | grep 'Time zone')"

# ============================================
# 3. ЛОКАЛЬ
# ============================================
print_info "Настройка русской локали..."
apt-get install -y language-pack-ru
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8
print_success "Русская локаль установлена"

# ============================================
# 4. БАЗОВЫЕ УТИЛИТЫ
# ============================================
print_info "Установка базовых утилит..."
apt-get install -y \
    git curl wget unzip jq htop tmux net-tools dnsutils \
    bat eza fd-find ripgrep zoxide fzf \
    python3 python3-pip python3-venv build-essential \
    btop mtr iperf3 zsh
print_success "Базовые утилиты установлены"

# ============================================
# 5. СИМЛИНКИ
# ============================================
print_info "Создание симлинков для bat и fd..."
ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
print_success "Симлинки созданы"

# ============================================
# 6. SUDOERS (NOPASSWD)
# ============================================
print_info "Настройка sudoers для команд без пароля..."
SUDOERS_LINE="$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw, /usr/bin/journalctl"
if grep -q "$SUDOERS_LINE" /etc/sudoers 2>/dev/null; then
    print_warning "Правило sudoers уже существует"
else
    echo "$SUDOERS_LINE" | EDITOR='tee -a' visudo > /dev/null
    print_success "Sudoers настроен"
fi

# ============================================
# 7. ZSH
# ============================================
print_info "Установка Zsh как оболочки по умолчанию..."
chsh -s $(which zsh) "$CURRENT_USER"
print_success "Zsh установлен как оболочка по умолчанию"

# ============================================
# 8. OH MY ZSH
# ============================================
print_info "Установка Oh My Zsh..."
if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
    export RUNZSH=no
    export KEEP_ZSHRC=no
    if [ "$CURRENT_USER" = "root" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    else
        sudo -u "$CURRENT_USER" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi
    print_success "Oh My Zsh установлен"
else
    print_warning "Oh My Zsh уже установлен"
fi

# ============================================
# 9. POWERLEVEL10K
# ============================================
print_info "Установка Powerlevel10k..."
ZSH_CUSTOM_DIR="$USER_HOME/.oh-my-zsh/custom"
if [ ! -d "$ZSH_CUSTOM_DIR/themes/powerlevel10k" ]; then
    if [ "$CURRENT_USER" = "root" ]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM_DIR/themes/powerlevel10k"
    else
        sudo -u "$CURRENT_USER" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM_DIR/themes/powerlevel10k"
    fi
    print_success "Powerlevel10k установлен"
else
    print_warning "Powerlevel10k уже установлен"
fi

# ============================================
# 10. ПЛАГИНЫ OMZ
# ============================================
print_info "Установка плагинов Oh My Zsh..."
clone_plugin() {
    local name=$1
    local url=$2
    if [ ! -d "$ZSH_CUSTOM_DIR/plugins/$name" ]; then
        if [ "$CURRENT_USER" = "root" ]; then
            git clone "$url" "$ZSH_CUSTOM_DIR/plugins/$name"
        else
            sudo -u "$CURRENT_USER" git clone "$url" "$ZSH_CUSTOM_DIR/plugins/$name"
        fi
    fi
}

clone_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
clone_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"
clone_plugin "zsh-completions" "https://github.com/zsh-users/zsh-completions"
print_success "Плагины установлены"

# ============================================
# 11. .zshrc
# ============================================
print_info "Создание конфигурации .zshrc..."
cat > "$USER_HOME/.zshrc" << 'EOF'
# Enable Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
    zoxide
    fzf
    sudo
    extract
    docker
)

source $ZSH/oh-my-zsh.sh

# === Алиасы на современные утилиты ===
alias cat="bat --paging=never"
alias ls="eza --icons"
alias ll="eza -la --icons --git"
alias lt="eza --tree --icons --level=2"
alias grep="rg"
alias fd="fd"
alias cd="z"
alias top="btop"

# === Удобные алиасы ===
alias ..="cd .."
alias ...="cd ../.."
alias ports="ss -tulnp"
alias myip="curl -s ifconfig.me"
alias h="history"
alias hg="history | grep"
alias reload="source ~/.zshrc"

# === UFW (Firewall) ===
alias ufwv="sudo ufw status verbose"
alias ufwn="sudo ufw status numbered"
alias ufwl="sudo journalctl -u ufw -n 50 --no-pager"

# === FZF (универсальный способ для всех Ubuntu 22/24/26) ===
source <(fzf --zsh)

# === Zoxide (умный cd) ===
eval "$(zoxide init zsh)"

# === Powerlevel10k config ===
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF
print_success "Файл .zshrc создан"

# ============================================
# 12. ПРАВА ДОСТУПА
# ============================================
if [ "$CURRENT_USER" != "root" ]; then
    chown -R "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.oh-my-zsh"
    chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc"
fi

# ============================================
# ФИНАЛ
# ============================================
echo ""
echo "=========================================="
print_success "Настройка завершена!"
echo "=========================================="
echo ""
print_info "ВАЖНО: Для применения всех изменений:"
echo ""
echo "  1. Выйдите из текущей SSH-сессии: exit"
echo "  2. Зайдите снова на сервер (Zsh подхватится автоматически)"
echo "  3. При первом входе запустите настройку Powerlevel10k: p10k configure"
echo "  4. Установите шрифт MesloLGS NF на ваш локальный компьютер:"
echo "     https://github.com/romkatv/powerlevel10k#fonts"
echo ""
print_warning "Не забудьте настроить SSH вручную"
echo ""
