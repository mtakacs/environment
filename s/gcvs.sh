#!/bin/sh

dString=`date +%Y%m%d-%H%M`
dDir=${HOME}/backup/${dString}
mkdir -p ~/backup/${dString}
echo "Backing up files to ${dDir}"
cp $* ${dDir}
 
