# kolla-ceph

## Purpose

The purpose of this repo is to provide a docker deployment tool of ceph, it include building ceph image, deploying ceph cluster, maintaining ceph services, upgrading ceph versions, updating configurations, and related operations.

Previously, the openstack/kolla project provided a good structure for containerized deployments, including some deployments of ceph, but the Kolla community was planning to abandon the development of ceph deployments, and they wanted to focus on the work related to openstack.

I think this way of deploying ceph is very good. It's a pity to give up, so I will make secondary development on the basis of kolla. Because my energy is limited, so this repo currently only provides containerization and related script settings based on centos 7.
