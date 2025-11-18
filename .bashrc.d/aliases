#!/bin/bash
#  -*- shell-script -*-
#######################################################
# $Id: .bash_aliases,v 1.19 2008/09/22 16:12:00 tak Exp $
# @(#) aliases
# Rob's aliases
# Adopted and mutated by Tak

alias a=alias

#eval `dircolors -b /etc/DIR_COLORS`

#################################
# a bajillion ways to use ls
#################################
if [ -x /usr/local/bin/gnuls ] || [ -x ${HOME}/bin/gnuls ] ; then
  color="--color=auto"
  LS="/usr/local/bin/gnuls ${color}"
else
#  color="--color=auto -G"
  color="-G"
  LS="/bin/ls ${color}"
fi

# emacs shells dont like colors
if [ "$TERM" == 'emacs' ]
then
    unset color
    LS="/bin/ls"
fi

a d="${LS}"
a ls="${LS} -F"
a ll="${LS} -la"
a dir="${LS}"

a l="${LS} -lL"
a la="${LS} -laL"
a lart="${LS} -lArtL"
a lt="${LS} -lt"
a lrt="${LS} -lrtL"

#eval `dircolors -b /etc/DIR_COLORS`
#a d="ls --color"
#a ls="ls --color=auto"
#a ll="ls --color -l"

#a l='ls --color=always -lL'
#a la='ls --color=always -laL'
#a lart='ls --color=always -lArtL'
#a ls='ls --color=always -F'
#a lt='ls --color=always -lt'
#a ll="ls --color=always -la"
#a lrt='ls --color=always -lrtL'
#a dir="ls --color=always"

#################################
# utility aliases
#################################
a ,='cd $dot'
a ..='set dot=$cwd;cd ..'
#a cp='cp -prd'
a cp='cp -pr'
a pwd='pwd -P'
a clean='\rm -f *~ .*~ \#* .\#*'
a h='history \!* | more'
# a hg='history | egrep \!*'
a j='jobs'
a jc="javac -g"
a java_dbg="java -Xdebug -Xnoagent -Djava.compiler=NONE -Xrunjdwp:transport=dt_socket,server=y,address=8888,suspend=y"
a largest='find . -type f -print | xargs -i /bin/ls -al {} | sort -n +3 -4'
a lower='tr "[A-Z]" "[a-z]"'
a md=mkdir
a mm=less
a s=source
if [ -x ${HOME}/s/0emacs ] ; then
    a emacs="${HOME}/s/0emacs"
else
    a emacs="emacs -nw"
fi
a psa="ps -ef | egrep ${USER}"
a psgrep="ps -ef | egrep -v egrep | egrep "
a i="ps -auxw | grep -i"
a psmem="ps -u$USER -o s -o uid -o pid -o ppid -o pri -o vsz -o stime -o time -o comm"
a ts='set noglob; eval `tset -s -Q \!*`'
a vi=vim
a finding="find . -type f | grep -v ' ' | grep -v 'semantic.cache' | grep -v '/.svn/' | xargs egrep -s -e"


# change as required
a lsearch='ldapsearch -D "cn=directory manager" -w secretdog'

#a java12='/mojo/tools/linux/jdk1.2.2/bin/java'
#a tunnelgui='java12 org.apache.soap.util.net.TcpTunnelGui 1234 localhost 7001'

#a sql="sqlplus ${USER}/${USER}@ebiscuit.coscend.com"

a sfdevcvs="export CVS_RSH=ssh"
a sfanoncvs="unset CVS_RSH"
a eqportal="ssh -l mtakacs eqportal.sf.net"
a eqwaclasses="ssh -l mtakacs eqportal.sf.net"
a p68="ssh -l mtakacs direct.project68.com"

a takterm14="xterm -vb -fg white -bg black -font 7x14 &"
a takterm15="xterm -vb -fg white -bg black -font 9x15 &"
a takterm20="xterm -vb -fg white -bg black -font 10x20 &"
a takterm="xterm -vb -fg white -bg black -font 9x15 &"

a synergy="synergyc -f --name MacBook Jolo"

a flush_dns="dscacheutil -flushcache;sudo killall -HUP mDNSResponder"
a whatsmyip="curl http://ipecho.net/plain; echo"

