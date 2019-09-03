#!/usr/bin/env python

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

import json
import subprocess  # nosec


DOCUMENTATION = '''
---
module: kolla_ceph_device_class
short_description: >
  Module for set ceph osd device class.
description:
  - A module used to set ceph osd device class in kolla-ceph.
options:
  osd_id:
    description:
      - the osd id in ceph
    required: True
    type: int
  container_name:
    description:
      - the ceph mon container name
    required: False
    default: ceph_mon
    type: str
  device_class:
    description:
      - the device class of osd
    required: True
    type: str
author: Wang Wei
'''

EXAMPLES = '''
- name: set the device class to osd
  kolla_ceph_device_class:
    osd_id: 1
    container_name: ceph_mon
    device_class: "hdd"
'''


class CephDeviceClass(object):
    def __init__(self, osd_id, device_class, container_name='ceph_mon'):
        self.osd_id = osd_id
        self.device_class = device_class
        self.container_name = container_name
        self.changed = False
        self.message = None

    def _run(self, cmd):
        _prefix = ['docker', 'exec', self.container_name]
        cmd = _prefix + cmd
        proc = subprocess.Popen(cmd,  # nosec
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        stdout, stderr = proc.communicate()
        retcode = proc.poll()
        if retcode != 0:
            output = 'stdout: "%s", stderr: "%s"' % (stdout, stderr)
            raise subprocess.CalledProcessError(retcode, cmd, output)
        return stdout

    def parse_stdout(self, stdout):
        result = json.loads(stdout)
        return result

    def set_device_class(self):
        if self.device_class == '':
            self.message = 'The device class is empty, no need to set.'
            return
        stdout = self.get_class_osd()
        osds = self.parse_stdout(stdout)
        if self.osd_id not in osds:
            self.remove_osd_class()
            self.set_osd_class()
            self.changed = True
            self.message = 'The device class of osd.{0} is successfully set' \
                           ' to {1}.'.format(self.osd_id, self.device_class)
        else:
            self.message = 'The device class of osd.{0} has been set to ' \
                           '{1}.'.format(self.osd_id, self.device_class)

    def get_class_osd(self):
        ceph_cmd = ['ceph', '--format', 'json', 'osd', 'crush', 'class',
                    'ls-osd', self.device_class]
        return self._run(ceph_cmd)

    def remove_osd_class(self):
        ceph_cmd = ['ceph', '--format', 'json', 'osd', 'crush',
                    'rm-device-class', '{}'.format(self.osd_id)]
        self._run(ceph_cmd)

    def set_osd_class(self):
        ceph_cmd = ['ceph', '--format', 'json', 'osd', 'crush',
                    'set-device-class', self.device_class,
                    'osd.{}'.format(self.osd_id)]
        self._run(ceph_cmd)


def main():
    specs = dict(
        osd_id=dict(type='int', required=True),
        container_name=dict(type='str', default='ceph_mon'),
        device_class=dict(type='str', required=True)
    )
    module = AnsibleModule(argument_spec=specs)  # noqa
    params = module.params
    ceph_device_class = CephDeviceClass(params['osd_id'],
                                        params['device_class'],
                                        params['container_name'])
    try:
        ceph_device_class.set_device_class()
        module.exit_json(changed=ceph_device_class.changed,
                         message=ceph_device_class.message)
    except subprocess.CalledProcessError as ex:
        msg = ('Failed to call command: %s returncode: %s output: %s' %
               (ex.cmd, ex.returncode, ex.output))
        module.fail_json(msg=msg)


from ansible.module_utils.basic import *  # noqa
if __name__ == "__main__":
    main()
