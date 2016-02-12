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

##
## Run all the bashrc fragments
##
for script in .bashrc.d/*; do
    # skip non-executable snippets
    [ -x "$script" ] && source $script
done

## Install ansible from source
[ -x $HOME/dev/ansible/hacking/env-setup ] && source $HOME/dev/ansible/hacking/env-setup -q

## Git Prompt magic -- i like this one better. Make sure this comes after PS1/PROMPT_COMMAND definitions
# @see ~/.git-prompt.conf
#[ -f $HOME/dev/git-prompt/git-prompt.sh ] && source $HOME/dev/git-prompt/git-prompt.sh

## Loads NVM
[ -s $HOME/.nvm/nvm.sh ] && . $HOME/.nvm/nvm.sh # This loads NVM

#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="~/.sdkman"
[[ -s "~/.sdkman/bin/sdkman-init.sh" ]] && source "~/.sdkman/bin/sdkman-init.sh"
