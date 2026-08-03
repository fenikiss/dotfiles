export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="alanpeabody"

plugins=(git zsh-autosuggestions)

export LC_ALL=en_US.UTF-8

HISTFILE=$HOME/.zhistory
SAVEHIST=1000
HISTSIZE=999

PROMPT="$TERM_STRING"

source $ZSH/oh-my-zsh.sh
source <(fzf --zsh)
eval "$(zoxide init zsh)"

autoload -U colors && colors

PROMPT='%F{242}%~%f %F{white}$%f '

ZSH_THEME_GIT_PROMPT_PREFIX="%F{8}*"
ZSH_THEME_GIT_PROMPT_SUFFIX="%f"

# Remove símbolos de estado
ZSH_THEME_GIT_PROMPT_DIRTY=""
ZSH_THEME_GIT_PROMPT_CLEAN=""
ZSH_THEME_GIT_PROMPT_ADDED=""
ZSH_THEME_GIT_PROMPT_MODIFIED=""
ZSH_THEME_GIT_PROMPT_DELETED=""
ZSH_THEME_GIT_PROMPT_RENAMED=""
ZSH_THEME_GIT_PROMPT_UNMERGED=""
ZSH_THEME_GIT_PROMPT_UNTRACKED=""

bindkey '^ ' autosuggest-accept

export PATH=$PATH:$(go env GOPATH)/bin

alias ta="tmux a"
alias tnew="tmux new-session -t"
alias tls="tmux ls"
alias tk="tmux kill-session -t"
