#!/bin/sh
DATESTAMP=`date +%Y%m%d-%H%M%S`
TARFILE="dotters_${DATESTAMP}.tar"
PWD=`pwd`
##
## Entire dirs we want to archive
##
DIRS=""
DIRS="${DIRS} ./.aws"
DIRS="${DIRS} ./.emacs.d"
DIRS="${DIRS} ./.ssh"
DIRS="${DIRS} ./.bashrc.d"
DIRS="${DIRS} ./s"
DIRS="${DIRS} ./.feldspar"
DIRS="${DIRS} ./.gradle/init.d"
##
## Individual dotrc files
##
DOTS=""
DOTS="${DOTS} ./.atom/*cson"
DOTS="${DOTS} ./.awsrc"
DOTS="${DOTS} ./.gradle/*properties"
DOTS="${DOTS} ./.bashrc"
DOTS="${DOTS} ./.bash_*"
DOTS="${DOTS} ./.cvsignore"
DOTS="${DOTS} ./.cvsrc"
DOTS="${DOTS} ./.digrc"
DOTS="${DOTS} ./.dircolors"
DOTS="${DOTS} ./.emacs"
DOTS="${DOTS} ./.git*"
DOTS="${DOTS} ./.inputrc"
DOTS="${DOTS} ./.p4config-zimbra"
DOTS="${DOTS} ./.ssh-agent"
DOTS="${DOTS} ./.viminfo"
DOTS="${DOTS} ./.vimrc"
DOTS="${DOTS} ./.xinitrc"
DOTS="${DOTS} ./.xsession"

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
