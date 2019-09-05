# kolla-ceph

## Purpose

The purpose of this repo is to provide a docker deployment tool of ceph, it include building ceph image, deploying ceph cluster, maintaining ceph services, upgrading ceph versions, updating configurations, and related operations.

Previously, the openstack/kolla project provided a good structure for containerized deployments, including some deployments of ceph, but the Kolla community was planning to abandon the development of ceph deployments, and they wanted to focus on the work related to openstack.

I think this way of deploying ceph is very good. It's a pity to give up, so I will make secondary development on the basis of kolla. Because my energy is limited, so this repo currently only provides containerization and related script settings based on centos 7.

## Build images

### Modify the build configuration (ceph-build.conf)


```
[DEFAULT]
base = centos
type = binary

profile = image_ceph

registry = 192.168.10.11:4000
username =
password =
email =

namespace = kolla-ceph
retries = 1
push_threads = 4
maintainer = Kolla Ceph Project
ceph_version = nautilus
ceph_release = 14.2.2

[profiles]
image_ceph = fluentd,cron,kolla-toolbox,ceph
```

``Note:``
 
``1.Mainly modify the information of docker regisry.``
``2.We can control the fixed version number with ceph_release.``

### Run the build script

- Determine the users and permissions to execute the script

Please confirm that the user running the shell script has the correct permissions. Building the image requires saving some data to (/home/kolla-ceph) folder. You can modify the folder location in the script:

```
BUILD_DATA_PATH="/home/kolla-ceph"

```
The following data will be saved under this path.

```
.
|__ BUILD_CEPH_RECORD # Build records, such as "2019-08-29 15:05.35 build ceph | tag : [ nautilus-14.2.2.0001 ]"
|__ log
|   |__ nautilus-14.2.2.0001.log # The logs of building image
|__ TAG_CEPH_NUMBER   # Record the serial number of the last automatic build image tag
```

- Build script options

```
Usage: sh build.sh [options]

Options:
    --tag, -t <image_tag>              (Optional) Specify tag for docker images
    --help, -h                         (Optional) Show this usage information

```

- Build image

```
sh build.sh
```

``Note: Build the image by default with (ceph version)-(ceph release).(serial number) as the image tag, for example nautilus-14.2.2.0001.``

- Build the image using the specified tag

```
sh build.sh --tag test.0001
```

## Ceph cluster management

### Create a ceph cluster configuration

- Create a folder corresponding to the cluster

```
|__ ceph-env
|   |__test
|       |__ ceph.conf
|       |__ globals.yml
|       |__ inventory

```
You need to create a folder in ceph-env and refer to the cluster by the name of the folder.

- Edit ceph configuration file

```
[global]
rbd_default_features = 1
public_network = 192.168.10.0/24
cluster_network = 192.168.10.0/24
osd_pool_default_size = 3
osd_pool_default_min_size = 2
osd_class_update_on_start = false
```

- Edit globals.yml

```
####################
# Docker options
####################
### Example: Private repository with authentication

docker_registry: "192.168.10.11:4000"
docker_namespace: "kolla-ceph"

# Valid options are [ never, on-failure, always, unless-stopped ]
docker_restart_policy: "always"
docker_registry_username: ""

###################
# Ceph options
###################
ceph_pool_pg_num: 32
ceph_pool_pgp_num: 32

osd_initial_weight: "auto"

# Set the store type for ceph OSD
# Valid options are [ filestore, bluestore]
ceph_osd_store_type: "bluestore"

ceph_cluster_fsid: "4a9e463a-4853-4237-a5c5-9ae9d25bacda"
```

Please modify the docker registry information and ceph_cluster_fsid.

- Edit invertory

```
# api_interface: NIC used by other services
# storage_interface: NIC used by ceph public_network
# cluster_interface: NIC used by ceph cluster_network
[mons]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0
ceph-node2 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0
ceph-node3 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0


# device_class: Specify device-class corresponding to osd, one node supports one device-class
[osds]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0 device_class=hdd
ceph-node2 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0 device_class=hdd
ceph-node3 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0 device_class=hdd

[rgws]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0

[mgrs]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0

[mdss]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0

[nfss]

[ceph-mon:children]
mons

[ceph-rgw:children]
rgws

[ceph-osd:children]
osds

[ceph-mgr:children]
mgrs

[ceph-mds:children]
mdss

[ceph-nfs:children]
nfss

```

### Prepare osd disk

In kolla-ceph, all osd disks need to be labeled. The same osd disk prefix is the same, different suffixes represent different disk usage.

#### bluestore

- Disk name description

```
KOLLA_CEPH_OSD_BOOTSTRAP_BS_${OSD_NAME}_${OSD_DISK_SUFFIXES}

Examples:
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_B
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_D
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_W
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1

The following are the different meanings of the suffix.
(B) : OSD Block Partition
(D) : OSD DB Partition
(W) : OSD WAL Partition
(null) : In the deployment of kolla-ceph, a 100M partition is needed to save the data needed for osd startup, so it is called osd data partition. If there is a separate block partition, then this partition only represents osd data, otherwise it represents 100M data partition and the rest will be used as a block partition
```

- how to preapare disk

```
sudo sgdisk --zap-all -- /dev/sdb
sudo sgdisk --zap-all -- /dev/sdc
sudo sgdisk --zap-all -- /dev/sdd

# Use the entire disk, including the osd data partition and the block partition
sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1  1 -1

# Customize multiple partitions
sudo /sbin/parted /dev/sdb -s -- mklabel  gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1 1 100
sudo /sbin/parted /dev/sdb -s mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_B 101 100%
sudo /sbin/parted /dev/sdc -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_D 1 2000
sudo /sbin/parted /dev/sdd -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_W 1 2000
```

#### Filestore

- Disk name description

```
KOLLA_CEPH_OSD_BOOTSTRAP_${OSD_NAME}_${OSD_DISK_SUFFIXES}

Examples:
KOLLA_CEPH_OSD_BOOTSTRAP_FOO1_J
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1

The following are the different meanings of the suffix.
(J) : OSD Journal Partition
(null) : If there is a separate Journal partition, then this partition only represents osd data, otherwise it represents 5G Journal partition and the rest will be used as a data partition
```

- how to preapare disk

```
sudo sgdisk --zap-all -- /dev/sdb
sudo sgdisk --zap-all -- /dev/sdc

# Use the entire disk, including the osd data partition and the journal partition
sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_FOO1  1 -1

# Customize multiple partitions
parted  /dev/sdb -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_FOO1  1  -1
parted  /dev/sdc -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_FOO1_J  1  5000
```

### Deploy a ceph cluster

- Manage script options

```
Usage: sh manage.sh COMMAND [options]

Options:
    --help, -h                         (Optional) Show this usage information
    --image, <images tag>              (Required) Specify images tag to be deployed
    --limit <host>                     (Optional) Specify host to run plays
    --forks <forks>                    (Optional) Number of forks to run Ansible with
    --daemon <ceph-daemon>             (Optional) Specify ceph daemon to be installed, default is all,[ceph-mon,ceph-mgr,ceph-osd,ceph-rgw,ceph-mds]
    --cluster <ceph-cluster-name>      (Required) Specifies the name of the ceph cluster to deploy, which should be placed in the ceph-env folder
    --skip-pull                        (Optional) Whether to skip pulling the image
    --verbose, -v                      (Optional) Increase verbosity of ansible-playbook

Commands:
    deploy              Deploy Ceph cluster, also to fix daemons and update configurations
    reconfigure         Reconfigure Ceph service
    stop                Stop Ceph containers
    upgrade             Upgrades existing Ceph Environment

```

- Deploy the ceph cluster with the specified image tag

```
sh manage.sh deploy --cluster test --image nautilus.0001
```

- You can also deploy only one service or a few, such as following:

```
sh manage.sh deploy --cluster test --image nautilus.0001 --daemon ceph-osd

sh manage.sh deploy --cluster test --image nautilus.0001 --daemon ceph-osd,ceph-rgw
```

``Note: "--daemon" Recommended for maintenance of existing clusters``

- You can modify a service on a node, such as repairing a damaged osd on a node.

```
sh manage.sh deploy --cluster test --image nautilus.0011 --daemon ceph-osd --limit ceph-node3
```
