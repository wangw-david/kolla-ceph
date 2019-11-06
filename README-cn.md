# kolla-ceph : 一个ceph容器化部署编排项目

github: https://github.com/wangw-david/kolla-ceph

## 起源

这个项目中的部分代码来自于kolla和kolla-ansible, 而kolla和kolla-ansible是openstack的容器化部署项目, 包含了ceph和其他openstack组件的部署, 但是因为ceph部署的复杂性, 社区决定不再开发ceph部署和管理的相关的大的feature, 只对现有的部署进行维护, 并逐渐废弃对ceph部署的支持.

```
Support for deploying Ceph via Kolla Ansible is deprecated. In a future
release support for deploying Ceph will be removed from Kolla Ansible. Prior
to this we will ensure a migration path to another tool such as Ceph
Ansible (http://docs.ceph.com/ceph-ansible/master/>) is available. For new
deployments it is recommended to use another tool to deploy Ceph to avoid a
future migration. This can be integrated with OpenStack by following the
external Ceph guide
(https://docs.openstack.org/kolla-ansible/latest/reference/storage/external-ceph-guide.html).
```

但是作为一个一直使用kolla来部署ceph集群的人, 我觉得放弃对ceph部署的支持太可惜了, 在容器的编排部署上, kolla有一套很成熟的体系:

 1. 镜像的构建很方便
 2. 与docker的交互很方便, 社区自己开发的ansible脚本可以方便的操作docker容器, 包括比较, 删除, 创建等.
 3. 使用ansible可以方便流程化部署和定制化部署
 4. 在ceph的部署上, 社区设计的流程是给磁盘打上标签, 然后osd初始化过程中先bootstrap, 再启用osd, 不同的osd容器挂载独立的磁盘, 部署和维护都特别方便.

基于以上的优点, 我决定在社区版本的基础上进行二次开发, 将我在日常使用中遇到的一些问题, 和一些新特性的支持, 提交上去, 于是有了这个kolla-ceph的项目.

主要改进如下:

    1. 精简代码只保留与ceph相关的, 并用shell脚本进行操作, 简化流程
    2. 修复了一些bug(之前已经提交了一些bug修复到社区版本)
    3. 添加了一些新的特性, 比如指定ceph daemon进行部署, 设置device class等
    4. 添加了对lvm方式部署ceph osd的支持(类似于ceph-volume)
    5. 添加了对多路径磁盘和bcache磁盘的部署支持 
    6. 对ceph部署进行了重构, 使用了ansible handler, 对部署和升级不同场景的下的流程进行了区别, 更安全的部署和升级.
    

## 使用

整个kolla-ceph的文件夹结构如下:

```
.
├── ansible # 部署相关ansible任务
├── build.sh # 构建镜像的shell脚本
├── ceph-build.conf # 构建相关配置
├── ceph-env # 要部署的集群的相关配置
├── docker # dockerfile文件等
├── kolla  # kolla的构建镜像的python脚本
├── LICENSE
├── manage.sh # 部署及修复, 升级的shell脚本
├── NOTICE
├── README.md
└── requirements.txt

```

### 构建镜像

- 构建镜像需要修改ceph-build.conf

```
[DEFAULT]
base = centos
type = binary

profile = image_ceph

registry =
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
需要配置的地方主要就是registry, 然后ceph的version和release, version的选项有``luminous, mimic, nautilus``, release对应的每个version的release号. 配置后安装的ceph版本和指定的版本一致.

- 构建记录

利用build.sh可以自动构建镜像, 不过build.sh会需要一个文件路径来存储相关的构建信息, 默认是以下路径:

```
BUILD_DATA_PATH="/home/kolla-ceph"

```
该路径下保存以下文件:

```
.
├── BUILD_CEPH_RECORD
├── log
│   ├── build-nautilus-14.2.2.0001.log
│   ├── build-nautilus-14.2.2.0002.log
│   └── build-test.0001.log
└── TAG_CEPH_NUMBER

```

BUILD_CEPH_RECORD保存的是构建每个镜像的时间

```
2019-10-23 19:22.58 build ceph | tag : [ nautilus-14.2.2.0001 ]
2019-10-25 11:53.38 build ceph | tag : [ nautilus-14.2.2.0002 ]
```

TAG_CEPH_NUMBER 保存的是上一次构建成功的序列号, 下一次自动构建会在此基础上加1.

log中是每次构建的输出日志.

 
- 构建脚本

可以指定tag, 也可以不指定, 默认是(ceph version)-(ceph release).(serial number), 比如 nautilus-14.2.2.0001

```
Usage: sh build.sh [options]

Options:
    --tag, -t <image_tag>              (Optional) Specify tag for docker images
    --help, -h                         (Optional) Show this usage information

```

自动构建

```
sh build.sh
```

指定tag构建

```
sh build.sh --tag test.0001
```

### 部署和管理集群

#### 磁盘初始化

目前kolla-ceph中支持两种模式的osd初始化, disk模式(类似于ceph-disk)和lvm模式(类似于ceph-volume), 每种模式都支持bulestore和filestore的部署, 以下会详细讲解如何初始化磁盘.

##### disk模式

- bluestore

bluestore如果用disk模式的话, 一个osd最多有四个磁盘分区, 100M左右的osd data分区, 用来保存osd启动所需要的数据; block分区, 承载数据的分区; db分区, 用来保存rocksdb的数据和元数据; wal分区, 用来保存rocksdb的日志文件.
在kolla-ceph中, 所有分区以后缀来区别, bluestore DISK模式前缀中有个``_BS``:

```
KOLLA_CEPH_OSD_BOOTSTRAP_BS_${OSD_NAME}_${OSD_DISK_SUFFIXES}

例如:
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_B(FOO1代表同一个osd,B代表block分区)
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_D(FOO1代表同一个osd,D代表db分区)
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_W(FOO1代表同一个osd,W代表wal分区)
KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1(FOO1代表同一个osd,无后缀代表osd data分区)
KOLLA_CEPH_OSD_BOOTSTRAP_BS(没有osd名和后缀, 默认代表一个osd, 会被自动分为osd data分区和block分区)

以下是后缀意义:
(B) : OSD Block Partition
(D) : OSD DB Partition
(W) : OSD WAL Partition
(null) : 在kolla ceph中, 如果一个分区没有后缀, 有两种情况: 1. 没有对应的block分区, 那么这个分区会被自动初始化为两个分区, osd data分区和block分区; 2. 如果这个osd已经有_B后缀的block分区, 那这个没有后缀的分区会被用来做osd data分区.
```

初始化磁盘

```
# 清除原有分区
sudo sgdisk --zap-all -- /dev/sdb
sudo sgdisk --zap-all -- /dev/sdc
sudo sgdisk --zap-all -- /dev/sdd

# 简单初始化, 无后缀
sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1  1 -1

# 自定义多个分区
sudo /sbin/parted /dev/sdb -s -- mklabel  gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1 1 100
sudo /sbin/parted /dev/sdb -s mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_B 101 100%
sudo /sbin/parted /dev/sdc -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_D 1 2000
sudo /sbin/parted /dev/sdd -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_W 1 2000
```
- filestore

disk模式下filestore一个osd有两个磁盘分区, osd data分区(保存osd启动数据和存储数据), journal(日志分区)

```
KOLLA_CEPH_OSD_BOOTSTRAP_${OSD_NAME}_${OSD_DISK_SUFFIXES}

例如:
KOLLA_CEPH_OSD_BOOTSTRAP_FOO1_J(日志分区)
KOLLA_CEPH_OSD_BOOTSTRAP_FOO1(data分区)
KOLLA_CEPH_OSD_BOOTSTRAP(无后缀会默认划分为data分区和5G的日志分区)

以下是后缀意义:
(J) : OSD Journal Partition
(null) : 如果无后缀, 当osd有对应的journal分区的时候, 该分区只代表data分区, 如果没有额外的journal分区, 那么该分区会自动划分为data分区和5G的日志分区
```

初始化磁盘:

```
# 清除旧的分区
sudo sgdisk --zap-all -- /dev/sdb
sudo sgdisk --zap-all -- /dev/sdc

# 简易初始化, 无后缀
sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_FOO1  1 -1

# 自定义磁盘分区
parted  /dev/sdb -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_FOO1  1  -1
parted  /dev/sdc -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_FOO1_J  1  5000
```

##### LVM模式

- bluestore

LVM模式跟DISK模式的不同在于, LVM模式下, osd data分区是从tmpfs中挂载出来的一个分区, 而block分区则是一个虚拟卷, wal分区和db分区则依旧可以是原始分区. bluestore LVM模式前缀中有个``_BSL``:

```
KOLLA_CEPH_OSD_BOOTSTRAP_BSL_${OSD_NAME}_${OSD_DISK_SUFFIXES}

例如:
KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1_B
KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1_D
KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1_W
KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1 (无后缀代表block分区, 会被初始化成虚拟卷)
KOLLA_CEPH_OSD_BOOTSTRAP_BSL(无osd名, 无后缀代表一个osd)

后缀代表:
(B) : OSD Block Partition
(D) : OSD DB Partition
(W) : OSD WAL Partition
(null) : 在lvm模式下, 无后缀整个分区会被用于block分区的虚拟卷
```

初始化磁盘

```
sudo sgdisk --zap-all -- /dev/sdb
sudo sgdisk --zap-all -- /dev/sdc
sudo sgdisk --zap-all -- /dev/sdd

# 简易初始化
sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1  1 -1

# 自定义磁盘分区
# 以下两种都代表block分区
sudo /sbin/parted /dev/sdb -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1 1 100%
或者
sudo /sbin/parted /dev/sdb -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1_B 1 100%

sudo /sbin/parted /dev/sdc -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1_D 1 2000
sudo /sbin/parted /dev/sdd -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BSL_FOO1_W 1 2000
```

##### Filestore

LVM模式下filestore的osd data分区会被初始化成虚拟卷, 而journal盘依旧可以是原始分区.

```
KOLLA_CEPH_OSD_BOOTSTRAP_L_${OSD_NAME}_${OSD_DISK_SUFFIXES}

例如:
KOLLA_CEPH_OSD_BOOTSTRAP_L_FOO1_J
KOLLA_CEPH_OSD_BOOTSTRAP_L_FOO1(无后缀代表osd data分区)
KOLLA_CEPH_OSD_BOOTSTRAP_L(简易初始化, 整个磁盘会被分为5G的journal分区和osd data分区)
以下是后缀意义:
(J) : OSD Journal Partition
(null) : 当没有单独的journal分区的时候, 这个分区会被初始化成5G的journal分区. 当有journal分区的时候, 这个分区只是代表osd data分区, 与disk模式最大的不同在于, osd data分区会被创建成虚拟卷.
```

磁盘初始化

```
sudo sgdisk --zap-all -- /dev/sdb
sudo sgdisk --zap-all -- /dev/sdc

# 简易初始化
sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_L_FOO1  1 -1

# 自定义初始化
parted  /dev/sdb -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_L_FOO1  1  -1
parted  /dev/sdc -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP_L_FOO1_J  1  5000
```
    
#### 部署新的集群

举例如下:

|    node    | usage | disk | 
| ---------- | --- | --- |
| ceph-node1 |  mon, mgr, osd, rgw | sdb, sdc, sdd|
| ceph-node2 |  mon, mgr, mds, osd | sdb, sdc, sdd|
| ceph-node3 |  mds, osd | sdb, sdc, sdd|


##### 创建配置文件

当我们要部署一个新的集群, 我们需要在``ceph-env``路径下创建一个文件夹, 文件夹名代表集群的名字, 比如test:

```
.
└── test
    ├── ceph.conf
    ├── globals.yml
    └── inventory

```
其中, ``ceph.conf``是ceph配置中需要自定义的部分; globals.yml是该集群部署需要的配置, 默认使用all.yml中的配置; inventory是该集群的节点配置.

- 例如ceph.conf
```
[global]
rbd_default_features = 1
public_network = 192.168.10.0/24 (必须)
cluster_network = 192.168.10.0/24 (必须)
osd_pool_default_size = 2
osd_pool_default_min_size = 1
osd_class_update_on_start = false
mon_max_pg_per_osd = 500
mon_allow_pool_delete = true

[mon]
mon_warn_on_legacy_crush_tunables = false
mon_keyvaluedb = rocksdb
mon_health_preluminous_compat = false
mon_health_preluminous_compat_warning = false

[client]
rbd_cache = True
rbd_cache_writethrough_until_flush = True
```
- globals.yml

```
---
####################
# Docker options
####################
### Example: Private repository with authentication

docker_registry: "192.168.10.11:4000" (必须)
docker_namespace: "kolla-ceph" (必须) # 与 ceph-build.conf 中的配置一致

# Valid options are [ never, on-failure, always, unless-stopped ]
docker_restart_policy: "always"
docker_registry_username: ""
docker_registry_password: ""

###################
# Ceph options
###################
ceph_pool_pg_num: 32
ceph_pool_pgp_num: 32

osd_initial_weight: "auto"
ceph_cluster_fsid: "4a9e463a-4853-4237-a5c5-9ae9d25bacda" (必须)
```

- inventory

```
# api_interface: NIC used by other services
# storage_interface: NIC used by ceph public_network
# cluster_interface: NIC used by ceph cluster_network
# device_class: Specify device-class corresponding to osd, one node supports one device-class
[mons]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0
ceph-node2 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0

[osds]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0 device_class=hdd
ceph-node2 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0 device_class=hdd
ceph-node3 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0 device_class=hdd

[rgws]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0

[mgrs]
ceph-node1 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0
ceph-node2 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0

[mdss]
ceph-node2 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0
ceph-node3 ansible_user=root api_interface=eth0 storage_interface=eth0 cluster_interface=eth0

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

##### 初始化磁盘示例:

```
sudo sgdisk --zap-all -- /dev/sdb
sudo sgdisk --zap-all -- /dev/sdc
sudo sgdisk --zap-all -- /dev/sdd

# bluestore disk 模式简易初始化
#sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS  1 -1
#sudo /sbin/parted  /dev/sdc  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS  1 -1
#sudo /sbin/parted  /dev/sdd  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS  1 -1

# bulestore lvm 模式简易初始化
sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BSL  1 -1
sudo /sbin/parted  /dev/sdc  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BSL  1 -1
sudo /sbin/parted  /dev/sdd  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BSL  1 -1

# bluestore disk 模式自定义
#sudo /sbin/parted  /dev/sdb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1  1 1000
#sudo /sbin/parted  /dev/sdb  -s  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_B  1001 100%
#sudo /sbin/parted  /dev/sdc  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_W  1  25000
#sudo /sbin/parted  /dev/sdc  -s  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1_D  25001 100%

# 多路径磁盘初始化
#sudo sgdisk --zap-all -- /dev/mapper/mpathc
#sudo sgdisk --zap-all -- /dev/mapper/mpathb

#sudo /sbin/parted  /dev/mapper/mpathb  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1  1 -1
#sudo /sbin/parted  /dev/mapper/mpathc  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO2  1 -1

# bcache 磁盘初始化
#sudo sgdisk --zap-all -- /dev/bcache0
#sudo sgdisk --zap-all -- /dev/bcache1
#sudo /sbin/parted  /dev/bcache0  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO1  1 -1
#sudo /sbin/parted  /dev/bcache1  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS_FOO2  1 -1

```

##### 部署脚本

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
    upgrade             Upgrades existing Ceph Environment(Upgrades are limited to one by one, but there can be multiple daemons on a node,
                        so please specify some daemons name, it is recommended to upgrade only one daemon at a time.)
```

下面根据一些场景说一下具体如何使用部署脚本.

- 部署新的ceph集群

需要指定镜像的tag和集群的名称

```
sh manage.sh deploy --cluster test --image nautilus-14.2.2.0001
```

- 修复损坏的osd

比如osd.0损坏, 首先清除旧的磁盘

```
# docker stop ceph_osd_0 && docker rm ceph_osd_0

# fdisk -l

Disk /dev/sdd: 53.7 GB, 53687091200 bytes, 104857600 sectors
Units = sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disk label type: gpt
Disk identifier: 3EB2FAA8-2270-48A4-841E-1E857700D28F


#         Start          End    Size  Type            Name
 1         2048       206847    100M  unknown         KOLLA_CEPH_DATA_BS_0
 2       206848    104857566   49.9G  unknown         KOLLA_CEPH_DATA_BS_0_B

# df -h
/dev/sdd1                 97M  5.4M   92M   6% /var/lib/ceph/osd/81493f61-ce76-49bb-a27c-fa2c09d9d6c7

# umount /var/lib/ceph/osd/81493f61-ce76-49bb-a27c-fa2c09d9d6c

# sudo sgdisk --zap-all -- /dev/sdd

# sudo /sbin/parted  /dev/sdd  -s  -- mklabel  gpt  mkpart KOLLA_CEPH_OSD_BOOTSTRAP_BS  1 -1
```

添加以下在globals.yml中, 这样就不会影响到正在运行的容器, 当配置或者镜像改变时, 依旧不会影响正在运行的容器.
```
ceph_container_running_restart: "no"
```
损坏的osd在node1, 所以我们只需要在ceph-node运行(--limit ceph-node1); 然后只需要部署osd, 不需要其他的ceph组件(--daemon ceph-osd); 也不需要再拉取镜像, 跳过pull来节省时间(--skip-pull):

```
sh manage.sh deploy --cluster test --image nautilus-14.2.2.0001 --daemon ceph-osd --limit ceph-node1 --skip-pull
```
其他的组件修改也是一样, 可以用--daemon来限定

- 升级ceph的镜像或者版本

用容器部署的ceph集群, 最方便的就是升级版本, 我们可以一个容器一个容器的进行修改. 在我们再构建一个镜像nautilus-14.2.2.0002, 然后模拟版本升级.

整个升级流程是串行的, 串行是脚本在upgrade action时自动设置的, 即先升级一个节点上的容器, 再升级下一个节点, 如果你想让同一组件先升级, 需要用--daemon来限定升级的组件.

下面这个参数可以打开ceph状态检测, 当升级下一个容器时, 会先检测集群状态, 当状态为``health_ok``时进行升级. 当然, 需要在升级之前让ceph集群状态为``health_ok``.
```
enable_upgrade_health_check: "no"
```

1. 首先我们需要升级mon, mon只能单独指定升级, 不能和其他组件一起升级

```
sh manage.sh upgrade  --cluster test --image nautilus-14.2.2.0002 --daemon ceph-mon

```
2. 升级其他组件可以一起升级, 也可以单独升级

```
sh manage.sh upgrade  --cluster test --image nautilus-14.2.2.0020 --daemon ceph-osd,ceph-mgr
```

- 创建pool

可以在globals.yml中重新定义要创建的pool, 可直接在rule中指定device class, 就会限定pool所在的osd:

```
定义一个pool需要以下的项, 一般只需要必填项就可以了:

 +----------------------+---------------------------------------------------+
 | item name            | required                                          |
 +======================+===================================================+
 | pool_name            | Required                                          |
 +----------------------+---------------------------------------------------+
 | pool_type            | Required                                          |
 +----------------------+---------------------------------------------------+
 | pool_pg_num          | Required                                          |
 +----------------------+---------------------------------------------------+
 | pool_pgp_num         | Required                                          |
 +----------------------+---------------------------------------------------+
 | pool_erasure_name    | Optional, required when pool_type is erasure      |
 +----------------------+---------------------------------------------------+
 | pool_erasure_profile | Optional, required when pool_type is erasure      |
 +----------------------+---------------------------------------------------+
 | pool_rule_name       | Optional, required when pool_type is replicated   |
 +----------------------+---------------------------------------------------+
 | pool_rule            | Optional, required when pool_type is replicated   |
 +----------------------+---------------------------------------------------+
 | pool_cache_enable    | Optional, default is false                        |
 +----------------------+---------------------------------------------------+
 | pool_cache_mode      | Optional, required when pool_cache_enable is true |
 +----------------------+---------------------------------------------------+
 | pool_cache_rule_name | Optional, required when pool_cache_enable is true |
 +----------------------+---------------------------------------------------+
 | pool_cache_rule      | Optional, required when pool_cache_enable is true |
 +----------------------+---------------------------------------------------+
 | pool_cache_pg_num    | Optional, required when pool_cache_enable is true |
 +----------------------+---------------------------------------------------+
 | pool_cache_pgp_num   | Optional, required when pool_cache_enable is true |
 +----------------------+---------------------------------------------------+
 | pool_application     | Required                                          |
 +----------------------+---------------------------------------------------+

```
例如:

```
ceph_pools:
  - pool_name: "rbd"
    pool_type: "replicated"
    pool_rule_name: "hdd-rep"
    pool_rule: "default host hdd"
    pool_pg_num: 32
    pool_pgp_num: 32
    pool_application: "rbd"
    create: "yes"
  - pool_name: "rbd-ec"
    pool_type: "erasure"
    pool_erasure_name: "hdd-ec"
    pool_erasure_profile: "k=2 m=1 crush-failure-domain=osd crush-device-class=hdd"
    pool_pg_num: 32
    pool_pgp_num: 32
    pool_application: "rbd"
    create: "yes"
```
在ceph的部署中会自动创建对应的规则和pool.

- 修改ceph的配置

启用以下参数, 然后自动以one by one的方式去更新配置文件并重启容器. 流程与升级一样.
```
ceph_conf_change_restart: "yes"
```

执行命令
```
sh manage.sh reconfigure --cluster test --image nautilus-14.2.2.0001
```

reconfigure和upgrade不同之处在于, reconfigure只有在配置改变时才会重启容器, 当镜像或容器的环境变量改变时会跳过, 不会重新创建新的容器.reconfigure不需要强制指定daemon.


##### 清除旧的集群

```
#!/bin/bash
docker stop $(docker ps -a -q) && docker rm $(docker ps -a -q)
sudo rm  -rf  /etc/kolla-ceph/*

sudo docker  volume  rm  ceph_mon  ceph_mon_config kolla_ceph_logs

sudo  umount -l  /var/lib/ceph/osd/*

sudo sed -i '/\/var\/lib\/ceph\/osd/d' /etc/fstab
sudo  rm  -rf  /var/lib/ceph

systemctl daemon-reload
# disk mode
sudo sgdisk --zap-all -- /dev/sdb
sudo sgdisk --zap-all -- /dev/sdc
sudo sgdisk --zap-all -- /dev/sdd

# lvm mode
vgremove -y $(vgs | grep "ceph-" | awk '{print $1}')
pvremove /dev/sdb1 /dev/sdc1 /dev/sdd1
```