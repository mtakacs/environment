#  -*- shell-script -*-
#######################################################
# $Id: .xsession,v 1.3 2005/07/13 19:37:39 tak Exp $

PATH=/home/bin/y:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/local/sbin:/usr/X11R6/bin
/usr/X11R6/bin/xscreensaver &
#exec /usr/bin/ssh-agent /usr/X11R6/bin/ctwm 
#exec /usr/bin/ssh-agent /usr/X11R6/bin/enlightenment
#exec /usr/bin/ssh-agent /usr/X11R6/bin/sawfish
#exec /usr/bin/ssh-agent /usr/X11R6/bin/gnome-session
exec /usr/bin/ssh-agent /usr/local/bin/startkde
