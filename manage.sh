#!/bin/bash

function usage {
    cat <<EOF
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
EOF
}

SHORT_OPTS="hv"
LONG_OPTS="help,image:,yes-i-really-really-mean-it,limit:,forks:,daemon:,cluster:,skip-pull,verbose"

RAW_ARGS="$*"
ARGS=$(getopt -o "${SHORT_OPTS}" -l "${LONG_OPTS}" --name "$0" -- "$@") || { usage >&2; exit 2; }

eval set -- "$ARGS"

while [[ "$#" -gt 0 ]]; do
    case "$1" in

    (--image)
            IMAGE_TAG="$2"
            shift 2
            ;;

    (--yes-i-really-really-mean-it)
            DANGER_CONFIRM=true
            shift 1
            ;;

    (--limit)
            LIMIT_HOSTS="$2"
            shift 2
            ;;

    (--forks)
            FORKS_NUM="$2"
            shift 2
            ;;

    (--daemon)
            CEPH_DAEMONS=$2
            shift 2
            ;;

    (--cluster)
            CEPH_CLUSTER=$2
            shift 2
            ;;

    (--skip-pull)
            SKIP_PULL=true
            shift 1
            ;;

    (--verbose|-v)
            VERBOSITY="$VERBOSITY --verbose"
            shift 1
            ;;

    (--help|-h)
            usage
            shift
            exit 0
            ;;

    (--)
            shift
            break
            ;;

    (*)
            echo "error"
            exit 3
            ;;
esac
done

case "$1" in

(deploy)
        ACTION_DES="Deploying Ceph daemons"
        CEPH_ACTION="deploy"
        ;;
(upgrade)
        ACTION_DES="Upgrading Ceph Environment"
        CEPH_ACTION="upgrade"
        ;;
(reconfigure)
        ACTION_DES="Reconfigure Ceph daemons"
        CEPH_ACTION="reconfigure"
        ;;
(stop)
        ACTION_DES="Stop Ceph daemons"
        CEPH_ACTION="stop"
        if [[ "${DANGER_CONFIRM}" != "--yes-i-really-really-mean-it" ]]; then
            cat << EOF
WARNING:
    This will stop all deployed kolla ceph containers. To confirm, please add the following option:
    --yes-i-really-really-mean-it
EOF
            exit 1
        fi
        ;;
(*)     usage
        exit 0
        ;;
esac

##############################
# Check ceph cluster
##############################
CEPH_ENV_PATH=$(realpath ceph-env/)

if [[ -z ${CEPH_CLUSTER} ]]; then
    echo "Please specify the cluster name to be deployed [--cluster]."
    exit 1
fi

CLUSTER_CONFIG_PATH="${CEPH_ENV_PATH}/${CEPH_CLUSTER}"
if [[ ! -d "${CLUSTER_CONFIG_PATH}" ]]; then
    echo "There is no corresponding cluster configuration folder (${CLUSTER_CONFIG_PATH}) here, please add it before deploying."
    exit 1
fi

##############################
# Ansible configuration
##############################
GLOBAL_FILE="${CLUSTER_CONFIG_PATH}/globals.yml"
INVENTORY="${CLUSTER_CONFIG_PATH}/inventory"
PLAYBOOK="ansible/site.yml"

##############################
# Set forks num
##############################
# Setup the number of parallel processes to spawn when communicating with remote hosts
if [[ -z ${FORKS_NUM} ]]; then
    FORKS_NUM=10
fi

##############################
# Check image tag
##############################
if [[ -z ${IMAGE_TAG} ]]; then
    echo "Please specify the image tag to be deployed [--image]."
    exit 1
fi

##############################
# Set ceph install daemon
##############################

LIMIT_DAEMONS=""

if [[ -n $CEPH_DAEMONS ]]; then
    if [[ "${CEPH_ACTION}" == "upgrade" ]]; then
        if [[ "${CEPH_DAEMONS}" =~ "ceph-mon" && "${CEPH_DAEMONS}" != "ceph-mon" ]] ; then
            cat <<EOF
Because the upgrade of mon is the highest priority, if you just started upgrading the cluster, please specify only mon
first (--daemon ceph-mon), then upgrade other daemons.
EOF
            exit 1
        fi
    fi
    LIMIT_DAEMONS="[${CEPH_DAEMONS}]"
else
    if [[ "${CEPH_ACTION}" == "upgrade" ]]; then
        cat <<EOF
When upgrading, instead of executing multiple nodes at the same time, they are executed one after the other. For the
same daemon, it should be performed in the same upgrade, so please specify the name of the daemon to be upgraded(--daemon).
EOF
        exit 1
    fi

fi

if [[ -z ${LIMIT_HOSTS} ]] ; then
    if [[ "${CEPH_DAEMONS}" =~ "ceph-mon" ]] ; then
        limit_for_upgrade="mons,"
    fi
    if [[ "${CEPH_DAEMONS}" =~ "ceph-mgr" ]] ; then
        limit_for_upgrade="${limit_for_upgrade}mgrs,"
    fi
    if [[ "${CEPH_DAEMONS}" =~ "ceph-osd" ]] ; then
        limit_for_upgrade="${limit_for_upgrade}osds,"
    fi
    if [[ "${CEPH_DAEMONS}" =~ "ceph-rgw" ]] ; then
        limit_for_upgrade="${limit_for_upgrade}rgws,"
    fi
    if [[ "${CEPH_DAEMONS}" =~ "ceph-mds" ]] ; then
        limit_for_upgrade="${limit_for_upgrade}mdss,"
    fi
    if [[ -n ${limit_for_upgrade} ]]; then
        LIMIT_HOSTS=${limit_for_upgrade}
    fi
fi
##############################
# Set ansible command
##############################
function set_ansible_vars {
    ANSIBLE_VARS="-i ${INVENTORY} -e ceph_action=${CEPH_ACTION} -e @${GLOBAL_FILE} -e CONFIG_DIR=${CLUSTER_CONFIG_PATH} -e ceph_release=${IMAGE_TAG} --forks ${FORKS_NUM}"

    if [[ -n "${LIMIT_HOSTS}" ]]; then
        ANSIBLE_VARS="${ANSIBLE_VARS} --limit ${LIMIT_HOSTS}"
    fi

    if [[ -n "${LIMIT_DAEMONS}" ]]; then
        ANSIBLE_VARS="${ANSIBLE_VARS} -e ceph_install_daemons=${LIMIT_DAEMONS}"
    fi
    if [[ -n "${CEPH_SERIAL}" ]]; then
        ANSIBLE_VARS="${ANSIBLE_VARS} -e ceph_serial=${CEPH_SERIAL}"
    fi

    if [[ -n "${VERBOSITY}" ]]; then
        ANSIBLE_VARS="${ANSIBLE_VARS} ${VERBOSITY}"
    fi
}

function process_cmd(){
    set_ansible_vars
    CMD="ansible-playbook ${ANSIBLE_VARS} ${PLAYBOOK}"
    echo "$ACTION_DES : $CMD"
    $CMD
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo "Command failed : $CMD"
        exit 1
    fi
}

##############################
# Pull docker image
##############################
function pull_images(){
    local action=${CEPH_ACTION}
    CEPH_ACTION="pull"
    process_cmd

    CEPH_ACTION=${action}
}

#################################
# Print the details for checking
#################################

function print_deploy_details() {
    if [[ -z ${LIMIT_DAEMONS} ]]; then
        local show_limit_daemons="all daemons"
    else
        local show_limit_daemons="${LIMIT_DAEMONS}"
    fi
    if [[ -z ${LIMIT_HOSTS} ]]; then
        local show_limit_hosts="all nodes"
    else
        local show_limit_hosts="${LIMIT_HOSTS}"
    fi
    local show_image_tag="\e[1;32m$IMAGE_TAG\e[0m"

    echo    ""
    echo    "*************** Please check here ********************************"
    echo    ""
    echo    "Will be [ ${CEPH_ACTION} ] [ ${CEPH_CLUSTER} ] cluster:"
    echo -e "    The ceph daemon           : [ ${show_limit_daemons} ]"
    echo -e "    The image tag             : [ ${show_image_tag} ]"
    echo -e "    Limited nodes             : [ ${show_limit_hosts} ]"
    echo    "    The config dir            : [ ${CLUSTER_CONFIG_PATH} ]"
    echo    "    The gloabl file           : [ ${GLOBAL_FILE} ]"
    echo    "    The inventory             : [ ${INVENTORY} ]"
    echo    ""
    echo    "******************************************************************"
    echo    "You have 30s to check, if you want to quit press CTRL + C :"
    echo    "******************************************************************"
    local time=0
    for (( i=29; i>=0; i=i-1 )); do
        ((time+=1));
        if (( "${i}"%10 == 0 )); then
            echo " . . . . * . . . . $i "
        fi
        sleep 1
    done
    echo "Check time is $time seconds"
    if [[ ${time} -lt 20 ]];then
        exit 1
    fi
    echo ""
    echo "******************************************************************"
    echo "Start [ ${CEPH_ACTION} ] now : "
    echo "******************************************************************"
    echo ""
}

##############################
# Perform action
##############################
print_deploy_details

if [[ "${CEPH_ACTION}" == "deploy" || "${CEPH_ACTION}" == "upgrade" ]] && [[ "${SKIP_PULL}" != "true" ]]; then
    pull_images
fi

if [[ "${CEPH_ACTION}" == "upgrade" || "${CEPH_ACTION}" == "reconfigure" ]]; then
    CEPH_SERIAL=1
fi
process_cmd
