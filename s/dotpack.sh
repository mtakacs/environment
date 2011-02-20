#!/bin/sh


PWD=`pwd`
DOTS="./.bashrc"
EMACS_DIR="./.emacs.d"
SSH_DIR="./.ssh"
SCRIPTS_DIR="./s"
DOTS="${DOTS} ./.bash_aliases"
DOTS="${DOTS} ./.bash_export"
DOTS="${DOTS} ./.bash_func"
#DOTS="${DOTS} ./.bash_history"  # dont export this
DOTS="${DOTS} ./.bash_misc"
DOTS="${DOTS} ./.bash_profile"
DOTS="${DOTS} ./.bash_yahoo"
DOTS="${DOTS} ./.bashrc"
DOTS="${DOTS} ./.bashrc.FreeBSD"
DOTS="${DOTS} ./.cvsignore"
DOTS="${DOTS} ./.cvsrc"
DOTS="${DOTS} ./.dircolors"
DOTS="${DOTS} ./.emacs"
DOTS="${DOTS} ./.inputrc"
DOTS="${DOTS} ./.p4config-zimbra"
DOTS="${DOTS} ./.ssh-agent"
DOTS="${DOTS} ./.viminfo"
DOTS="${DOTS} ./.vimrc"
DOTS="${DOTS} ./.xinitrc"
DOTS="${DOTS} ./.xsession"
TARFILE="dotters.tar"

dirs="${EMACS_DIR} ${SCRIPTS_DIR} ${SSH_DIR}"
files="${DOTS}"

cd  ${HOME}

rm -f ${TARFILE}
rm -f ${TARFILE}.gz

for d in $dirs; do
    echo $d
    tar -rvf ${TARFILE} --exclude "*~" $d/*
done

for f in $files; do
    echo $f
    tar -rvf ${TARFILE} $f
done

gzip --best ${TARFILE}

cd ${PWD}
