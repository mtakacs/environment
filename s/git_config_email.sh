#!/bin/bash

for dir in *; do
    if [ -d "${dir}" ]; then
        echo "REPO: ${dir}: Running commands.."
        cd ${dir} 
        git config user.name "Mark Takacs"
        git config user.email "mtakacs@apple.com" 
        #git config push.followTags true
        #git checkout 1.45
        git pull
        # git fetch
        cd ..
        echo "REPO: ${dir}: done"
        echo 
    fi
done
