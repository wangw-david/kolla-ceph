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
module: kolla_ceph_pools
short_description: >
  Module for creating a ceph pool.
description:
  - A module used to create a ceph pool in kolla-ceph.
options:
  pool_name:
    description:
      - the name of ceph pool
    required: True
    type: str
  pool_type:
    description:
      - the type of ceph pool
    required: True
    type: str
  pool_pg_num:
    description:
      - the pg number of ceph pool
    required: True
    type: str
  pool_pgp_num:
    description:
      - the pgp number of ceph pool
    required: True
    type: str
  pool_application:
    description:
      - the application of ceph pool
    required: True
    type: str
  pool_erasure_name:
    description:
      - the name of erasure-code-profile
    required: when pool type is erasure-code
    type: str
  pool_erasure_profile:
    description:
      - the profile of erasure-code-profile
    required: when pool type is erasure-code
    type: str
  pool_rule_name:
    description:
      - the name of replicated rule
    required: when pool type is replicated
    type: str
  pool_rule:
    description:
      - the content of replicated rule
    required: when pool type is replicated
    type: str
  pool_cache_enable:
    description:
      - Whether to enable ceph pool cache
    required: False
    type: bool
  pool_cache_mode:
    description:
      - the mode of ceph pool cache
    required: When ceph pool cache is enabled
    type: str
  pool_cache_rule_name:
    description:
      - the name of ceph pool cache rule
    required: When ceph pool cache is enabled
    type: str
  pool_cache_rule:
    description:
      - the content of ceph pool cache rule
    required: When ceph pool cache is enabled
    type: str
  pool_cache_pg_num:
    description:
      - the pg number of ceph pool cache
    required: When ceph pool cache is enabled
    type: str
  pool_cache_pgp_num:
    description:
      - the pgp number of ceph pool cache
    required: When ceph pool cache is enabled
    type: str
  target_max_bytes:
    description:
      - the target_max_bytes of ceph pool cache
    required: When ceph pool cache is enabled
    type: str
  target_max_objects:
    description:
      - the target_max_objects of ceph pool cache
    required: When ceph pool cache is enabled
    type: str
author: Wang Wei
'''

EXAMPLES = '''
- name: Create a ceph pool
  kolla_ceph_pools:
    pool_name: "rbd"
    pool_type: "replicated"
    pool_rule_name: "hdd"
    pool_rule: "default host hdd"
    pool_pg_num: 32
    pool_pgp_num: 32
    pool_application: "rbd"
'''


class CephPool(object):
    def __init__(self, module, name, type, pg_num, pgp_num, application, erasure_name, erasure_profile,
                 rule_name, rule, cache_enable, cache_mode, cache_rule_name, cache_rule,
                 cache_pg_num, cache_pgp_num, target_max_bytes, target_max_objects,):
        self.module = module
        self.name = name
        self.type = type
        self.pg_num = pg_num
        self.pgp_num = pgp_num
        self.application = application
        self.erasure_name = erasure_name
        self.erasure_profile = erasure_profile
        self.rule_name = rule_name
        self.rule = rule
        self.cache_enable = cache_enable
        self.cache_mode = cache_mode
        self.cache_rule_name = cache_rule_name
        self.cache_rule = cache_rule
        self.cache_pg_num = cache_pg_num
        self.cache_pgp_num = cache_pgp_num
        self.target_max_bytes = target_max_bytes
        self.target_max_objects = target_max_objects
        self.changed = False
        self.message = None

    def _run(self, cmd):
        _prefix = ['docker', 'exec', 'ceph_mon']
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

    def prepare_pool(self):
        if self.name == '':
            self.message = 'The pool name is empty, can not create it.'
            raise

        if self.type == '':
            self.message = 'The pool type is empty, can not create it.'
            raise

        if self.pg_num == '':
            self.message = 'The pool pg number is empty, can not create it.'
            raise

        if self.pgp_num == '':
            self.message = 'The pool pgp number is empty, can not create it.'
            raise

        if self.application == '':
            self.message = 'The pool application is empty, can not create it.'
            raise

        stdout = self.get_pools()
        pools = self.parse_stdout(stdout)
        for pool in pools:
            if pool.get('poolname', '') == self.name:
                self.message = 'A pool of the same name has been created, please check it.'
                return

        if self.type == 'erasure':
            self.create_erasure_profile()
            self.create_pool(self.name, self.pg_num, self.pgp_num, self.type, self.erasure_name)
            self.enable_application()
            self.enable_overwrites()
        else:
            if self.rule_name == '':
                self.message = 'The pool rule_name is empty, can not create it.'
                return

            if self.rule == '':
                self.message = 'The pool rule is empty, can not create it.'
                return
            self.create_replicated_rule(self.rule_name, self.rule)
            self.create_pool(self.name, self.pg_num, self.pgp_num, self.type, self.rule_name)
            self.enable_application()

        if self.cache_enable:
            if self.cache_rule_name == '':
                self.message = 'The pool cache_rule_name is empty, can not create it.'
                return

            if self.cache_rule == '':
                self.message = 'The pool cache_rule is empty, can not create it.'
                return
            self.create_replicated_rule(self.cache_rule_name, self.cache_rule)
            self.create_pool('{}-cache'.format(self.name), self.cache_pg_num, self.cache_pgp_num, 'replicated',
                             self.cache_rule_name)
            self.add_cache_to_pool()
            self.set_cache_mode()
            self.set_cache_overlay()
            if self.target_max_bytes != '':
                self.set_cache_target_max_bytes()

            if self.target_max_objects != '':
                self.set_cache_target_max_objects()

        self.changed = True
        self.message = 'The pool {} was created successfully.'.format(self.name)

    def create_erasure_profile(self):
        if self.erasure_name == '':
            self.message = 'The pool erasure_name is empty, can not create it.'
            return

        if self.erasure_profile == '':
            self.message = 'The pool erasure_profile is empty, can not create it.'
            return
        profile_list = self.erasure_profile.split()
        ceph_cmd = ['ceph', 'osd', 'erasure-code-profile', 'set', self.erasure_name]
        ceph_cmd = ceph_cmd + profile_list
        return self._run(ceph_cmd)

    def create_replicated_rule(self, rule_name, rule):
        rule_list = rule.split()
        ceph_cmd = ['ceph', 'osd', 'crush', 'rule', 'create-replicated', rule_name]
        ceph_cmd = ceph_cmd + rule_list
        return self._run(ceph_cmd)

    def get_pools(self):
        ceph_cmd = ['ceph', '--format', 'json', 'osd', 'lspools']
        return self._run(ceph_cmd)

    def create_pool(self, name, pg_num, pgp_num, type, erasure_rule_name):
        ceph_cmd = ['ceph', 'osd', 'pool', 'create', name, pg_num, pgp_num,
                    type, erasure_rule_name]
        self._run(ceph_cmd)

    def enable_application(self):
        ceph_cmd = ['ceph', 'osd', 'pool', 'application', 'enable', self.name, self.application]
        self._run(ceph_cmd)

    def enable_overwrites(self):
        ceph_cmd = ['ceph', 'osd', 'pool', 'set', self.name, 'allow_ec_overwrites', 'true']
        self._run(ceph_cmd)

    def add_cache_to_pool(self):
        ceph_cmd = ['ceph', 'osd', 'tier', 'add', self.name, '{}-cache'.format(self.name)]
        self._run(ceph_cmd)

    def set_cache_mode(self):
        ceph_cmd = ['ceph', 'osd', 'tier', 'cache-mode', '{}-cache'.format(self.name), self.cache_mode]
        self._run(ceph_cmd)

    def set_cache_overlay(self):
        ceph_cmd = ['ceph', 'osd', 'tier', 'set-overlay', self.name, '{}-cache'.format(self.name)]
        self._run(ceph_cmd)

    def set_cache_hit_set_type(self):
        ceph_cmd = ['ceph', 'osd', 'pool', 'set', '{}-cache'.format(self.name), 'hit_set_type', 'bloom']
        self._run(ceph_cmd)

    def set_cache_target_max_bytes(self):
        ceph_cmd = ['ceph', 'osd', 'pool', 'set', '{}-cache'.format(self.name), 'target_max_bytes',
                    self.target_max_bytes]
        self._run(ceph_cmd)

    def set_target_max_objects(self):
        ceph_cmd = ['ceph', 'osd', 'pool', 'set', '{}-cache'.format(self.name), 'target_max_objects',
                    self.target_max_objects]
        self._run(ceph_cmd)


def main():
    specs = dict(
        pool_name=dict(type='str', required=True),
        pool_type=dict(type='str', required=True),
        pool_pg_num=dict(type='str', required=True),
        pool_pgp_num=dict(type='str', required=True),
        pool_application=dict(type='str', required=True),
        pool_erasure_name=dict(type='str', required=False),
        pool_erasure_profile=dict(type='str', required=False),
        pool_rule_name=dict(type='str', required=False),
        pool_rule=dict(type='str', required=False),
        pool_cache_enable=dict(type='bool', required=False),
        pool_cache_mode=dict(type='str', required=False),
        pool_cache_rule_name=dict(type='str', required=False),
        pool_cache_rule=dict(type='str', required=False),
        pool_cache_pg_num=dict(type='str', required=False),
        pool_cache_pgp_num=dict(type='str', required=False),
        target_max_bytes=dict(type='str', required=False),
        target_max_objects=dict(type='str', required=False)
    )
    module = AnsibleModule(argument_spec=specs)  # noqa
    params = module.params
    ceph_pool = CephPool(module,
                         params['pool_name'],
                         params['pool_type'],
                         params['pool_pg_num'],
                         params['pool_pgp_num'],
                         params['pool_application'],
                         params['pool_erasure_name'],
                         params['pool_erasure_profile'],
                         params['pool_rule_name'],
                         params['pool_rule'],
                         params['pool_cache_enable'],
                         params['pool_cache_mode'],
                         params['pool_cache_rule_name'],
                         params['pool_cache_rule'],
                         params['pool_cache_pg_num'],
                         params['pool_cache_pgp_num'],
                         params['target_max_bytes'],
                         params['target_max_objects'])
    try:
        ceph_pool.prepare_pool()
        module.exit_json(changed=ceph_pool.changed,
                         message=ceph_pool.message)
    except subprocess.CalledProcessError as ex:
        msg = ('Failed to call command: %s returncode: %s output: %s' %
               (ex.cmd, ex.returncode, ex.output))
        module.fail_json(msg=msg)


from ansible.module_utils.basic import *  # noqa
if __name__ == "__main__":
    main()
