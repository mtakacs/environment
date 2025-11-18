#!/bin/sh
DATESTAMP=`date +%Y%m%d-%H%M%S`
TARFILE="dotters_${DATESTAMP}.tar"
PWD=`pwd`
##
## Entire dirs we want to archive
##
DIRS=""
DIRS="${DIRS} ./.agilebits"
DIRS="${DIRS} ./.aws"
DIRS="${DIRS} ./.bashrc.d"
DIRS="${DIRS} ./.emacs.d"
DIRS="${DIRS} ./.feldspar"
DIRS="${DIRS} ./.gradle/init.d"
DIRS="${DIRS} ./.oh-my-zsh"
DIRS="${DIRS} ./.ssh"
DIRS="${DIRS} ./s"
##
## Individual dotrc files
##
DOTS=""
DOTS="${DOTS} ./.atom/*cson"
DOTS="${DOTS} ./.awsrc"
DOTS="${DOTS} ./.bash_*"
DOTS="${DOTS} ./.bashrc"
DOTS="${DOTS} ./.bashrc.FreeBSD"
DOTS="${DOTS} ./.cvsignore"
DOTS="${DOTS} ./.cvsrc"
DOTS="${DOTS} ./.digrc"
DOTS="${DOTS} ./.dircolors"
DOTS="${DOTS} ./.emacs"
DOTS="${DOTS} ./.ExifTool_config"
DOTS="${DOTS} ./.git*"
DOTS="${DOTS} ./.gradle/*properties"
DOTS="${DOTS} ./.inputrc"
DOTS="${DOTS} ./.p10k.zsh"
DOTS="${DOTS} ./.p4config-zimbra"
DOTS="${DOTS} ./.profile"
DOTS="${DOTS} ./.nvmrc"
DOTS="${DOTS} ./.ssh-agent"
DOTS="${DOTS} ./.viminfo"
DOTS="${DOTS} ./.vimrc"
DOTS="${DOTS} ./.xinitrc"
DOTS="${DOTS} ./.xsession"
DOTS="${DOTS} ./.zprofile"
DOTS="${DOTS} ./.zsh_history"
DOTS="${DOTS} ./.zshrc"

dirs="${DIRS}"
files="${DOTS}"

#cd ${HOME}

rm -f ${TARFILE}
rm -f ${TARFILE}.gz

for d in $dirs; do
    if [ -d $d ]; then
      # echo $d
      tar -rvf ${TARFILE} --exclude "*~" $d/*
    fi
done

for f in $files; do
  if [ -f $f ]; then
    # echo $f
    tar -rvf ${TARFILE} $f
  fi
done

gzip --best ${TARFILE}

#cd ${PWD}
