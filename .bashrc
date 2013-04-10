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


##uncomment the following to activate bash-completion:
[ -f /etc/profile.d/bash-completion ] && source /etc/profile.d/bash-completion
[ -f /etc/bash_completion ] && ! shopt -oq posix && source /etc/bash_completion


[ -f $HOME/.bash_export ] && source $HOME/.bash_export
[ -f $HOME/.bash_aliases ] && source $HOME/.bash_aliases
[ -f $HOME/.bash_misc ] && source $HOME/.bash_misc
#   [ -f $HOME/.bash_yahoo ] && source $HOME/.bash_yahoo
[ -f $HOME/.bash_citrus ] && source $HOME/.bash_citrus
[ -f $HOME/.bash_func ] && source $HOME/.bash_func
[ -f $HOME/.bash_func_grails -a -f $HOME/.grails ] && source $HOME/.bash_func_grails
[ -f $HOME/.git-completion.bash ] && source $HOME/.git-completion.bash
#[ -f $HOME/.git-prompt.sh ] && source $HOME/.git-prompt.sh

[[ $- == *i* ]] && source $HOME/dev/git-prompt/git-prompt.sh

#THIS MUST BE AT THE END OF THE FILE FOR GVM TO WORK!!!
[[ -s "/Users/tak/.gvm/bin/gvm-init.sh" && -z $(which gvm-init.sh | grep '/gvm-init.sh') ]] && source "/Users/tak/.gvm/bin/gvm-init.sh"

#eof
