#!/bin/bash

# There are many variables in this script. To distinguish, the environment
# variables of the container are not prefixed. The prefix of the variable
# defined in this script is added with "L_" (means local).

if [[ ! -d "/var/log/kolla-ceph/ceph" ]]; then
    mkdir -p /var/log/kolla-ceph/ceph
fi
if [[ $(stat -c %a /var/log/kolla-ceph/ceph) != "755" ]]; then
    chmod 755 /var/log/kolla-ceph/ceph
fi

# NOTE(SamYaple): Static gpt partcodes
L_REGULAR_OSD_TYPE_CODE="4fbd7e29-9d25-41b8-afd0-062c0ceff05d"
L_REGULAR_JOURNAL_TYPE_CODE="45b0969e-9b03-4f30-b4c6-b4b80ceff106"
L_REGULAR_BLOCK_TYPE_CODE="cafecafe-9b03-4f30-b4c6-b4b80ceff106"
L_REGULAR_WAL_TYPE_CODE="5ce17fce-4087-4169-b7ff-056cc58473f9"
L_REGULAR_DB_TYPE_CODE="30cd0809-c2b2-499c-8879-2d6b78529876"

L_MPATH_OSD_TYPE_CODE="4fbd7e29-8ae0-4982-bf9d-5a8d867af560"
L_MPATH_JOURNAL_TYPE_CODE="45b0969e-8ae0-4982-bf9d-5a8d867af560"
L_MPATH_BLOCK_TYPE_CODE="cafecafe-8ae0-4982-bf9d-5a8d867af560"
L_MPATH_WAL_TYPE_CODE="01b41e1b-002a-453c-9f17-88793989ff8f"
L_MPATH_DB_TYPE_CODE="ec6d6385-e346-45dc-be91-da2a7c8b3261"

# Inform the os about partition table changes
function partprobe_device {
    local device=$1
    udevadm settle --timeout=600
    flock -s ${device} partprobe ${device}
    udevadm settle --timeout=600
}

# In some cases, the disk partition will not appear immediately, so check every
# 1s, try up to 10 times. In general, this interval is enough.
function wait_partition_appear {
    local dev_part=$1
    local part_name=$(echo ${dev_part} | awk -F '/' '{print $NF}')
    for(( i=1; i<11; i++ )); do
        flag=$(ls /dev | awk '/'"${part_name}"'/{print $0}' | wc -l)
        if [[ "${flag}" -eq 0 ]]; then
            echo "sleep 1 waits for the partition ${dev_part} to appear: ${i}"
            sleep 1
        else
            return 0
        fi
    done
    echo "The device /dev/${dev_part} does not appear within the limited time 10s."
    exit 1
}


# Update the uuid corresponding to the partition, otherwise the uuid of
# multipath disks will change after the host reboot.
function trigger_part_uuid {
    local dev_part=$1
    udevadm control --reload || true
    udevadm trigger "${dev_part}" || true
}

# For multipath disks, after changing the typecode, the corresponding path
# change will be delayed by 1 second or more.
function wait_device_link_appear {
    local dev_path=$1
    local dev_uuid=$2
    local dev_part=$3
    for(( i=0; i<10; i++ )); do
        trigger_part_uuid "${dev_part}"
        flag=$(ls $dev_path | awk '/'"$dev_uuid"'/{print $0}' | wc -l)
        if [[ "${flag}" -eq 0 ]]; then
            sleep 1
        else
            return 0
        fi
    done
    echo "The device $dev_path/${dev_uuid} does not appear in the correct path."
    exit 1
}

function divide_filestore_osd_partition {
    OSD_PARTUUID=$(uuidgen)
    JOURNAL_PARTUUID=$(uuidgen)
    # Formatting disk for ceph
    sgdisk --zap-all -- "${OSD_DEV}"
    sgdisk --new=2:0:+5120M --partition-guid=2:"${JOURNAL_PARTUUID}" --mbrtogpt -- "${OSD_DEV}"
    sgdisk --largest-new=1 --partition-guid=1:"${OSD_PARTUUID}" --mbrtogpt -- "${OSD_DEV}"
    partprobe_device "${OSD_DEV}"
}

function divide_bluestore_osd_partition {
    OSD_PARTUUID=$(uuidgen)
    BLOCK_PARTUUID=$(uuidgen)
    sgdisk --zap-all -- "${OSD_DEV}"
    sgdisk --new=1:0:+100M --partition-guid=1:"${OSD_PARTUUID}" --mbrtogpt -- "${OSD_DEV}"
    sgdisk --largest-new=2 --partition-guid=2:"${BLOCK_PARTUUID}" --mbrtogpt -- "${OSD_DEV}"
    partprobe_device "${OSD_DEV}"
}

function init_osd_data_part {
    wait_partition_appear "${OSD_PARTITION}"
    sgdisk --zap-all -- "${OSD_PARTITION}"
    if [[ "${OSD_PARTTYPE}" == "mpath" ]]; then
        L_CEPH_OSD_TYPE_CODE="${L_MPATH_OSD_TYPE_CODE}"
    else
        L_CEPH_OSD_TYPE_CODE="${L_REGULAR_OSD_TYPE_CODE}"
    fi
}

function init_journal_part {
    wait_partition_appear "${JOURNAL_PARTITION}"
    sgdisk --zap-all -- "${JOURNAL_PARTITION}"
    if [[ "${JOURNAL_PARTTYPE}" == "mpath" ]]; then
        L_CEPH_JOURNAL_TYPE_CODE="${L_MPATH_JOURNAL_TYPE_CODE}"
        L_JOURNAL_LINK_PATH=/dev/disk/by-parttypeuuid
        L_JOURNAL_LINK_UUID="${L_CEPH_JOURNAL_TYPE_CODE}"."${JOURNAL_PARTUUID}"
    else
        L_CEPH_JOURNAL_TYPE_CODE="${L_REGULAR_JOURNAL_TYPE_CODE}"
        L_JOURNAL_LINK_PATH=/dev/disk/by-partuuid
        L_JOURNAL_LINK_UUID="${JOURNAL_PARTUUID}"
    fi
    L_JOURNAL_BOOT_PATH="${L_JOURNAL_LINK_PATH}"/"${L_JOURNAL_LINK_UUID}"
}

function init_block_part {
    wait_partition_appear "${BLOCK_PARTITION}"
    sgdisk --zap-all -- "${BLOCK_PARTITION}"
    if [[ "${BLOCK_PARTTYPE}" == "mpath" ]]; then
        L_CEPH_BLOCK_TYPE_CODE="${L_MPATH_BLOCK_TYPE_CODE}"
        L_BLOCK_LINK_PATH=/dev/disk/by-parttypeuuid
        L_BLOCK_LINK_UUID="${L_CEPH_BLOCK_TYPE_CODE}"."${BLOCK_PARTUUID}"
    else
        L_CEPH_BLOCK_TYPE_CODE="${L_REGULAR_BLOCK_TYPE_CODE}"
        L_BLOCK_LINK_PATH=/dev/disk/by-partuuid
        L_BLOCK_LINK_UUID="${BLOCK_PARTUUID}"
    fi
    L_BLOCK_BOOT_PATH="${L_BLOCK_LINK_PATH}"/"${L_BLOCK_LINK_UUID}"
}

function init_wal_part {
    sgdisk --zap-all -- "${WAL_PARTITION}"
    L_CHECK_WAL_DEVICE="True"
    if [[ "${WAL_PARTTYPE}" == "mpath" ]]; then
        L_CEPH_WAL_TYPE_CODE="${L_MPATH_WAL_TYPE_CODE}"
        L_WAL_LINK_PATH=/dev/disk/by-parttypeuuid
        L_WAL_LINK_UUID="${L_CEPH_WAL_TYPE_CODE}"."${WAL_PARTUUID}"
    else
        L_CEPH_WAL_TYPE_CODE="${L_REGULAR_WAL_TYPE_CODE}"
        L_WAL_LINK_PATH=/dev/disk/by-partuuid
        L_WAL_LINK_UUID="${WAL_PARTUUID}"
    fi
    L_WAL_BOOT_PATH="${L_WAL_LINK_PATH}"/"${L_WAL_LINK_UUID}"
}

function init_db_part {
    sgdisk --zap-all -- "${DB_PARTITION}"
    L_CHECK_DB_DEVICE="True"
    if [[ "${DB_PARTTYPE}" == "mpath" ]]; then
        L_CEPH_DB_TYPE_CODE="${L_MPATH_DB_TYPE_CODE}"
        L_DB_LINK_PATH=/dev/disk/by-parttypeuuid
        L_DB_LINK_UUID="${L_CEPH_DB_TYPE_CODE}"."${DB_PARTUUID}"
    else
        L_CEPH_DB_TYPE_CODE="${L_REGULAR_DB_TYPE_CODE}"
        L_DB_LINK_PATH=/dev/disk/by-partuuid
        L_DB_LINK_UUID="${DB_PARTUUID}"
    fi
    L_DB_BOOT_PATH="${L_DB_LINK_PATH}"/"${L_DB_LINK_UUID}"
}

function get_osd_id {
    L_OSD_KEYRING=$(ceph-authtool --gen-print-key)
    L_OSD_TMP_KEY="/var/lib/ceph/tmp/keyring"
    echo "${L_OSD_KEYRING}" > "${L_OSD_TMP_KEY}"
    L_OSD_ID=$(ceph osd new "${OSD_PARTUUID}" -i "${L_OSD_TMP_KEY}")
}

function get_osd_keyring {
    ceph-authtool "${L_OSD_DIR}/keyring" --create-keyring --name osd.${L_OSD_ID} --add-key "${L_OSD_KEYRING}"
    ceph auth add osd.${L_OSD_ID} osd 'allow *' mon 'allow profile osd' -i "${L_OSD_DIR}/keyring"
}

function get_mon_map {
    L_MON_MAP="${L_OSD_DIR}/activate.monmap"
    ceph mon getmap -o "${L_MON_MAP}"
}

function change_wal_part_name {
    local wal_prefix=$1
    sgdisk "--change-name=${WAL_PARTNUM}:"${wal_prefix}"_${L_OSD_ID}_W" "--typecode=${WAL_PARTNUM}:${L_CEPH_WAL_TYPE_CODE}" -- "${WAL_DEV}"
    partprobe_device "${WAL_DEV}"
    L_CHANGE_WAL_NAME="True"
}

function change_db_part_name {
    local db_prefix=$1
    sgdisk "--change-name=${DB_PARTNUM}:"${db_prefix}"_${L_OSD_ID}_D" "--typecode=${DB_PARTNUM}:${L_CEPH_DB_TYPE_CODE}" -- "${DB_DEV}"
    partprobe_device "${DB_DEV}"
    L_CHANGE_DB_NAME="True"
}

function prepare_osd_lvm {
    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        sgdisk --zap-all -- "${OSD_PARTITION}"
        if [[ -n "${WAL_DEV}" && "${OSD_DEV}" != "${WAL_DEV}" && -n "${WAL_PARTITION}" ]]; then
            init_wal_part
        fi

        if [[ -n "${DB_DEV}" && "${OSD_DEV}" != "${DB_DEV}" && -n "${DB_PARTITION}" ]]; then
            init_db_part
        fi
    else
        if [[ "${USE_EXTERNAL_JOURNAL_OR_BLOCK}" == "False" ]]; then
            divide_filestore_osd_partition
        fi
        init_osd_data_part
        init_journal_part
    fi

    L_OSD_FSID="${OSD_PARTUUID}"
    get_osd_id

    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        sgdisk "--change-name=${OSD_PARTNUM}:KOLLA_CEPH_DATA_BSL_${L_OSD_ID}" -- "${OSD_DEV}"
    else
        sgdisk "--change-name=${OSD_PARTNUM}:KOLLA_CEPH_DATA_L_${L_OSD_ID}" -- "${OSD_DEV}"
    fi
    partprobe_device "${OSD_DEV}"

    L_VG_UUID=$(uuidgen)
    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        vgcreate --force --yes ceph-"${L_VG_UUID}" "${OSD_PARTITION}"
        lvcreate --yes -l 100%FREE -n osd-block-${L_OSD_FSID} ceph-"${L_VG_UUID}"
        L_LV_NAME="/dev/ceph-${L_VG_UUID}/osd-block-${L_OSD_FSID}"
    else
        vgcreate -s 1G --force --yes ceph-"${L_VG_UUID}" "${OSD_PARTITION}"
        lvcreate --yes -l 100%FREE -n osd-data-${L_OSD_FSID} ceph-"${L_VG_UUID}"
        L_LV_NAME="/dev/ceph-${L_VG_UUID}/osd-data-${L_OSD_FSID}"
    fi

    L_LV_UUID=$(lvs --noheadings --readonly --separator=";" -o lv_uuid "${L_LV_NAME}")
    L_LV_UUID=$(echo ${L_LV_UUID} | sed s/[[:space:]]//g)

    lvchange --addtag ceph.osd_id="${L_OSD_ID}" "${L_LV_NAME}"
    lvchange --addtag ceph.osd_fsid="${L_OSD_FSID}" "${L_LV_NAME}"
    lvchange --addtag ceph.cluster_name=ceph "${L_LV_NAME}"
    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        lvchange --addtag ceph.type=block "${L_LV_NAME}"
        lvchange --addtag ceph.block_device="${L_LV_NAME}" "${L_LV_NAME}"
        lvchange --addtag ceph.block_uuid="${L_LV_UUID}" "${L_LV_NAME}"
    else
        lvchange --addtag ceph.type=data "${L_LV_NAME}"
        lvchange --addtag ceph.data_device="${L_LV_NAME}" "${L_LV_NAME}"
        lvchange --addtag ceph.data_uuid="${L_LV_UUID}" "${L_LV_NAME}"
    fi

    L_OSD_DIR="/var/lib/ceph/osd/ceph-${L_OSD_ID}"
    mkdir -p "${L_OSD_DIR}"

    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        mount -t tmpfs tmpfs "${L_OSD_DIR}"
    else
        mkfs -t xfs -f -i size=2048 "${L_LV_NAME}"
        mount -t xfs -o rw,noatime,inode64 "${L_LV_NAME}" "${L_OSD_DIR}"
    fi

    get_osd_keyring
    get_mon_map

    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        if [[ "${L_CHECK_WAL_DEVICE}" == "True" && -n "${WAL_PARTNUM}" ]]; then
            change_wal_part_name "KOLLA_CEPH_DATA_BSL"
        fi

        if [[ "${L_CHECK_DB_DEVICE}" == "True" && -n "${DB_PARTNUM}" ]]; then
            change_db_part_name "KOLLA_CEPH_DATA_BSL"
        fi

        ln -snf "${L_LV_NAME}" "${L_OSD_DIR}"/block
        if [[ "${L_CHANGE_WAL_NAME}" == "True" ]]; then
            wait_device_link_appear "${L_WAL_LINK_PATH}" "${L_WAL_LINK_UUID}" "${WAL_PARTITION}"
            ln -snf "${L_WAL_BOOT_PATH}" "${L_OSD_DIR}"/block.wal
            OSD_HAS_WAL_DB_OR_JOURNAL="${OSD_HAS_WAL_DB_OR_JOURNAL} --bluestore-block-wal-path ${L_WAL_BOOT_PATH}"
            lvchange --addtag ceph.wal_device="${L_WAL_BOOT_PATH}" ${L_LV_NAME}
            lvchange --addtag ceph.wal_uuid="${WAL_PARTUUID}" ${L_LV_NAME}
        fi

        if [[ "${L_CHANGE_DB_NAME}" == "True" ]]; then
            wait_device_link_appear "${L_DB_LINK_PATH}" "${L_DB_LINK_UUID}" "${DB_PARTITION}"
            ln -snf "${L_DB_BOOT_PATH}" "${L_OSD_DIR}"/block.db
            OSD_HAS_WAL_DB_OR_JOURNAL="${OSD_HAS_WAL_DB_OR_JOURNAL} --bluestore-block-db-path ${L_DB_BOOT_PATH}"
            lvchange --addtag ceph.db_device="${L_DB_BOOT_PATH}" "${L_LV_NAME}"
            lvchange --addtag ceph.db_uuid="${DB_PARTUUID}" "${L_LV_NAME}"
        fi
    else
        sgdisk "--change-name=${JOURNAL_PARTNUM}:KOLLA_CEPH_DATA_L_${L_OSD_ID}_J" "--typecode=${JOURNAL_PARTNUM}:${L_CEPH_JOURNAL_TYPE_CODE}" -- "${JOURNAL_DEV}"
        partprobe_device "${JOURNAL_DEV}"

        wait_device_link_appear "${L_JOURNAL_LINK_PATH}" "${L_JOURNAL_LINK_UUID}" "${JOURNAL_PARTITION}"

        ln -s "${L_JOURNAL_BOOT_PATH}" "${L_OSD_DIR}"/journal
        L_OSD_HAS_WAL_DB_OR_JOURNAL="--osd-journal ${L_JOURNAL_BOOT_PATH}"
        lvchange --addtag ceph.journal_device="${L_JOURNAL_BOOT_PATH}" "${L_LV_NAME}"
        lvchange --addtag ceph.journal_uuid="${JOURNAL_PARTUUID}" "${L_LV_NAME}"
    fi

    L_WEIGHT_PARTITION="${OSD_PARTITION}"
}

function prepare_osd_disk {
    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        if [[ "${USE_EXTERNAL_JOURNAL_OR_BLOCK}" == "False" ]]; then
            divide_bluestore_osd_partition
        fi

        L_OSD_FSID="${OSD_PARTUUID}"
        init_osd_data_part
        init_block_part

        if [[ -n "${WAL_DEV}" && "${BLOCK_DEV}" != "${WAL_DEV}" && -n "${WAL_PARTITION}" ]]; then
            init_wal_part
        fi

        if [[ -n "${DB_DEV}" && "${BLOCK_DEV}" != "${DB_DEV}" && -n "${DB_PARTITION}" ]]; then
            init_db_part
        fi
    else
        if [[ "${USE_EXTERNAL_JOURNAL_OR_BLOCK}" == "False" ]]; then
            divide_filestore_osd_partition
        fi

        init_osd_data_part
        init_journal_part
    fi

    get_osd_id
    L_OSD_DIR="/var/lib/ceph/osd/ceph-${L_OSD_ID}"
    mkdir -p "${L_OSD_DIR}"

    mkfs -t xfs -f -i size=2048 "${OSD_PARTITION}"
    mount -t xfs -o rw,noatime,inode64 "${OSD_PARTITION}" "${L_OSD_DIR}"

    get_osd_keyring
    get_mon_map

    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        sgdisk "--change-name=${BLOCK_PARTNUM}:KOLLA_CEPH_DATA_BS_${L_OSD_ID}_B" "--typecode=${BLOCK_PARTNUM}:${L_CEPH_BLOCK_TYPE_CODE}" -- "${BLOCK_DEV}"
        partprobe_device "${BLOCK_DEV}"

        if [[ "${L_CHECK_WAL_DEVICE}" == "True" && -n "${WAL_PARTNUM}" ]]; then
            change_wal_part_name "KOLLA_CEPH_DATA_BS"
        fi

        if [[ "${L_CHECK_DB_DEVICE}" == "True" && -n "${DB_PARTNUM}" ]]; then
            change_db_part_name "KOLLA_CEPH_DATA_BS"
        fi

        wait_device_link_appear "${L_BLOCK_LINK_PATH}" "${L_BLOCK_LINK_UUID}" "${BLOCK_PARTITION}"
        ln -snf "${L_BLOCK_BOOT_PATH}" "${L_OSD_DIR}"/block

        if [[ "${L_CHANGE_WAL_NAME}" == "True" ]]; then
            wait_device_link_appear "${L_WAL_LINK_PATH}" "${L_WAL_LINK_UUID}" "${WAL_PARTITION}"
            ln -snf "${L_WAL_BOOT_PATH}" "${L_OSD_DIR}"/block.wal
            L_OSD_HAS_WAL_DB_OR_JOURNAL="--bluestore-block-wal-path ${L_WAL_BOOT_PATH}"
        fi

        if [[ "${L_CHANGE_DB_NAME}" == "True" ]]; then
            wait_device_link_appear "${L_DB_LINK_PATH}" "${L_DB_LINK_UUID}" "${DB_PARTITION}"
            ln -snf "${L_DB_BOOT_PATH}" "${L_OSD_DIR}"/block.db
            L_OSD_HAS_WAL_DB_OR_JOURNAL="${L_OSD_HAS_WAL_DB_OR_JOURNAL} --bluestore-block-db-path ${L_DB_BOOT_PATH}"
        fi

        L_WEIGHT_PARTITION="${BLOCK_PARTITION}"
    else
        sgdisk "--change-name=${JOURNAL_PARTNUM}:KOLLA_CEPH_DATA_${L_OSD_ID}_J" "--typecode=${JOURNAL_PARTNUM}:${L_CEPH_JOURNAL_TYPE_CODE}" -- "${JOURNAL_DEV}"
        partprobe_device "${JOURNAL_DEV}"

        wait_device_link_appear "${L_JOURNAL_LINK_PATH}" "${L_JOURNAL_LINK_UUID}" "${JOURNAL_PARTITION}"
        ln -s "${L_JOURNAL_BOOT_PATH}" "${L_OSD_DIR}"/journal
        L_OSD_HAS_WAL_DB_OR_JOURNAL="--osd-journal ${L_JOURNAL_BOOT_PATH}"

        L_WEIGHT_PARTITION=${OSD_PARTITION}
    fi

    # Setting partition name based on ${OSD_ID}
    if [[ "${OSD_STORE_TYPE}" == "bluestore" ]]; then
        sgdisk "--change-name=${OSD_PARTNUM}:KOLLA_CEPH_DATA_BS_${L_OSD_ID}" "--typecode=${OSD_PARTNUM}:${L_CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"
    else
        sgdisk "--change-name=${OSD_PARTNUM}:KOLLA_CEPH_DATA_${L_OSD_ID}" "--typecode=${OSD_PARTNUM}:${L_CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"
    fi
    trigger_part_uuid "${OSD_PARTITION}"
    partprobe_device "${OSD_DEV}"
}

# Bootstrap and exit if KOLLA_BOOTSTRAP variable is set. This catches all cases
# of the KOLLA_BOOTSTRAP variable being set, including empty.
if [[ "${!KOLLA_BOOTSTRAP[@]}" ]]; then
    # Wait for ceph quorum before proceeding
    ceph quorum_status

    if [[ "${OSD_DISK_MODE}" == "LVM" ]]; then
        prepare_osd_lvm
    else
        prepare_osd_disk
    fi

    ceph-osd --osd-objectstore "${OSD_STORE_TYPE}" -d --mkfs -i "${L_OSD_ID}" --monmap "${L_MON_MAP}" ${L_OSD_HAS_WAL_DB_OR_JOURNAL} --osd-data "${L_OSD_DIR}" --osd-uuid "${L_OSD_FSID}"
    #rm "${OSD_TMP_KEY}"

    umount "${L_OSD_DIR}"

    if [[ "${!CEPH_CACHE[@]}" ]]; then
        CEPH_ROOT_NAME=cache
    fi

    if [[ "${OSD_INITIAL_WEIGHT}" == "auto" ]]; then
        # Because the block partition is a raw device, there is no disk label.
        # When this command is executed, an error is reported, so add "|| true" to ignore errors
        OSD_INITIAL_WEIGHT=$(parted --script ${L_WEIGHT_PARTITION} unit TB print | awk 'match($0, /^Disk.* (.*)TB/, a){printf("%.2f", a[1])}' || true )
    fi

    # These commands only need to be run once per host but are safe to run
    # repeatedly. This can be improved later or if any problems arise.
    host_bucket_name="${HOSTNAME}${CEPH_ROOT_NAME:+-${CEPH_ROOT_NAME}}"
    host_bucket_check=$(ceph osd tree | awk '/'"${host_bucket_name}"'/{print $0}' | wc -l)
    if [[ "${host_bucket_check}" -eq 0 ]]; then
        ceph osd crush add-bucket "${host_bucket_name}" host
        ceph osd crush move "${host_bucket_name}" root=${CEPH_ROOT_NAME:-default}
    fi

    # Adding osd to crush map
    ceph osd crush add "${L_OSD_ID}" "${OSD_INITIAL_WEIGHT}" host="${HOSTNAME}${CEPH_ROOT_NAME:+-${CEPH_ROOT_NAME}}"

    exit 0
fi

if [[ "${!OSD_START[@]}" ]]; then
    L_OSD_DIR="/var/lib/ceph/osd/ceph-${OSD_ID}"
    L_OSD_BLOCK_LINK="${L_OSD_DIR}/block"
    L_OSD_WAL_LINK="${L_OSD_DIR}/block.wal"
    L_OSD_DB_LINK="${L_OSD_DIR}/block.db"
    L_OSD_KEYRING="${L_OSD_DIR}/keyring"
    if [[ "${OSD_DISK_MODE}" == "LVM" && "${OSD_STORE_TYPE}" == "bluestore" ]] ; then
        if [[ ! -f ${L_OSD_BLOCK_LINK} && -n "${OSD_BLOCK}" ]]; then
            ln -snf "${OSD_BLOCK}" "${L_OSD_BLOCK_LINK}"
        fi
        if [[ ! -f ${L_OSD_WAL_LINK} && -n "${OSD_WAL}" ]]; then
            ln -snf "${OSD_WAL}" "${L_OSD_WAL_LINK}"
        fi
        if [[ ! -f ${L_OSD_DB_LINK} && -n "${OSD_DB}" ]]; then
            ln -snf "${OSD_DB}" "${L_OSD_DB_LINK}"
        fi
        if [[ ! -f ${L_OSD_KEYRING} ]]; then
            ceph auth get-or-create osd.${OSD_ID} osd 'allow *' mon 'allow profile osd' -o "${L_OSD_KEYRING}"
        fi
        ceph-bluestore-tool prime-osd-dir --dev "${OSD_BLOCK}" --path "${L_OSD_DIR}" --no-mon-config
    fi
fi

ARGS="-i ${OSD_ID}"
