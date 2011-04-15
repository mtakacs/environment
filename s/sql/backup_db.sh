#!/bin/sh
#
# USAGE: backup (database) (user) (password)
#
# If called w/o arguments, the defaults listed below are used
#
# Tak - July 2004

## --- CONFIGURE ME: start ---
## --- CONFIGURE ME: start ---
## --- CONFIGURE ME: start ---

## How many backup copies you want to keep
KEEP=7

## Defaut Dump Dir
DBDUMP_DIR="/home/sql/data"

## Defaut DB info
DEFAULT_DB="eqportal"
DEFAULT_USER="eqportal"
DEFAULT_PASS="the...Commune"

DEFAULT_DB="wordpress"
DEFAULT_USER="wp"
DEFAULT_PASS="word...press"

# gallery2 g2/g2pass
# eqportal eqportal/TheCommune
# wordpress wp/wp!pass
# vbulletin eqportal/TheCommune


## --- CONFIGURE ME: end ---
## --- CONFIGURE ME: end ---
## --- CONFIGURE ME: end ---

## Hopefully this doesnt need configured
MYSQLDUMP="/usr/bin/mysqldump --add-drop-table"
GZIP="/bin/gzip --best"
RM="/bin/rm"

## Use supplied values or defaults
DB=${1:-${DEFAULT_DB}}
DBUSER=${2:-${DEFAULT_USER}}
DBPASS=${3:-${DEFAULT_PASS}}

## Get today's date
TODAY=`date +%Y%m%d-%H%M`

# where to place the data Dump
if [ -d ${DBDUMP_DIR} ]; 
	then
		BACKUP=${DBDUMP_DIR}/${DB}_${TODAY}.sql
	else
		BACKUP=`pwd`/${DB}_${TODAY}.sql
fi

echo "Dumping DB(${DB}) to $BACKUP"

## Delete a backup if we ran this today already
if [ -f ${BACKUP} ]; 
	then ${RM} ${BACKUP} 
fi
if [ -f ${BACKUP}.gz ];
	then ${RM} ${BACKUP}.gz	
fi

## Dump the Request DB
${MYSQLDUMP} -u ${DBUSER} --password=${DBPASS} ${DB} > $BACKUP

## GZIP the Dump
if [ -f ${BACKUP} ]; 
	then ${GZIP} ${BACKUP}
fi

#### PRUNE

COUNT=`echo $(ls ${DBDUMP_DIR}/${DB}_* | wc -l)`

let DELETE=${COUNT}-${KEEP}
#echo "COUNT($COUNT) KEEP($KEEP) DELETE($DELETE)"

if [ $DELETE -gt 0 ]; 
	then  
		DELFILES=`ls ${DBDUMP_DIR}/${DB}_* | head -n ${DELETE}`
		for dead in $DELFILES ; do
			echo "Pruning old backup: $dead"
			${RM} -f $dead
		done
#	else
#		echo "Nothing to delete"
fi



exit
# eof
