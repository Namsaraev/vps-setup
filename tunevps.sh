# 11. .zshrc
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
alias h="history"
alias hg="history | grep"
alias reload="source ~/.zshrc"

alias ufwv="sudo ufw status verbose"
alias ufwn="sudo ufw status numbered"
alias ufwl="sudo journalctl -u ufw -n 50 --no-pager"

# === FZF (универсальный способ для всех версий Ubuntu) ===
source <(fzf --zsh)

# === Zoxide (умный cd) ===
eval "$(zoxide init zsh)"

# === Powerlevel10k config ===
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF
print_success "Файл .zshrc создан"
