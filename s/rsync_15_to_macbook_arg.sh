#!/bin/bash
OPTS=""
#OPTS="${OPTS} -n"
OPTS="${OPTS} --progress"
OPTS="${OPTS} --delete"
OPTS="${OPTS} -va"
OPTS="${OPTS} --iconv=utf-8-mac,utf-8"
SRCDIR="/c/media/music/$1"
DESTDIR="/Users/TAKMA07/Music"

if [ -z "$1" ]
then
  echo "Need an arg"
  exit 1
fi

echo rsync ${OPTS} 192.168.2.15:${SRCDIR} ${DESTDIR}
rsync ${OPTS} 192.168.2.15:${SRCDIR} ${DESTDIR}
