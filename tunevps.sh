#!/bin/bash

set -e  # Остановка при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для красивого вывода
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка прав
if [ "$EUID" -eq 0 ]; then
    print_info "Скрипт запущен от имени root"
    CURRENT_USER="root"
    USER_HOME="/root"
elif sudo -n true 2>/dev/null; then
    print_info "Скрипт запущен с правами sudo"
    CURRENT_USER=$(whoami)
    USER_HOME="$HOME"
else
    print_error "Для работы скрипта нужны права root или sudo"
    exit 1
fi

print_info "Начинаем настройку системы для пользователя: $CURRENT_USER"
echo ""

# ============================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================
print_info "Обновление системы..."
sudo apt update -y
sudo apt upgrade -y
print_success "Система обновлена"

# ============================================
# 2. НАСТРОЙКА ЧАСОВОГО ПОЯСА
# ============================================
print_info "Настройка часового пояса: Asia/Irkutsk"
sudo timedatectl set-timezone Asia/Irkutsk
print_success "Часовой пояс установлен: $(timedatectl | grep 'Time zone')"

# ============================================
# 3. НАСТРОЙКА РУССКОЙ ЛОКАЛИ
# ============================================
print_info "Настройка русской локали..."
sudo apt install language-pack-ru -y
sudo locale-gen ru_RU.UTF-8
sudo update-locale LANG=ru_RU.UTF-8
print_success "Русская локаль установлена"

# ============================================
# 4. УСТАНОВКА ПОЛЕЗНЫХ УТИЛИТ
# ============================================
print_info "Установка Modern CLI утилит..."
sudo apt install -y \
    git \
    curl \
    wget \
    unzip \
    jq \
    htop \
    tmux \
    net-tools \
    dnsutils \
    bat \
    eza \
    fd-find \
    ripgrep \
    zoxide \
    fzf \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    btop \
    mtr \
    iperf3 \
    zsh \
    procs

print_success "Утилиты установлены"

# ============================================
# 5. СОЗДАНИЕ СИМЛИНКОВ ДЛЯ UBUNTU
# ============================================
print_info "Создание симлинков для bat и fd..."
sudo ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
print_success "Симлинки созданы"

# ============================================
# 6. НАСТРОЙКА SUDOERS (NOPASSWD)
# ============================================
print_info "Настройка sudoers для команд без пароля..."
SUDOERS_LINE="$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw, /usr/bin/journalctl"
if sudo grep -q "$SUDOERS_LINE" /etc/sudoers 2>/dev/null; then
    print_warning "Правило sudoers уже существует"
else
    echo "$SUDOERS_LINE" | sudo tee -a /etc/sudoers > /dev/null
    print_success "Sudoers настроен"
fi

# ============================================
# 7. УСТАНОВКА И НАСТРОЙКА ZSH
# ============================================
print_info "Установка Zsh как оболочки по умолчанию..."

# Меняем shell для текущего пользователя
if [ "$CURRENT_USER" = "root" ]; then
    sudo chsh -s $(which zsh) root
else
    sudo chsh -s $(which zsh) "$CURRENT_USER"
fi
print_success "Zsh установлен как оболочка по умолчанию"

# ============================================
# 8. УСТАНОВКА OH MY ZSH
# ============================================
print_info "Установка Oh My Zsh..."
if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
    # Используем unattended установку (без интерактива)
    export RUNZSH=no
    export KEEP_ZSHRC=no
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    print_success "Oh My Zsh установлен"
else
    print_warning "Oh My Zsh уже установлен"
fi

# ============================================
# 9. УСТАНОВКА POWERLEVEL10K
# ============================================
print_info "Установка Powerlevel10k..."
if [ ! -d "$USER_HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        ${ZSH_CUSTOM:-$USER_HOME/.oh-my-zsh/custom}/themes/powerlevel10k
    print_success "Powerlevel10k установлен"
else
    print_warning "Powerlevel10k уже установлен"
fi

# ============================================
# 10. УСТАНОВКА ПЛАГИНОВ OMZ
# ============================================
print_info "Установка плагинов Oh My Zsh..."

# zsh-autosuggestions
if [ ! -d "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions \
        ${ZSH_CUSTOM:-$USER_HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
fi

# zsh-syntax-highlighting
if [ ! -d "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
        ${ZSH_CUSTOM:-$USER_HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
fi

# zsh-completions
if [ ! -d "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-completions" ]; then
    git clone https://github.com/zsh-users/zsh-completions \
        ${ZSH_CUSTOM:-$USER_HOME/.oh-my-zsh/custom}/plugins/zsh-completions
fi

print_success "Плагины установлены"

# ============================================
# 11. СОЗДАНИЕ .zshrc
# ============================================
print_info "Создание конфигурации .zshrc..."

cat > "$USER_HOME/.zshrc" << 'EOF'
# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load
ZSH_THEME="powerlevel10k/powerlevel10k"

# Which plugins would you like to load?
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

# === FZF ===
source /usr/share/doc/fzf/examples/key-bindings.zsh
source /usr/share/doc/fzf/examples/completion.zsh

# === Zoxide (умный cd) ===
eval "$(zoxide init zsh)"

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF

print_success "Файл .zshrc создан"

# ============================================
# 12. НАСТРОЙКА ПРАВ ДОСТУПА
# ============================================
if [ "$CURRENT_USER" != "root" ]; then
    sudo chown -R "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.oh-my-zsh"
    sudo chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc"
fi

# ============================================
# ФИНАЛЬНЫЕ ИНСТРУКЦИИ
# ============================================
echo ""
echo "=========================================="
print_success "Настройка завершена!"
echo "=========================================="
echo ""
print_info "ВАЖНО: Для применения всех изменений выполните:"
echo ""
echo "  1. Выйдите из текущей SSH-сессии:"
echo "     exit"
echo ""
echo "  2. Зайдите снова на сервер:"
echo "     ssh $CURRENT_USER@YOUR_SERVER_IP"
echo ""
echo "  3. При первом входе запустите настройку Powerlevel10k:"
echo "     p10k configure"
echo ""
echo "  4. Установите шрифт MesloLGS NF на ваш локальный компьютер:"
echo "     https://github.com/romkatv/powerlevel10k#fonts"
echo ""
print_warning "Не забудьте настроить SSH вручную после выхода из скрипта"
echo ""
