export LOCAL_BIN_DIR="${HOME}/.local/bin"
export SSH_ENV="$HOME/.ssh-agent-env"

log() {
  >&2 echo $@
}

check_zsh() {
  if [ "${SHELL}" = "/bin/zsh" ]; then
    return 0
  fi
  return 1
}

setup_path() {
  export PATH="${LOCAL_BIN_DIR}:${PATH}"
  return
}

# Stow-based dotfiles setup function (works in Bash and Zsh)
dotsetup() {
  local DOTFILES_DIR="$(realpath ${1})"

  if [[ ! -d "$DOTFILES_DIR" ]]; then
    log "Error: Directory not found: $DOTFILES_DIR"
    log "Usage: dotsetup [path_to_dotfiles_folder]"
    return 1
  fi

  cd "$DOTFILES_DIR" || return 1

  stow -d $(dirname ${DOTFILES_DIR}) -t ${HOME} -R -v $(basename ${DOTFILES_DIR})
}

install_packages_apt() {
  sudo apt-update -y && sudo apt install curl -y
  sudo install -dm 755 /etc/apt/keyrings
  sudo add-apt-repository ppa:neovim-ppa/unstable -y
  curl -fSs https://mise.jdx.dev/gpg-key.pub | sudo tee /etc/apt/keyrings/mise-archive-keyring.asc 1>/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.asc] https://mise.jdx.dev/deb stable main" | sudo tee /etc/apt/sources.list.d/mise.list

  sudo apt update -y
  sudo apt install mise unzip tmux stow git curl neovim ripgrep fd-find build-essential -y
}

install_packages_brew() {
  brew install mise stow git curl tmux neovim ripgrep fd unzip 
  return

}

install_packages_x() {
  curl -fSsL https://xpra.org/xpra.asc | sudo tee /etc/apt/keyrings/xpra.asc 1>/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/xpra.asc] https://xpra.org/ noble main" | sudo tee /etc/apt/sources.list.d/xpra.list
  curl -fsSL https://apt.fury.io/wez/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
  echo "deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *" | sudo tee /etc/apt/sources.list.d/wezterm.list
  sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" | sudo tee /etc/apt/sources.list.d/brave-browser-release.list
  sudo apt update -y
  sudo sudo apt install xpra i3-wm xserver-xorg-video-fbdev brave-browser picom wezterm-nightly feh -y
}

install_packages() {
  case $(uname -o) in
  Darwin)
    install_packages_brew
    return $?
    ;;
  GNU/Linux)
    install_packages_apt
    install_packages_x
    return $?
    ;;
  *)
    log "Unhandled uname -o"
    return 1
    ;;
  esac
}

mkdir_local_bin() {
  log "Ensuring ${LOCAL_BIN_DIR} is created"
  mkdir -p "${LOCAL_BIN_DIR}"
}

install_starship() {
  mkdir_local_bin
  log "Installing starship"
  pwd
  #curl -sS https://starship.rs/install.sh | BIN_DIR="${LOCAL_BIN_DIR} sh"
  curl -sS https://starship.rs/install.sh | sh -s -- -y -b "${LOCAL_BIN_DIR}"
}

init_starship() {
  eval "$(starship init zsh)"
}

install_antidote() {
  if [ ! -d "${HOME}/.antidote" ]; then
    log "installing antidote"
    git clone --depth=1 https://github.com/mattmc3/antidote.git ${HOME}/.antidote
  else
    echo "antidote already installed."
  fi
}

load_antidote() {
  zle -N menu-search
  zle -N recent-paths
  source ${HOME}/.antidote/antidote.zsh
  antidote load
}

bundle_antidote() {
  set +u
  source ${HOME}/.antidote/antidote.zsh
  antidote bundle <${HOME}/.zsh_plugins.txt >${HOME}/.zsh_plugins.zsh
  set -u
}

install_nerd_fonts() {
  install_nerd_font JetBrainsMono
  install_nerd_font FiraCode
  install_nerd_font Hack
}

install_nerd_font() {
  FONT=${1:-JetBrainsMono}

  log "Installing ${FONT} Nerd Font..."

  mkdir -p ${HOME}/.local/share/fonts
  (
    cd ${HOME}/.local/share/fonts

    curl -sfLO "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${FONT}.zip"
    unzip -q -o "${FONT}.zip"
    rm "${FONT}.zip"

    fc-cache -fv
  )

  log "Done! Font installed: ${FONT} Nerd Font"
}

start_ssh_agent() {
  ssh-agent -s | sed 's/^echo/#echo/' >"${SSH_ENV}"
  chmod 600 "${SSH_ENV}"
  source "${SSH_ENV}" >/dev/null
  ssh-add -l >/dev/null 2>&1 || ssh-add
}

activate_ssh_agent() {
  if [ -f "${SSH_ENV}" ]; then
    source "${SSH_ENV}" >/dev/null
    ssh-add -l >/dev/null 2>&1
    if [ $? -eq 2 ]; then
      start_ssh_agent
    fi
  else
    start_ssh_agent
  fi
}
