
source ~/.local/lib/funkshuns.sh

export LS_COLORS="di=38;5;81:fi=38;5;252:ln=38;5;117:or=38;5;203:mi=38;5;203:ex=38;5;155:*.tar=38;5;204:*.gz=38;5;204:*.zip=38;5;204:*.jpg=38;5;216:*.png=38;5;216:st=38;5;220:tw=38;5;220:ow=38;5;220"

setup_path

load_antidote

#unalias gc 2> /dev/null

init_starship

eval "$(mise activate zsh)"

activate_ssh_agent

eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
fpath=(~/.grok/completions/zsh $fpath)
autoload -Uz compinit && compinit -C
# <<< grok installer <<<
