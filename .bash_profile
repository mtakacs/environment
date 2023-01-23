#!/bin/sh
#  -*- shell-script -*-
#######################################################
# $Id: .bash_profile,v 1.3 2005/06/02 22:45:28 tak Exp $
## Tak config here
#######################################################

#This file is sourced by bash when you log in interactively.
[ -f ~/.bashrc ] && . ~/.bashrc
[[ :$PATH: == *:$HOME/bin:* ]] || PATH=$HOME/bin:$PATH
