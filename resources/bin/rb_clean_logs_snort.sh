#!/bin/bash

for instance in $(ls -d /var/log/snort/instance-* 2>/dev/null); do
    pushd ${instance}/archive &>/dev/null
    find . -name "snort.log.*" -mtime +30 -delete
    popd &>/dev/null
done