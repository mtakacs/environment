#!/bin/bash
#  -*- shell-script -*-
#######################################################
# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples
## Tak Config
#######################################################

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# Source .bashrc for non-interactive Bash shells
export BASH_ENV="~/.bashrc"

# uncomment the following to activate bash-completion:
[ -f /etc/profile.d/bash-completion ] && source /etc/profile.d/bash-completion
[ -f /etc/bash_completion ] && ! shopt -oq posix && source /etc/bash_completion

# Git completion
[ -x $HOME/.git-completion.bash ] && source $HOME/.git-completion.bash
# Git prompt magic :  http://git-prompt.sh
[ -x $HOME/.git-prompt.sh ] && source $HOME/.git-prompt.sh

[ -x $HOME/.bash_export ] && source $HOME/.bash_export
[ -x $HOME/.bash_aliases ] && source $HOME/.bash_aliases
[ -x $HOME/.bash_ssh ] && source $HOME/.bash_ssh
[ -x $HOME/.bash_misc ] && source $HOME/.bash_misc
[ -x $HOME/.bash_func ] && source $HOME/.bash_func
[ -x $HOME/.bash_func_grails -a -f $HOME/.grails ] && source $HOME/.bash_func_grails
[ -x $HOME/dev/ansible/hacking/env-setup ] && source $HOME/dev/ansible/hacking/env-setup -q
[ -x $HOME/.bash_ruby ] && source $HOME/.bash_ruby
[ -x $HOME/.bash_pyenv ] && source $HOME/.bash_pyenv
#[ -x $HOME/.bash_citrus ] && source $HOME/.bash_citrus
#[ -x $HOME/.bash_ca ] && source $HOME/.bash_ca
[ -x $HOME/.bash_apple ] && source $HOME/.bash_apple

## Git Prompt magic -- i like this one better. Make sure this comes after PS1/PROMPT_COMMAND definitions
# @see ~/.git-prompt.conf
#[ -f $HOME/dev/git-prompt/git-prompt.sh ] && source $HOME/dev/git-prompt/git-prompt.sh

## Loads NVM
[ -s $HOME/.nvm/nvm.sh ] && . $HOME/.nvm/nvm.sh # This loads NVM

#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="~/.sdkman"
[[ -s "~/.sdkman/bin/sdkman-init.sh" ]] && source "~/.sdkman/bin/sdkman-init.sh"
