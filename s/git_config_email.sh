#!/bin/bash

CMD="git config user.email='mtakacs@apple.com'"

for D in *; do
    if [ -d "${D}" ]; then
        echo "${D}: ${CMD}"
        cd $D ; git config user.email="mtakacs@apple.com"; cd ..
    fi
done
