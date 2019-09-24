#!/usr/bin/python

# Copyright 2015 Sam Yaple
# Copyright 2019 Wang Wei
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This module has been relicensed from the source below:
# https://github.com/SamYaple/yaodu/blob/master/ansible/library/ceph_osd_list

import json
import pyudev
import re
import subprocess  # nosec

from ansible.module_utils.basic import AnsibleModule
from ceph_volume.api import lvm as api

DOCUMENTATION = '''
---
module: find_disks
short_description: Return list of devices containing a specfied name or label
description:
     - This will return a list of all devices with either GPT partition name
       or filesystem label of the name specified.
options:
  match_mode:
    description:
      - Label match mode, either strict or prefix
    default: 'strict'
    required: False
    choices: [ "strict", "prefix" ]
    type: str
  name:
    description:
      - Partition name or filesystem label
    required: True
    type: str
    aliases: [ 'partition_name' ]
  use_udev:
    description:
      - When True, use Linux udev to read disk info such as partition labels,
        uuid, etc.  Some older host operating systems have issues using udev to
        get the info this module needs. Set to False to fall back to more low
        level commands such as blkid to retrieve this information. Most users
        should not need to change this.
    default: True
    required: False
    type: bool
author: Sam Yaple
'''

EXAMPLES = '''
- hosts: ceph-osd
  tasks:
    - name: Return all valid formated devices with the name KOLLA_CEPH_OSD
      find_disks:
          name: 'KOLLA_CEPH_OSD'
      register: osds
'''

CEPH_MPATH_LIST = list()


def get_id_part_entry_name(dev, use_udev):
    if use_udev:
        dev_name = dev.get('ID_PART_ENTRY_NAME', '')
    else:
        part = re.sub(r'.*[^\d]', '', dev.device_node)
        parent = dev.find_parent('block').device_node
        # NOTE(Mech422): Need to use -i as -p truncates the partition name
        out = subprocess.Popen(['/usr/sbin/sgdisk', '-i', part,  # nosec
                                parent],
                               stdout=subprocess.PIPE).communicate()
        match = re.search(r'Partition name: \'(\w+)\'', out[0])
        if match:
            dev_name = match.group(1)
        else:
            dev_name = ''
    return dev_name


def get_id_fs_uuid(dev, use_udev):
    if use_udev:
        id_fs_uuid = dev.get('ID_FS_UUID', '')
    else:
        out = subprocess.Popen(['/usr/sbin/blkid', '-o', 'export',  # nosec
                                dev.device_node],
                               stdout=subprocess.PIPE).communicate()
        match = re.search(r'\nUUID=([\w-]+)', out[0])
        if match:
            id_fs_uuid = match.group(1)
        else:
            id_fs_uuid = ''
    return id_fs_uuid


def get_part_label_for_mpath(dev, use_udev):
    dev_name = ''
    if use_udev:
        dev_name = dev.get('ID_PART_ENTRY_NAME', '')

    if dev_name == '':
        out = subprocess.Popen(['/usr/sbin/blkid', '-o', 'export',  # nosec
                                dev.device_node],
                               stdout=subprocess.PIPE).communicate()
        match = re.search(r'\nPARTLABEL=([\w-]+)', out[0])
        if match:
            dev_name = match.group(1)
    return dev_name


def get_id_part_uuid(dev, use_udev):
    if use_udev:
        id_part_uuid = dev.get('ID_PART_ENTRY_UUID', '')
    else:
        out = subprocess.Popen(['/usr/sbin/blkid', '-o', 'export',  # nosec
                                dev.device_node],
                               stdout=subprocess.PIPE).communicate()
        match = re.search(r'\nPARTUUID=([\w-]+)', out[0])
        if match:
            id_part_uuid = match.group(1)
        else:
            id_part_uuid = ''
    return id_part_uuid


def get_mapper_path(dev):
    match = re.search(r'/dev/mapper/[\w]+', dev.get('DEVLINKS', ''))
    if match:
        dev_path = match.group()
    else:
        dev_path = ''
    return dev_path


def is_mapper_device(dev):
    if dev.get('DEVTYPE', '') == 'disk' and get_mapper_path(dev):
        return True
    return False


def is_exists_device(ct, dev_name):
    try:
        pyudev.Device.from_device_file(ct, dev_name)
    except OSError:
        return False
    return True


def get_mapper_parent(ct, mapper_path):
    part_num = re.sub(r'.*[^\d]', '', mapper_path)
    dev_name = mapper_path[:-len(part_num)]

    if is_exists_device(ct, dev_name):
        return dev_name
    else:
        if dev_name.endswith('p') and dev_name[-2].isdigit():
            dev_name = dev_name[:-1]
            if is_exists_device(ct, dev_name):
                return dev_name
        return ''


def is_dev_matched_by_name(dev, name, mode, use_udev):
    if dev.get('DEVTYPE', '') == 'partition':
        dev_name = get_id_part_entry_name(dev, use_udev)
    elif is_mapper_device(dev):
        dev_name = get_part_label_for_mpath(dev, use_udev)
    else:
        dev_name = dev.get('ID_FS_LABEL', '')

    if mode == 'strict':
        return dev_name == name
    elif mode == 'prefix':
        return dev_name.startswith(name)
    else:
        return False


def find_disk(ct, name, match_mode, use_udev):
    for dev in ct.list_devices(subsystem='block'):
        if is_dev_matched_by_name(dev, name, match_mode, use_udev):
            yield dev


def extract_disk_info_ceph(ct, dev, name, use_udev):
    if not dev:
        return
    kwargs = dict()
    kwargs['fs_uuid'] = get_id_fs_uuid(dev, use_udev)
    kwargs['fs_label'] = dev.get('ID_FS_LABEL', '')

    if dev.get('DEVTYPE', '') == 'partition':
        actual_name = get_id_part_entry_name(dev, use_udev)
        if actual_name in CEPH_MPATH_LIST:
            return
        dev_partition = dev.device_node
        dev_parent = dev.find_parent('block').device_node
        if 'iscsi' in dev.get('ID_PATH', ''):
            dev_type = 'iscsi'
        else:
            dev_type = 'regular'
    elif is_mapper_device(dev):
        actual_name = get_part_label_for_mpath(dev, use_udev)
        dev_partition = get_mapper_path(dev)
        dev_parent = get_mapper_parent(ct, dev_partition)
        if not dev_parent:
            return
        dev_type = 'mpath'
        CEPH_MPATH_LIST.append(actual_name)
    else:
        return

    if name in actual_name:
        kwargs['partition'] = dev_partition
        kwargs['partition_num'] = re.sub(r'.*[^\d]', '', dev_partition)
        kwargs['device'] = dev_parent
        kwargs['partition_label'] = actual_name
        kwargs['partition_uuid'] = get_id_part_uuid(dev, use_udev)
        kwargs['partition_type'] = dev_type

        if actual_name.endswith("_B"):
            kwargs['partition_usage'] = 'block'
            return kwargs

        if actual_name.endswith("_D"):
            kwargs['partition_usage'] = 'block.db'
            return kwargs

        if actual_name.endswith("_W"):
            kwargs['partition_usage'] = 'block.wal'
            return kwargs

        if actual_name.endswith("_J"):
            kwargs['partition_usage'] = 'journal'
            return kwargs

        kwargs['partition_usage'] = 'osd'
        if 'BOOTSTRAP_BS' in actual_name or 'DATA_BS' in actual_name:
            kwargs['store_type'] = 'bluestore'
        else:
            kwargs['store_type'] = 'filestore'

        if 'BOOTSTRAP_BSL' in actual_name or \
                'DATA_BSL' in actual_name or \
                'BOOTSTRAP_L' in actual_name or \
                'DATA_L' in actual_name:
            kwargs['disk_mode'] = 'LVM'
            return kwargs
        else:
            kwargs['disk_mode'] = 'DISK'
            return kwargs
    return


def filter_mpath_subdisk(disks):
    result = list()
    for item in disks:
        if (item['partition_type'] != 'mpath' and
                item['partition_label'] in CEPH_MPATH_LIST):
            continue
        result.append(item)
    return result


def nb_of_osd(disks):
    osd_info = dict()
    osd_info['label'] = list()
    nb_of_osds = 0
    for item in disks:
        if item['partition_usage'] == 'osd':
            osd_info['label'].append(item['partition_label'])
            nb_of_osds += 1
    osd_info['nb_of_osd'] = nb_of_osds
    return osd_info


def get_lvm_osd_info(final):
    pv = api.get_pv(pv_name=final['osd_partition'])
    if not pv:
        return

    lv = api.get_lv(vg_name=pv.vg_name)
    if lv:
        final['osd_data_block'] = lv.tags.get('ceph.block_device', '')
        final['osd_data_wal'] = lv.tags.get('ceph.wal_device', '')
        final['osd_data_db'] = lv.tags.get('ceph.db_device', '')
        final['osd_data_osd'] = lv.tags.get('ceph.data_device', '')
        final['osd_data_id'] = lv.tags.get('ceph.osd_id', '')


def final_bluestore(disks, idx_osd, idx_blk, idx_wal, idx_db, final):
    if disks[idx_osd]['disk_mode'] == 'DISK':
        if idx_blk != -1:
            final['blk_device'] = disks[idx_blk]['device']
            final['blk_partition'] = disks[idx_blk]['partition']
            final['blk_partition_num'] = disks[idx_blk]['partition_num']
            final['blk_partition_uuid'] = disks[idx_blk]['partition_uuid']
            final['blk_partition_type'] = disks[idx_blk]['partition_type']
            disks[idx_blk]['partition_usage'] = ''
            final['external_journal_or_block'] = True
        else:
            # If no block partition was found, then kolla will automatically
            # initialize the entire disk, so make sure the partition_num is 1
            if int(disks[idx_osd]['partition_num']) != 1:
                return

            final['blk_device'] = disks[idx_osd]['device']
            final['blk_partition'] = disks[idx_osd]['partition'][:-1] + '2'
            final['blk_partition_num'] = 2
            final['blk_partition_type'] = disks[idx_osd]['partition_type']
            final['external_journal_or_block'] = False
    else:
        final['blk_device'] = disks[idx_osd]['device']
        final['blk_partition'] = disks[idx_osd]['partition']
        final['blk_partition_num'] = disks[idx_osd]['partition_num']
        final['blk_partition_uuid'] = disks[idx_osd]['partition_uuid']
        final['blk_partition_type'] = disks[idx_osd]['partition_type']
        final['external_journal_or_block'] = False

    if idx_wal != -1:
        final['wal_device'] = disks[idx_wal]['device']
        final['wal_partition'] = disks[idx_wal]['partition']
        final['wal_partition_num'] = disks[idx_wal]['partition_num']
        final['wal_partition_uuid'] = disks[idx_wal]['partition_uuid']
        final['wal_partition_type'] = disks[idx_wal]['partition_type']
        disks[idx_wal]['partition_usage'] = ''

    if idx_db != -1:
        final['db_device'] = disks[idx_db]['device']
        final['db_partition'] = disks[idx_db]['partition']
        final['db_partition_num'] = disks[idx_db]['partition_num']
        final['db_partition_uuid'] = disks[idx_db]['partition_uuid']
        final['db_partition_type'] = disks[idx_db]['partition_type']
        disks[idx_db]['partition_usage'] = ''

    return True


def final_filestore(disks, idx_osd, idx_jnl, final):
    if idx_jnl != -1:
        final['journal_device'] = disks[idx_jnl]['device']
        final['journal_partition'] = disks[idx_jnl]['partition']
        final['journal_partition_num'] = disks[idx_jnl]['partition_num']
        final['journal_partition_uuid'] = disks[idx_jnl]['partition_uuid']
        final['journal_partition_type'] = disks[idx_jnl]['partition_type']
        disks[idx_jnl]['partition_usage'] = ''
        final['external_journal_or_block'] = True
    else:
        if int(disks[idx_osd]['partition_num']) != 1:
            return

        final['journal_device'] = disks[idx_osd]['device']
        final['journal_partition'] = disks[idx_osd]['partition'][:-1] + '2'
        final['journal_partition_num'] = 2
        final['journal_partition_type'] = disks[idx_osd]['partition_type']
        final['external_journal_or_block'] = False

    return True


def combine_info(disks):
    info = list()
    osds = nb_of_osd(disks)
    for osd_id in range(osds['nb_of_osd']):
        final = dict()
        idx = 0
        idx_osd = idx_blk = idx_wal = idx_db = idx_jnl = -1
        for item in disks:
            if (item['partition_usage'] == 'osd' and
                    item['partition_label'] == osds['label'][osd_id]):
                idx_osd = idx
            elif (item['partition_usage'] == 'block' and
                    item['partition_label'] == osds['label'][osd_id] + "_B"):
                idx_blk = idx
            elif (item['partition_usage'] == 'block.wal' and
                    item['partition_label'] == osds['label'][osd_id] + "_W"):
                idx_wal = idx
            elif (item['partition_usage'] == 'block.db' and
                    item['partition_label'] == osds['label'][osd_id] + "_D"):
                idx_db = idx
            elif (item['partition_usage'] == 'journal' and
                    item['partition_label'] == osds['label'][osd_id] + "_J"):
                idx_jnl = idx
            idx += 1

        if disks[idx_osd]['store_type'] == "bluestore":
            ret = final_bluestore(disks, idx_osd, idx_blk, idx_wal, idx_db, final)
        else:
            ret = final_filestore(disks, idx_osd, idx_jnl, final)

        if not ret:
            continue

        final['osd_fs_uuid'] = disks[idx_osd]['fs_uuid']
        final['osd_fs_label'] = disks[idx_osd]['fs_label']
        final['osd_device'] = disks[idx_osd]['device']
        final['osd_partition'] = disks[idx_osd]['partition']
        final['osd_partition_num'] = disks[idx_osd]['partition_num']
        final['osd_partition_uuid'] = disks[idx_osd]['partition_uuid']
        final['osd_partition_type'] = disks[idx_osd]['partition_type']
        final['osd_disk_mode'] = disks[idx_osd]['disk_mode']
        final['osd_store_type'] = disks[idx_osd]['store_type']

        if final['osd_disk_mode'] == 'LVM':
            get_lvm_osd_info(final)

        disks[idx_osd]['partition_usage'] = ''
        info.append(final)

    return info


def main():
    argument_spec = dict(
        match_mode=dict(required=False, choices=['strict', 'prefix'],
                        default='strict'),
        name=dict(aliases=['partition_name'], required=True, type='str'),
        use_udev=dict(required=False, default=True, type='bool')
    )
    module = AnsibleModule(argument_spec)
    match_mode = module.params.get('match_mode')
    name = module.params.get('name')
    use_udev = module.params.get('use_udev')
    # This script is only used to collect ceph disk information.
    if 'KOLLA_CEPH_' not in name:
        return

    try:
        ret = list()
        ct = pyudev.Context()
        for dev in find_disk(ct, name, match_mode, use_udev):
            info = extract_disk_info_ceph(ct, dev, name, use_udev)
            if info:
                ret.append(info)

        if len(ret) > 0:
            if len(CEPH_MPATH_LIST) > 0:
                ret = filter_mpath_subdisk(ret)
            ret = combine_info(ret)

        module.exit_json(disks=json.dumps(ret))
    except Exception as e:
        module.exit_json(failed=True, msg=repr(e))


if __name__ == '__main__':
    main()
