#!/bin/bash

if [[ ! -d "/var/log/kolla-ceph/ceph" ]]; then
    mkdir -p /var/log/kolla-ceph/ceph
fi
if [[ $(stat -c %a /var/log/kolla-ceph/ceph) != "755" ]]; then
    chmod 755 /var/log/kolla-ceph/ceph
fi
