#  -*- shell-script -*-
#######################################################
## $Id: .bashrc,v 1.8 2009/02/19 01:13:28 tak Exp $
## Tak Config
#######################################################

# Source .basrc for non-interactive Bash shells
export BASH_ENV="~/.bashrc"

# Change the window title of X terminals
case $TERM in
    xterm*|rxvt|Eterm|eterm)
        PROMPT_COMMAND='echo -ne "\033]0;${USER}@${HOSTNAME%%.*}:${PWD/$HOME/~}\007"'
        ;;
    screen)
        PROMPT_COMMAND='echo -ne "\033_${USER}@${HOSTNAME%%.*}:${PWD/$HOME/~}\033\\"'
        ;;
esac

##uncomment the following to activate bash-completion:
# bail on non-interactive shells (scp,etc)
if [ -z "$PS1" ]; then
   FOO="foo"
else
   [ -f /etc/profile.d/bash-completion ] && source /etc/profile.d/bash-completion
   [ -f /home/y/etc/yvm.bashrc ] && source /home/y/etc/yvm.bashrc

   [ -f $HOME/.bash_export ] && source $HOME/.bash_export
   [ -f $HOME/.bash_aliases ] && source $HOME/.bash_aliases
   [ -f $HOME/.bash_misc ] && source $HOME/.bash_misc
#   [ -f $HOME/.bash_yahoo ] && source $HOME/.bash_yahoo
   [ -f $HOME/.bash_func ] && source $HOME/.bash_func
   [ -f $HOME/.bash_func_grails && -f $HOME/.grails ] && source $HOME/.bash_func_grails
fi


