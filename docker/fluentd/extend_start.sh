#!/bin/bash

# Give processes executed with the "kolla" group the permission to create files
# and sub-directories in the /var/log/kolla-ceph directory.
#
# Also set the setgid permission on the /var/log/kolla-ceph directory so that new
# files and sub-directories in that directory inherit its group id ("kolla").

USERGROUP="fluentd:kolla"
FLUENTD="fluentd"

if [ ! -d /var/log/kolla-ceph ]; then
    mkdir -p /var/log/kolla-ceph
fi
if [[ $(stat -c %U:%G /var/log/kolla-ceph) != "${USERGROUP}" ]]; then
    sudo chown ${USERGROUP} /var/log/kolla-ceph
fi
if [[ $(stat -c %a /var/log/kolla-ceph) != "2775" ]]; then
    sudo chmod 2775 /var/log/kolla-ceph
fi
if [[ $(stat -c %U:%G /var/lib/${FLUENTD}) != "${USERGROUP}" ]]; then
    sudo chown ${USERGROUP} /var/lib/${FLUENTD}
fi
