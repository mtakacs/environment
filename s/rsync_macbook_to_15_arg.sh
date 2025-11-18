#!/bin/bash
OPTS=""
#OPTS="${OPTS} -n"
OPTS="${OPTS} --progress"
OPTS="${OPTS} --delete"
OPTS="${OPTS} -va"
OPTS="${OPTS} --iconv=utf-8-mac,utf-8"
SRCDIR="/Users/TAKMA07/Music/$1"
DESTDIR="/c/media/music/"

if [ -z "$1" ]
then
  echo "Need an arg"
  exit 1
fi

echo rsync ${OPTS} ${SRCDIR} 192.168.2.15:${DESTDIR}
rsync ${OPTS} ${SRCDIR} 192.168.2.15:${DESTDIR}
