#!/bin/bash

if [[ ! -d "/var/log/kolla-ceph/ceph" ]]; then
    mkdir -p /var/log/kolla-ceph/ceph
fi
if [[ $(stat -c %a /var/log/kolla-ceph/ceph) != "755" ]]; then
    chmod 755 /var/log/kolla-ceph/ceph
fi

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

# Bootstrap and exit if KOLLA_BOOTSTRAP variable is set. This catches all cases
# of the KOLLA_BOOTSTRAP variable being set, including empty.
if [[ "${!KOLLA_BOOTSTRAP[@]}" ]]; then
    # NOTE(SamYaple): Static gpt partcodes
    REGULAR_JOURNAL_TYPE_CODE="45b0969e-9b03-4f30-b4c6-b4b80ceff106"
    REGULAR_OSD_TYPE_CODE="4fbd7e29-9d25-41b8-afd0-062c0ceff05d"
    REGULAR_OSD_BS_BLOCK_TYPE_CODE="cafecafe-9b03-4f30-b4c6-b4b80ceff106"
    REGULAR_OSD_BS_WAL_TYPE_CODE="5ce17fce-4087-4169-b7ff-056cc58473f9"
    REGULAR_OSD_BS_DB_TYPE_CODE="30cd0809-c2b2-499c-8879-2d6b78529876"

    MPATH_OSD_TYPE_CODE="4fbd7e29-8ae0-4982-bf9d-5a8d867af560"
    MPATH_OSD_BS_BLOCK_TYPE_CODE="cafecafe-8ae0-4982-bf9d-5a8d867af560"
    MPATH_OSD_BS_WAL_TYPE_CODE="01b41e1b-002a-453c-9f17-88793989ff8f"
    MPATH_OSD_BS_DB_TYPE_CODE="ec6d6385-e346-45dc-be91-da2a7c8b3261"

    # Wait for ceph quorum before proceeding
    ceph quorum_status

    if [[ "${OSD_STORETYPE}" == "bluestore" ]]; then
        if [[ "${USE_EXTERNAL_BLOCK}" == "False" ]]; then
            OSD_BS_PARTUUID=$(uuidgen)
            OSD_BS_BLK_PARTUUID=$(uuidgen)
            sgdisk --zap-all -- "${OSD_BS_DEV}"
            sgdisk --new=1:0:+100M --partition-guid=1:"${OSD_BS_PARTUUID}" --mbrtogpt -- "${OSD_BS_DEV}"
            sgdisk --largest-new=2 --partition-guid=2:"${OSD_BS_BLK_PARTUUID}" --mbrtogpt -- "${OSD_BS_DEV}"
            partprobe_device "${OSD_BS_DEV}"
        fi

        wait_partition_appear "${OSD_BS_PARTITION}"
        sgdisk --zap-all -- "${OSD_BS_PARTITION}"

        wait_partition_appear "${OSD_BS_BLK_PARTITION}"
        sgdisk --zap-all -- "${OSD_BS_BLK_PARTITION}"

        if [[ "${OSD_BS_PARTTYPE}" == "mpath" ]]; then
            CEPH_OSD_TYPE_CODE="${MPATH_OSD_TYPE_CODE}"
        else
            CEPH_OSD_TYPE_CODE="${REGULAR_OSD_TYPE_CODE}"
        fi

        if [[ "${OSD_BS_BLK_PARTTYPE}" == "mpath" ]]; then
            CEPH_OSD_BS_BLOCK_TYPE_CODE="${MPATH_OSD_BS_BLOCK_TYPE_CODE}"
            BLOCK_LINK_PATH=/dev/disk/by-parttypeuuid
            BLOCK_LINK_UUID="${CEPH_OSD_BS_BLOCK_TYPE_CODE}"."${OSD_BS_BLK_PARTUUID}"
        else
            CEPH_OSD_BS_BLOCK_TYPE_CODE="${REGULAR_OSD_BS_BLOCK_TYPE_CODE}"
            BLOCK_LINK_PATH=/dev/disk/by-partuuid
            BLOCK_LINK_UUID="${OSD_BS_BLK_PARTUUID}"
        fi

        if [[ -n "${OSD_BS_WAL_DEV}" && "${OSD_BS_BLK_DEV}" != "${OSD_BS_WAL_DEV}" && -n "${OSD_BS_WAL_PARTITION}" ]]; then
            sgdisk --zap-all -- "${OSD_BS_WAL_PARTITION}"
            CHECK_WAL_DEVICE="True"
            if [[ "${OSD_BS_WAL_PARTTYPE}" == "mpath" ]]; then
                CEPH_OSD_BS_WAL_TYPE_CODE="${MPATH_OSD_BS_WAL_TYPE_CODE}"
                WAL_LINK_PATH=/dev/disk/by-parttypeuuid
                WAL_LINK_UUID="${CEPH_OSD_BS_WAL_TYPE_CODE}"."${OSD_BS_WAL_PARTUUID}"
            else
                CEPH_OSD_BS_WAL_TYPE_CODE="${REGULAR_OSD_BS_WAL_TYPE_CODE}"
                WAL_LINK_PATH=/dev/disk/by-partuuid
                WAL_LINK_UUID="${OSD_BS_WAL_PARTUUID}"
            fi
        fi

        if [[ -n "${OSD_BS_DB_DEV}" && "${OSD_BS_BLK_DEV}" != "${OSD_BS_DB_DEV}" && -n "${OSD_BS_DB_PARTITION}" ]]; then
            sgdisk --zap-all -- "${OSD_BS_DB_PARTITION}"
            CHECK_DB_DEVICE="True"
            if [[ "${OSD_BS_DB_PARTTYPE}" == "mpath" ]]; then
                CEPH_OSD_BS_DB_TYPE_CODE="${MPATH_OSD_BS_DB_TYPE_CODE}"
                DB_LINK_PATH=/dev/disk/by-parttypeuuid
                DB_LINK_UUID="${CEPH_OSD_BS_DB_TYPE_CODE}"."${OSD_BS_DB_PARTUUID}"
            else
                CEPH_OSD_BS_DB_TYPE_CODE="${REGULAR_OSD_BS_DB_TYPE_CODE}"
                DB_LINK_PATH=/dev/disk/by-partuuid
                DB_LINK_UUID="${OSD_BS_DB_PARTUUID}"
            fi
        fi

        OSD_ID=$(ceph osd new "${OSD_BS_PARTUUID}")
        OSD_DIR="/var/lib/ceph/osd/ceph-${OSD_ID}"
        mkdir -p "${OSD_DIR}"

        mkfs.xfs -f "${OSD_BS_PARTITION}"
        mount "${OSD_BS_PARTITION}" "${OSD_DIR}"

        OSD_KEYRING=$(ceph-authtool --gen-print-key)
        ceph-authtool "${OSD_DIR}/keyring" --create-keyring --name osd.${OSD_ID} --add-key "${OSD_KEYRING}"

        echo "bluestore" > "${OSD_DIR}"/type

        sgdisk "--change-name=${OSD_BS_BLK_PARTNUM}:KOLLA_CEPH_DATA_BS_${OSD_ID}_B" "--typecode=${OSD_BS_BLK_PARTNUM}:${CEPH_OSD_BS_BLOCK_TYPE_CODE}" -- "${OSD_BS_BLK_DEV}"
        partprobe_device "${OSD_BS_BLK_DEV}"

        if [[ "${CHECK_WAL_DEVICE}" == "True" && -n "${OSD_BS_WAL_PARTNUM}" ]]; then
            sgdisk "--change-name=${OSD_BS_WAL_PARTNUM}:KOLLA_CEPH_DATA_BS_${OSD_ID}_W" "--typecode=${OSD_BS_WAL_PARTNUM}:${CEPH_OSD_BS_WAL_TYPE_CODE}" -- "${OSD_BS_WAL_DEV}"
            partprobe_device "${OSD_BS_WAL_DEV}"
            CHANGE_WAL_NAME="True"
        fi

        if [[ "${CHECK_DB_DEVICE}" == "True" && -n "${OSD_BS_DB_PARTNUM}" ]]; then
            sgdisk "--change-name=${OSD_BS_DB_PARTNUM}:KOLLA_CEPH_DATA_BS_${OSD_ID}_D" "--typecode=${OSD_BS_DB_PARTNUM}:${CEPH_OSD_BS_DB_TYPE_CODE}" -- "${OSD_BS_DB_DEV}"
            partprobe_device "${OSD_BS_DB_DEV}"
            CHANGE_DB_NAME="True"
        fi

        wait_device_link_appear "${BLOCK_LINK_PATH}" "${BLOCK_LINK_UUID}" "${OSD_BS_BLK_PARTITION}"
        ln -s "${BLOCK_LINK_PATH}"/"${BLOCK_LINK_UUID}" "${OSD_DIR}"/block

        if [[ "${CHANGE_WAL_NAME}" == "True" ]]; then
            wait_device_link_appear "${WAL_LINK_PATH}" "${WAL_LINK_UUID}" "${OSD_BS_WAL_PARTITION}"
            ln -s "${WAL_LINK_PATH}"/"${WAL_LINK_UUID}" "${OSD_DIR}"/block.wal
        fi

        if [[ "${CHANGE_DB_NAME}" == "True" ]]; then
            wait_device_link_appear "${DB_LINK_PATH}" "${DB_LINK_UUID}" "${OSD_BS_DB_PARTITION}"
            ln -s "${DB_LINK_PATH}"/"${DB_LINK_UUID}" "${OSD_DIR}"/block.db
        fi

        if [[ "$(ceph --version)" =~ (luminous|mimic) ]]; then
            ceph-osd -i "${OSD_ID}" --mkfs -k "${OSD_DIR}"/keyring --osd-uuid "${OSD_BS_PARTUUID}"
        else
            ceph-osd -i "${OSD_ID}" --mkfs -k "${OSD_DIR}"/keyring --osd-uuid "${OSD_BS_PARTUUID}" --no-mon-config
        fi

        ceph auth add "osd.${OSD_ID}" osd 'allow *' mon 'allow profile osd' -i "${OSD_DIR}/keyring"

        umount "${OSD_BS_PARTITION}"

        WEIGHT_PARTITION="${OSD_BS_BLK_PARTITION}"
    else
        CEPH_OSD_TYPE_CODE="${REGULAR_OSD_TYPE_CODE}"
        CEPH_JOURNAL_TYPE_CODE="${REGULAR_JOURNAL_TYPE_CODE}"
        if [[ "${USE_EXTERNAL_JOURNAL}" == "False" ]]; then
            # Formatting disk for ceph
            sgdisk --zap-all -- "${OSD_DEV}"
            sgdisk --new=2:1M:5G -- "${JOURNAL_DEV}"
            sgdisk --largest-new=1 -- "${OSD_DEV}"
            # NOTE(SamYaple): This command may throw errors that we can safely ignore
            partprobe || true
        fi

        OSD_ID=$(ceph osd create)
        OSD_DIR="/var/lib/ceph/osd/ceph-${OSD_ID}"
        mkdir -p "${OSD_DIR}"

        if [[ "${OSD_FILESYSTEM}" == "btrfs" ]]; then
            mkfs.btrfs -f "${OSD_PARTITION}"
        elif [[ "${OSD_FILESYSTEM}" == "ext4" ]]; then
            mkfs.ext4 "${OSD_PARTITION}"
        else
            mkfs.xfs -f "${OSD_PARTITION}"
        fi
        mount "${OSD_PARTITION}" "${OSD_DIR}"

        # This will through an error about no key existing. That is normal. It then
        # creates the key in the next step.
        if [[ "$(ceph --version)" =~ (luminous|mimic) ]]; then
            ceph-osd -i "${OSD_ID}" --mkfs --osd-journal="${JOURNAL_PARTITION}" --mkkey
        else
            ceph-osd -i "${OSD_ID}" --mkfs --osd-journal="${JOURNAL_PARTITION}" --mkkey --no-mon-config
        fi

        ceph auth add "osd.${OSD_ID}" osd 'allow *' mon 'allow profile osd' -i "${OSD_DIR}/keyring"
        umount "${OSD_PARTITION}"

        WEIGHT_PARTITION=${OSD_PARTITION}
    fi

    if [[ "${!CEPH_CACHE[@]}" ]]; then
        CEPH_ROOT_NAME=cache
    fi

    if [[ "${OSD_INITIAL_WEIGHT}" == "auto" ]]; then
        # Because the block partition is a raw device, there is no disk label.
        # When this command is executed, an error is reported, so add "|| true" to ignore errors
        OSD_INITIAL_WEIGHT=$(parted --script ${WEIGHT_PARTITION} unit TB print | awk 'match($0, /^Disk.* (.*)TB/, a){printf("%.2f", a[1])}' || true )
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
    ceph osd crush add "${OSD_ID}" "${OSD_INITIAL_WEIGHT}" host="${HOSTNAME}${CEPH_ROOT_NAME:+-${CEPH_ROOT_NAME}}"

    # Setting partition name based on ${OSD_ID}
    if [[ "${OSD_STORETYPE}" == "bluestore" ]]; then
        sgdisk "--change-name=${OSD_BS_PARTNUM}:KOLLA_CEPH_DATA_BS_${OSD_ID}" "--typecode=${OSD_BS_PARTNUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_BS_DEV}"
        trigger_part_uuid "${OSD_BS_PARTITION}"
    else
        sgdisk "--change-name=${OSD_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}" "--typecode=${OSD_PARTITION_NUM}:${CEPH_OSD_TYPE_CODE}" -- "${OSD_DEV}"
        sgdisk "--change-name=${JOURNAL_PARTITION_NUM}:KOLLA_CEPH_DATA_${OSD_ID}_J" "--typecode=${JOURNAL_PARTITION_NUM}:${CEPH_JOURNAL_TYPE_CODE}" -- "${JOURNAL_DEV}"
    fi
    partprobe || true

    exit 0
fi

OSD_DIR="/var/lib/ceph/osd/ceph-${OSD_ID}"
if [[ "${OSD_STORETYPE}" == "bluestore" ]]; then
    ARGS="-i ${OSD_ID}"
else
    ARGS="-i ${OSD_ID} --osd-journal ${JOURNAL_PARTITION} -k ${OSD_DIR}/keyring"
fi
