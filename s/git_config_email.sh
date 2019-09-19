#!/bin/bash

for dir in *; do
    if [ -d "${dir}" ]; then
        echo "${dir}: setting git config options"
        cd ${dir} 
        git config user.name "Mark Takacs"
        git config user.email "mtakacs@apple.com" 
        git config user.signingkey 066E2D2C
        git config push.followTags true
        cd ..
    fi
done
