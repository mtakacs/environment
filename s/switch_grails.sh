#!/bin/bash

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

DIR=/usr/local
GRAILS_NEW=grails-2.1.1
GROOVY_NEW=groovy-1.8.6
GRAILS_OLD=grails-1.3.9
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
purge_grails_cache ()
{
    echo "Purging grails cache"
    rm -rf ${HOME}/.grails ${HOME}/.ivy2
}

case "$1" in
    1.3.9) link_old
    ;;
    2.1) link_new
    ;;
    2.1.0) link_new
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
purge_grails_cache

GRAILS_CURRENT=`readlink ${DIR}/grails`
GROOVY_CURRENT=`readlink ${DIR}/groovy`

echo "Switched: Grails[${GRAILS_CURRENT}] Groovy[${GROOVY_CURRENT}]"

