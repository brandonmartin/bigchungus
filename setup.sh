#!/bin/zsh

set -euo pipefail

source lib/funkshuns.sh

if ! check_zsh; then
  log "zsh4lyfe"
  exit 1
fi

install_packages

dotsetup ./home

activate_ssh_agent
install_antidote
bundle_antidote
install_starship

log "Setup done!"
