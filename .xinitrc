#  -*- shell-script -*-
#######################################################
# $Id: .xinitrc,v 1.6 2005/06/02 22:45:28 tak Exp $

ssh-agent -s | sed -e '/^echo/d' > $HOME/.ssh-agent
source $HOME/.ssh-agent
/usr/bin/ssh-add

#/usr/X11R6/bin/xsetroot -solid DarkSlateBlue &

userresources=$HOME/.Xresources
usermodmap=$HOME/.Xmodmap
sysresources=/usr/X11R6/lib/X11/xinit/.Xresources
sysmodmap=/usr/X11R6/lib/X11/xinit/.Xmodmap

# merge in defaults and keymaps
if [ -f $sysresources ]; then
    xrdb -merge $sysresources
fi
if [ -f $sysmodmap ]; then
    xmodmap $sysmodmap
fi
if [ -f $userresources ]; then
    xrdb -merge $userresources
fi
if [ -f $usermodmap ]; then
    xmodmap $usermodmap
fi
