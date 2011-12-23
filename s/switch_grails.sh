#!/bin/bash

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

DIR=/usr/local
GRAILS_NEW=grails-2.0.0
GROOVY_NEW=groovy-1.8.5
GRAILS_OLD=grails-1.3.7
GROOVY_OLD=groovy-1.7.10

GRAILS_CURRENT=`readlink ${DIR}/grails`
GROOVY_CURRENT=`readlink ${DIR}/groovy`

#echo ${GRAILS_CURRENT}
#echo ${GROOVY_CURRENT}

rm -f ${DIR}/grails
rm -f ${DIR}/groovy

case "$1" in 
    1.3.7) 
        #echo "Switch $1 -- 1.3.7"
        ln -s ${DIR}/${GRAILS_OLD} grails
        ln -s ${DIR}/${GROOVY_OLD} groovy
    ;;
    2.0) 
        #echo "Switch $1 -- 2.0"
        ln -s ${DIR}/${GRAILS_NEW} grails
        ln -s ${DIR}/${GROOVY_NEW} groovy
    ;;
    2.0.0) 
        #echo "Switch $1 -- 2.0.0"
        ln -s ${DIR}/${GRAILS_NEW} grails
        ln -s ${DIR}/${GROOVY_NEW} groovy
    ;;
    *)
        #echo "Switch default"
        if [ "${GRAILS_CURRENT}" == "${DIR}/${GRAILS_NEW}" ]
        then
            ln -s ${DIR}/${GRAILS_OLD} grails
            ln -s ${DIR}/${GROOVY_OLD} groovy
        else
            ln -s ${DIR}/${GRAILS_NEW} grails
            ln -s ${DIR}/${GROOVY_NEW} groovy
        fi
    ;;
esac

GRAILS_CURRENT=`readlink ${DIR}/grails`
GROOVY_CURRENT=`readlink ${DIR}/groovy`

echo "Switched: Grails[${GRAILS_CURRENT}] Groovy[${GROOVY_CURRENT}]"

