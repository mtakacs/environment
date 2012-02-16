#!/bin/bash

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

DIR=/usr/local
GRAILS_NEW=grails-2.0.1
GROOVY_NEW=groovy-1.8.6
GRAILS_OLD=grails-1.3.7
GROOVY_OLD=groovy-1.7.10

GRAILS_CURRENT=`readlink ${DIR}/grails`
GROOVY_CURRENT=`readlink ${DIR}/groovy`

#echo ${GRAILS_CURRENT}
#echo ${GROOVY_CURRENT}

link_old ()
{
    #echo "Setting up grails_old"
    rm -f ${DIR}/grails
    rm -f ${DIR}/groovy
    ln -s ${DIR}/${GRAILS_OLD} ${DIR}/grails
    ln -s ${DIR}/${GROOVY_OLD} ${DIR}/groovy
}
link_new ()
{
    #echo "Setting up grails_new"
    rm -f ${DIR}/grails
    rm -f ${DIR}/groovy
    ln -s ${DIR}/${GRAILS_NEW} ${DIR}/grails
    ln -s ${DIR}/${GROOVY_NEW} ${DIR}/groovy
}

case "$1" in 
    1.3.7) link_old
    ;;
    2.0) link_new
    ;;
    2.0.0) link_new
    ;;
    *)
        if [ "${GRAILS_CURRENT}" == "${DIR}/${GRAILS_NEW}" ]
        then
            #echo "Setting up grails_old"
            link_old
        else
            #echo "Setting up grails_new"
            link_new
        fi
    ;;
esac

GRAILS_CURRENT=`readlink ${DIR}/grails`
GROOVY_CURRENT=`readlink ${DIR}/groovy`

echo "Switched: Grails[${GRAILS_CURRENT}] Groovy[${GROOVY_CURRENT}]"

