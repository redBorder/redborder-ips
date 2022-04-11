#!/bin/bash

#######################################################################
# Copyright (c) 2014 ENEO Tecnología S.L.
# This file is part of redBorder.
# redBorder is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# redBorder is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License License for more details.
# You should have received a copy of the GNU Affero General Public License License
# along with redBorder. If not, see <http://www.gnu.org/licenses/>.
#######################################################################

# functions library for barnyard2 and snort initscripts

function get_bridge() {

    local bridgeif=""
    local dnaif=$1
    local dnaifindex=`echo "${dnaif}" | sed 's/^dna//'|sed 's/:dna.*$//'`

    if [ "x$dnaifindex" != "x" ]; then
        bridgeindex=$(( $dnaifindex / 2 ))
        if [ "x$bridgeindex" != "x" ]; then
            bridgeif="bpbr$bridgeindex"
        fi
    fi
    echo $bridgeif
}

f_set_updown_br_or_bp() {

    #################################
    # Table of states
    #
    # mode/action | bypass | bridge |
    # ------------------------------|
    # IPS/start   | off    | down   |
    # IPS/stop    | on     | up     |
    # IDS/start   | off    | up     |
    # IDS/stop    | on     | up     |
    # ------------------------------|
    #
    #################################

    local mode=$1
    local action=$2
    local ifbr=$3
    local bpbr_mode=""
    local br_mode=""
    local bridgeif=""
    
    if [ "x${mode}" == "xips" ]; then
        if [ "x${action}" == "xstart" ]; then
            bpbr_mode="off"
            br_mode="down"
        else
            # stop
            bpbr_mode="on"
            br_mode="up"
        fi
    else
        # ids
        if [ "x${action}" == "xstart" ]; then
            bpbr_mode="off"
            br_mode="up"
        else
            # stop
            bpbr_mode="on"
            br_mode="up"
        fi
    fi

    echo "${ifbr}" | egrep -q "^bpbr[0-9]*$"
    if [ $? -eq 0 ]; then
        if [ -d /sys/class/net/${ifbr} ]; then
            # interface type bypass bridge

            if [ "x${bpbr_mode}" == "xon" ]; then
                #stop
                ${RBDIR}/bin/rb_bypass.sh -b ${ifbr} -g | grep -q "The interface is in the non-Bypass mode"
                if [ $? -eq 0 ]; then
                    echo -n "Enabling bypass on ${ifbr}:"
                    ${RBDIR}/bin/rb_bypass.sh -b ${ifbr} -s on &>/dev/null
                    print_result 0
                fi
            else
                #start
                if [ "x$action" == "xstart" -a "x${bpbr_mode}" == "xoff" ]; then
                    if [ "x${AUTOBYPASS}" != "x1" ]; then
                        echo "Disabling bypass on ${ifbr} not applied: this action must be done manually."
                    else
                        # AUTOBYPASS is active ... disabling bypass only if it is enabled (on)
                        ${RBDIR}/bin/rb_bypass.sh -b ${ifbr} -g | grep -q "The interface is in the Bypass mode"
                        if [ $? -eq 0 ]; then
                            echo -n "Disabling bypass on ${ifbr}:"
                            ${RBDIR}/bin/rb_bypass.sh -b ${ifbr} -s off &>/dev/null
                            print_result 0
                        fi
                    fi
                else
                    ${RBDIR}/bin/rb_bypass.sh -b ${ifbr} -g | grep -q "The interface is in the Bypass mode"
                    if [ $? -eq 0 ]; then
                        echo -n "Disabling bypass on ${ifbr}:"
                        ${RBDIR}/bin/rb_bypass.sh -b ${ifbr} -s off &>/dev/null
                        print_result 0
                    fi
                fi
                ip l set ${br_mode} ${ifbr}
            fi
        else
            # NOP
            :
        fi
    else
        # interface type normal bridge or other
        echo "${ifbr}" | egrep -q "^br[0-9]*$"
        if [ $? -eq 0 ]; then
            if [ "x${br_mode}" == "xup" ]; then
                echo -n "Enabling bridge on ${ifbr}:"
            else
                echo -n "Disabling bridge on ${ifbr}:"
            fi

            if [ "x${AUTOBYPASS}" != "x1" ]; then
                echo " this action must be done manually."
            else
                ip l set ${br_mode} ${ifbr}
                print_result 0
            fi
        else
            # NOP
            :
        fi
    fi
}

f_configure_interface(){

    local interface=$1
    local driver
    local lcpu
    numcpus=$(lscpu | grep '^CPU(s):[ ][ ]*[0-9][0-9]*$' | awk '{print $2}')

    cat /proc/mounts | grep -q "/tmp/snortd"
    if [ $? -ne 0 ]; then
        [ ! -d /tmp/snortd ] && mkdir /tmp/snortd
        mount -t tmpfs -o size=4096 tmpfs /tmp/snortd
        logger -t snortd "mounting tmpfs directory for conf_ethtool_devs"
    fi
    ifconfig ${interface} | grep -q "^[ ]*UP"
    if [ $? -ne 0 ]; then
        logger -t snortd "setting up device ${interface}"
        ip l set up ${interface}
    fi

    if [ ! -f /tmp/snortd/conf_ethtool_${interface} ]; then
        ethtool -K ${interface} tso off &>/dev/null
        ethtool -K ${interface} gro off &>/dev/null
        ethtool -K ${interface} lro off &>/dev/null     #may not be supported
        ethtool -K ${interface} gso off &>/dev/null
        ethtool -K ${interface} rx off  &>/dev/null
        ethtool -K ${interface} tx off  &>/dev/null

        driver=$(ethtool -i ${interface}|grep driver |awk '{print $2}')
        if [ "x${driver}" == "xixgbe" ]; then
            ethtool -C ${interface} rx-usecs 1 &>/dev/null
            ethtool -G ${interface} tx 32768 &>/dev/null
            ethtool -G ${interface} rx 32768 &>/dev/null
        else
            ethtool -C ${interface} rx-usecs 3 &>/dev/null
            ethtool -G ${interface} tx 4096 &>/dev/null
            ethtool -G ${interface} rx 4096 &>/dev/null
            # Now it is time to configure generic queue tx & rx affinity
            if [ "x${driver}" == "xigb" ]; then
                for lcpu in $(seq 0 $(($numcpus-1))); do
                    if [ -d /sys/class/net/${interface}/queues/rx-$lcpu ]; then
                        if [ -e /sys/class/net/${interface}/queues/rx-$lcpu/rps_cpus ]; then
                            echo "$(echo "obase=16; 2^$lcpu" | bc)" > /sys/class/net/${interface}/queues/rx-$lcpu/rps_cpus
                        fi
                    fi
                    if [ -d /sys/class/net/${interface}/queues/tx-$lcpu ]; then
                        if [ -e /sys/class/net/${interface}/queues/tx-$lcpu/xps_cpus ]; then
                            echo "$(echo "obase=16; 2^$lcpu" | bc)" > /sys/class/net/${interface}/queues/tx-$lcpu/xps_cpus
                        fi
                    fi
                done
            fi
        fi
        ethtool -K ${interface} sg off  &>/dev/null
        touch /tmp/snortd/conf_ethtool_${interface}
    fi

    return 0
}

f_interface_is_multiqueue() {

    local interface=$1
    local ret=0
    if [ ! -d /sys/class/net/${interface}/queues ]; then
        # interface has not multiqueue support
        ret=1
    else
        # interface has multiqueue support
        num_queues=$(ls -d /sys/class/net/${interface}/queues/tx* | wc -l)
        if [ ${num_queues} -gt 1 ]; then
            # interface is multiqueue
            ret=0
        else
            # need to check if it has 1 basic queue or zero queue
            num_queues=$(cat /proc/interrupts |grep "${interface}-" | wc -l)
            if [ ${num_queues} -eq 0 ]; then
                # interface has no queue
                ret=1
            else
                # interface has only default queue (0)
                ret=0
            fi
        fi
    fi

    return $ret
}

f_configure_interface_queues() {

    # This function set the affinity for a queue interface to the correct CPU
    local interface=$1
    local interface_queue interface_irq 
    f_interface_is_multiqueue ${interface}
    if [ $? -eq 0 ]; then
        # interface is multiqueue
        for interface_queue in $(ls -d /sys/class/net/${interface}/queues/tx*); do
            interface_queue=$(basename ${interface_queue} | sed 's/tx-//')
            for interface_irq in $(cat /proc/interrupts |grep ${interface}-[a-zA-Z]*-${interface_queue} | awk '{print $1}' | sed 's/://'); do
                if [ "x${interface_irq}" != "x" ]; then
                    affinity_value=${affinity[${v_cpu[$((${interface_queue}%${#v_cpu[*]}))]}]}
                    affinity_value_count=$(echo -n ${affinity_value} | wc -c )
                    if [ ${affinity_value_count} -gt 16 ]; then
                        affinity_value=$(echo ${affinity_value} | sed 's/\([0-9]\{16\}\)$/,\1/'| sed 's/\([0-9]\{8\}\)$/,\1/')
                    elif [ ${affinity_value_count} -gt 8 ]; then
                        affinity_value=$(echo ${affinity_value} | sed 's/\([0-9]\{8\}\)$/,\1/')
                    fi
                    #echo ${affinity[${v_cpu[$((${interface_queue}%${#v_cpu[*]}))]}]} > /proc/irq/${interface_irq}/smp_affinity
                    echo ${affinity_value} > /proc/irq/${interface_irq}/smp_affinity
                fi
            done
        done
       
    else
        # interface does not support multiqueue
        interface_irq=$(cat /proc/interrupts |grep "${interface}$" | awk '{print $1}' | sed 's/://')
        if [ "x${interface_irq}" != "x" ]; then
            echo ${affinity[${v_cpu[0]}]} > /proc/irq/${interface_irq}/smp_affinity
        fi
    fi

    return 0
}

f_prepare_interfaces() {

    # this function loop over the list of segments and
    # prepare the network interfaces linking to each segment
    local segments=$1
    local interface
    local ret=0
    for segment in $(echo ${segments} | tr ',' ' '); do
        echo "${segment}" | egrep -q "^br[0-9]+$|^bpbr[0-9]+$" # it must be a valid segment
        if [ $? -eq 0 ]; then
            for interface in $(ls -d /sys/class/net/${segment}/brif/* 2>/dev/null); do
                interface=$(basename ${interface})
                f_configure_interface ${interface}
                f_configure_interface_queues ${interface}
            done
        else
            # ignoring segment
            ret=1
            continue
        fi
    done

    # if ret=1 ... some segment is not valid and was ignored
    return $ret
}

f_get_interface_for_instance() {

    local instance=$1
    local interface=$2

    f_interface_is_multiqueue ${interface}
    if [ $? -eq 0 ]; then
        # check if exist this queue for this CPU (instance)
        cat /proc/interrupts |grep -q ${interface}-[a-zA-Z]*-${instance}
        if [ $? -eq 0 ]; then
            interface="${interface}@${instance}"
        else
            # the queue for this instance is not possible
            interface="null"
        fi
    fi

    echo "${interface}"
}

f_get_interfaces_per_instance() {

    local iface1=$1
    local iface2=$2
    local iface_split=$3
    local ret=0
    local iface_pair_list=""
    f_interface_is_multiqueue ${iface1}
    if [ $? -eq 0 ]; then
        f_interface_is_multiqueue ${iface2}
        if [ $? -eq 0 ]; then
            # Multiqueue ... loop over queues and assign ethX@Y pairs to instances
            for queue in $(cat /proc/interrupts | grep ${iface1}-[a-zA-Z]*-[0-9]* | sed 's/.*-\([0-9]*\)$/\1/'); do
                cat /proc/interrupts | grep -q ${iface2}-[a-zA-Z]*-${queue}
                if [ $? -eq 0 ]; then
                    # is this queue for this instance?
                    if [ "x${v_cpu[${instance}]}" == "x${v_cpu[$((${queue}%${#v_cpu[*]}))]}" ]; then
                        iface_pair_list="${iface_pair_list},${iface1}@${queue}${iface_split}${iface2}@${queue}"
                    else
                        continue
                    fi
                else
                    # No sync in queue devices
                    ret=1
                fi
            done
        else
            ret=1
        fi
    else
        ret=1
    fi

    iface_pair_list=$(echo ${iface_pair_list} | sed 's/^,//')
    if [ $ret -eq 0 ]; then
        echo "${iface_pair_list}"
    else
        echo "${iface1}${iface_split}${iface2}"
    fi

}

f_get_listenifaces_dna() {

    # Usage: f_get_listeniface_dna ${instance}
    local instance=$1
    local listenifaces=""
    local segment interface iface_split listenifaces_pre

    if [ "x${SNORT_MODE}" == "xIDS_SPAN" ]; then
        iface_split=","
    else
        iface_split=":"
    fi
    for segment in $(echo ${INTERFACES} | tr ',' ' '); do
        echo "${segment}" | egrep -q "^br[0-9]+$|^bpbr[0-9]+$" # it must be a valid segment
        if [ $? -eq 0 ]; then
            listenifaces_pre=""
            for interface in $(ls -d /sys/class/net/${segment}/brif/* 2>/dev/null); do
                interface=$(basename ${interface})
                # interface must have correct queue interface assigned to correct instance/cpu
                if [ "x${listenifaces_pre}" == "x" ]; then
                    listenifaces_pre="${interface}"
                else
                    listenifaces_pre="${listenifaces_pre} ${interface}"
                fi
            done
            listenifaces_pre=$(f_get_interfaces_per_instance ${listenifaces_pre} ${iface_split})
            if [ "x${listenifaces}" == "x" ]; then
                listenifaces="${listenifaces_pre}"
            else
                listenifaces="${listenifaces},${listenifaces_pre}"
            fi
        else
            # ignoring segment
            continue
        fi
    done

    echo "${listenifaces}"
}

f_get_listenifaces_pfring() {

    # Usage: f_get_listeniface_pfring ${instance} ['listenifaces'|'lowlevelbridge']
    local instance=$1
    local mode=$2
    local listenifaces=""
    local lowlevelbridge=""
    local segment interface iface_split listenifaces_pre lowlevelbridge_pre

    if [ "x${SNORT_MODE}" == "xIDS_SPAN" ]; then
        iface_split=","
    elif [ "x${SNORT_MODE}" == "xIDS_FWD" ]; then
        if [ "x${PFRING_BESTEFFORT}" == "x1" ]; then
            iface_split=":"
        else
            iface_split=","
        fi
    else
        iface_split=":"
    fi
    for segment in $(echo ${INTERFACES} | tr ',' ' '); do
        echo "${segment}" | egrep -q "^br[0-9]+$|^bpbr[0-9]+$" # it must be a valid segment
        if [ $? -eq 0 ]; then
            listenifaces_pre=""
            lowlevelbridge_pre=""
            for interface in $(ls -d /sys/class/net/${segment}/brif/* 2>/dev/null); do
                interface=$(basename ${interface})
                # interface must have correct queue interface assigned to correct instance/cpu
                if [ "x${listenifaces_pre}" == "x" ]; then
                    listenifaces_pre="${interface}"
                    lowlevelbridge_pre="${interface}"
                else
                    listenifaces_pre="${listenifaces_pre}${iface_split}${interface}"
                    lowlevelbridge_pre="${interface},${lowlevelbridge_pre}"
                fi
            done
            if [ "x${listenifaces}" == "x" ]; then
                listenifaces="${listenifaces_pre}"
                lowlevelbridge="${lowlevelbridge_pre}"
            else
                listenifaces="${listenifaces},${listenifaces_pre}"
                lowlevelbridge="${lowlevelbridge},${lowlevelbridge_pre}"
            fi
        else
            # ignoring segment
            continue
        fi
    done

    if [ "x${mode}" == "xlistenifaces" ]; then
        echo "${listenifaces}"
    else
        # lowlevelbridge
        echo "${lowlevelbridge}"
    fi
}

f_get_clusterid() {

    local listenifaces=$1
    local instances_group=$2
    local face clusterid_list clusterid

    if [ "x${instances_group}" == "x0" ]; then
        clusterid=10
    else
        clusterid="${instances_group}10"
    fi

    for iface in $(echo ${listenifaces} | tr ',' ' ' | tr ':' ' '); do
        if [ "x${clusterid_list}" == "x" ]; then
            clusterid_list="${clusterid}"
        else
            clusterid_list="${clusterid_list},${clusterid}"
        fi
        clusterid=$((${clusterid}+1))
    done

    echo "${clusterid_list}"

}

#f_get_clusterid() {
#
#    local clusterid=$(f_get_last_free_clusterid)
#    local listenifaces=$1
#    local iface clusterid_list
#    
#    for iface in $(echo ${listenifaces} | tr ',' ' ' | tr ':' ' '); do
#        if [ "x${clusterid_list}" == "x" ]; then
#            clusterid_list="${clusterid}"
#        else
#            clusterid_list="${clusterid_list},${clusterid}"
#        fi
#        clusterid=$((${clusterid}+1))
#    done
#
#    echo "${clusterid_list}"
#}

f_get_last_free_clusterid() {

    local pid clusterid_list_tmp clusterid_tmp
    local clusterid=10

    for pid in $(pidof snort); do
        clusterid_list_tmp=$(f_get_pid_value ${pid} 'CLUSTERID')
        for clusterid_tmp in $(echo ${clusterid_list_tmp} | tr ',' ' '); do
            if [ ${clusterid} -le ${clusterid_tmp} ]; then
                clusterid=$((${clusterid_tmp}+1))
            fi
        done
    done

    echo "${clusterid}"
}

RES_COL=60
MOVE_TO_COL="echo -en \\033[${RES_COL}G"

set_color() {
    if [ "x$BOOTUP" != "xnone" ]; then
        green="echo -en \\033[1;32m"
        red="echo -en \\033[1;31m"
        yellow="echo -en \\033[1;33m"
        orange="echo -en \\033[0;33m"
        blue="echo -en \\033[1;34m"
        black="echo -en \\033[1;30m"
        white="echo -en \\033[255m"
        norm="echo -en \\033[1;0m"
        eval \$$1
    fi
}

e_ok() {
    [ "x$BOOTUP" != "xnone" ] && $MOVE_TO_COL || echo -n "    "
    echo -n "["
    set_color green
    echo -n $"  OK  "
    set_color norm
    echo -n "]"
    [ "x$BOOTUP" != "xnone" ] && echo -ne "\r"
    echo
    return 0
}

e_fail() {
    [ "x$BOOTUP" != "xnone" ] && $MOVE_TO_COL || echo -n "    "
    echo -n "["
    set_color red
    echo -n $"FAILED"
    set_color norm
    echo -n "]"
    [ "x$BOOTUP" != "xnone" ] && echo -ne "\r"
    echo
    return 1
}

function print_result() {
    [ "x$BOOTUP" == "xnone" ] && echo -n "                                    "
    if [ $1 -eq 0 ]; then
        e_ok
    else
        e_fail
    fi
} 

f_wait_pid() {

    local pid=$1
    local count=0
    local ret=0
    while : ; do
        if [ ${count} -ge 10 ]; then
            ret=1
            break
        fi
        count=$((${count}+1))
        if [ ! -d /proc/${pid} ]; then
            ret=0
            break
        else
            sleep 1
            continue
        fi
    done

    return $ret
}

f_get_config_value() {

    local config_file=$1
    local key=$2
    local value=""
    if [ -f ${config_file} ]; then
        value=$(cat ${config_file} ${config_file}_local 2>/dev/null | grep "^${key}=" | tail -n 1 | awk -F = '{print $2}' | sed 's/"//g')
    fi

    echo "${value}"
}

f_get_pid_value() {

    local pid=$1
    local key=$2
    local value=""
    if [ -e /proc/${pid}/environ ]; then
        value=$(cat /proc/${pid}/environ 2>/dev/null | tr '\0' '\n' | grep "^${key}=" | sed 's/^[^=]*=\(.*\)$/\1/' | sed 's/"//g')
    fi

    echo "${value}"
   
}

f_get_groupid_bygroupname() {

    local ign=$1
    local sysc instances_group_name instances_group
    for sysc in $(ls /etc/sysconfig/snort-* 2>/dev/null); do
        instances_group_name=$(f_get_config_value "${sysc}" 'INSTANCES_GROUP_NAME')
        if [ "${instances_group_name}" == "$ign" ]; then
            instances_group=$(f_get_config_value "${sysc}" 'INSTANCES_GROUP')
            break
        fi
    done
    echo "${instances_group}"
}

f_get_groupname_bygroupid() {

    local igid=$1
    local sysc instances_group_name instances_group
    for sysc in $(ls /etc/sysconfig/snort-* 2>/dev/null); do
        instances_group=$(f_get_config_value "${sysc}" 'INSTANCES_GROUP')
        if [ "${instances_group}" == "$igid" ]; then
            instances_group_name=$(f_get_config_value "${sysc}" 'INSTANCES_GROUP_NAME')
            break
        fi
    done
    echo "${instances_group_name}"
}

f_get_pid_bygroupandinstance() {

    local instances_group=$1
    local instance=$2
    local ret

    for pid in $(pidof snort); do
        if [ "x$(f_get_pid_value ${pid} 'INSTANCES_GROUP')" == "x${instances_group}" ]; then
            if [ "x$(f_get_pid_value ${pid} 'INSTANCE')" == "x${instance}" ]; then
                ret=${pid}
                break
            fi
        fi
    done

    echo "$ret"
}

f_stop_group() {

    local instances_group=$1
    local -A instances_pid
    local pid instance instances_group_name pid_file interfaces snort_mode

    for pid in $(pidof ${prog}); do
        if [ "x$(f_get_pid_value ${pid} 'INSTANCES_GROUP')" == "x${instances_group}" ]; then
            instance=$(f_get_pid_value ${pid} 'INSTANCE')
            instances_pid[${instance}]="${pid}"
            interfaces="$(f_get_pid_value ${pid} 'INTERFACES')"
            snort_mode=$(f_get_pid_value ${pid} 'SNORT_MODE')
        fi
    done

    [ "x${interfaces}" == "xALL" ] && \
        interfaces="$(ls -d /sys/class/net/br* /sys/class/net/bpbr* 2>/dev/null | sed 's%/sys/class/net/%%' | tr '\n' ',' | sed 's/,$//')"

    if [ "x${snort_mode}" != "xIDS_SPAN" ]; then
        for segment in $(echo ${interfaces} | tr ',' ' '); do
            f_set_updown_br_or_bp ips stop ${segment}
        done
    fi

    # ordered shutdown of every instance for this instances_group
    for instance in ${!instances_pid[*]}; do
        ret=0
        pid=${instances_pid[${instance}]}
        instances_group_name=$(f_get_pid_value ${pid} 'INSTANCES_GROUP_NAME')
        pid_file=$(ls /var/run/${prog}_*.pid | grep "_${instances_group}-${instance}.pid$")
        ppid_file=$(ls /var/run/${prog}_*.pid | grep "_${instances_group}-${instance}.ppid$")
        echo -n "Stopping ${prog} (${instances_group_name}-${instance}): "
        kill ${pid} &>/dev/null
        f_wait_pid ${pid}
        if [ $? -ne 0 ]; then
            # force kill process
            kill -9 ${pid}
        fi
        print_result $?
        rm -f ${pid_file}
        rm -f ${ppid_file}
        rm -f ${pid_file}.lck
    done

    if [ $ret -eq 1 ]; then
        echo -n "The ${prog} group ${instances_group} is not running:"
        print_result 1
    fi
}

f_clean() {
    declare -A instances_group_list

    local pid instances_group instance config_group_file
    local RETVAL=0
    local action="$1"
    # check prog processes running
    for pid in $(pidof ${prog}); do
        instances_group=$(f_get_pid_value ${pid} 'INSTANCES_GROUP')
        instance=$(f_get_pid_value ${pid} 'INSTANCE')
        instances_group_list[${instances_group}]="down"
    done

    for config_group_file in $(ls ${RBDIR}/etc/sysconfig/${prog}-* | grep "${prog}-[0-9][0-9]*$" | sort); do
        instances_group=$(f_get_config_value "${config_group_file}" 'INSTANCES_GROUP')
        [ "x${INSTANCES_GROUP}" == "x" ] && instances_group="$(echo ${config_group_file} | sed 's/.*-\([0-9]*\)$/\1/')"
        instances_group_list[${instances_group}]="up"
    done

    for instances_group in ${!instances_group_list[*]}; do
        if [ "x${instances_group_list[${instances_group}]}" == "xdown" ]; then
            if [ "x${action}" == "x" -o "x${action}" == "xstop" ]; then
                f_stop_group ${instances_group}
            fi
        elif [ "x${instances_group_list[${instances_group}]}" == "xup" ]; then
            if [ "x${action}" == "x" -o "x${action}" == "xstart" ]; then
                f_start_group ${instances_group}
            fi
        else
            # other future states
            :
        fi  
    done

    #Checking instances on correct cpus
    if [ "x${action}" == "xstop" ]; then
        for pid in $(pidof ${prog}); do
            instances_group=$(f_get_pid_value ${pid} 'INSTANCES_GROUP')
            instance=$(f_get_pid_value ${pid} 'INSTANCE')
            bindcpu=$(f_get_pid_value ${pid} 'BIND_CPU')

            config_group_file="${RBDIR}/etc/sysconfig/${prog}-${instances_group}"
            
            if [ -f $config_group_file ]; then
                config_cpu_list=( $(f_get_config_value "${config_group_file}" 'CPU_LIST' | tr ',' ' ' ) )
                local msg=""
                if [ "x$bindcpu" == "x" ]; then
                    msg="$prog ($pid) has no cpu assigned"
                elif [ "x${config_cpu_list[${instance}]}" == "x" ]; then
                    msg="$prog ($pid) is running on not known cpu"
                elif [ "x${config_cpu_list[${instance}]}" != "x$bindcpu" ]; then
                    msg="$prog ($pid) is running on other cpu than expected"
                fi

                if [ "x$msg" != "x" ]; then
                    echo "INFO: $msg (group: ${instances_group}  instance:${instance})"
                    echo -n "Stopping ${prog} (pid: $pid) "
                    kill ${pid} &>/dev/null
                    f_wait_pid ${pid}
                    if [ $? -ne 0 ]; then
                        # force kill process
                        kill -9 ${pid}
                    fi
                    print_result $?
                fi
            fi
        done
    fi

    if [ "x$(pidof ${prog})" == "x" ]; then
        rm -f /var/run/${prog}_*.lck
        rm -f /var/run/${prog}_*.pid
        rm -f $subsysfile
    fi
}

f_stop() {

    local instances_group pid pid_file instance segment instances_group_list
    local instances_group_name="$1"
    local ret=1

    for pid in $(pidof ${prog}); do
        instances_group=$(f_get_pid_value ${pid} 'INSTANCES_GROUP')
        if [ "x${instances_group_name}" == "x" ]; then
            instances_group_list="${instances_group_list} $(f_get_pid_value ${pid} 'INSTANCES_GROUP')"
        else
            if [ "x${instances_group_name}" == "x$(f_get_pid_value ${pid} 'INSTANCES_GROUP_NAME')" ]; then
                instances_group_list="${instances_group}"
                break
            fi
        fi
    done

    if [ "x${instances_group_list}" != "x" ]; then
        for instances_group in ${instances_group_list}; do
            f_stop_group ${instances_group}
        done
        sleep 1
    else
        if [ "x$(pidof ${prog})" == "x" ]; then
            echo -n "NOTE: All ${prog} instances are already stopped"
            print_result 0
        else
            echo -n "Stopping ${prog}: "
            killproc ${prog}
            RETVAL=$?
            echo 
        fi
    fi

    if [ "x$(pidof ${prog})" == "x" ]; then
        rm -f /var/run/${prog}_*.lck
        rm -f /var/run/${prog}_*.pid
        rm -f /var/run/${prog}_*.ppid
        rm -f $subsysfile
    fi
}

f_check_instance() {

    local instances_group=$1
    local instance=$2
    local ret=1
    local pid
    for pid in $(pidof ${prog}); do
        instances_group_tmp=$(f_get_pid_value ${pid} 'INSTANCES_GROUP')
        instance_tmp=$(f_get_pid_value ${pid} 'INSTANCE')
        if [ "x${instances_group}" == "x${instances_group_tmp}" -a "x${instance}" == "x${instance_tmp}" ]; then
            # found!
            ret=0
            break
        fi
    done

    return ${ret}
}

f_reload_group() {

    local instances_group_name=$1
    local instances_group instances_group_name_pid mid_v_prog pid n
    local -a v_prog

    for pid in $(pidof ${prog}); do
        instances_group_name_pid="$(f_get_pid_value ${pid} 'INSTANCES_GROUP_NAME')"
        if [ "x${instances_group_name}" == "x${instances_group_name_pid}" ]; then
            v_prog=( ${v_prog[@]} ${pid} )
        fi
    done

    mid_v_prog=$((${#v_prog[@]}/2))

    for n in $(seq 0 $((${#v_prog[@]}-1))); do
        [ $n -eq ${mid_v_prog} -a "x${prog}" == "xsnort" ] && sleep 30
        pid=${v_prog[$n]}
        instances_group_name_pid="$(f_get_pid_value ${pid} 'INSTANCES_GROUP_NAME')"
        instance=$(f_get_pid_value ${pid} 'INSTANCE')
        echo -n "Reloading ${prog} (${instances_group_name_pid}-${instance}): "
        kill -s HUP ${pid}
        RET=$?
        print_result $RET
        [ $RET -ne 0 ] && RETVAL=$RET
    done
}

f_reload() {

    local instances_group_name=$1
    local pid
    local -A v_instances_group_name

    if [ "x${instances_group_name}" == "x" ]; then
        for pid in $(pidof ${prog}); do
            instances_group_name="$(f_get_pid_value ${pid} 'INSTANCES_GROUP_NAME')"
            v_instances_group_name[${instances_group_name}]=1
        done
        for instances_group_name in ${!v_instances_group_name[@]}; do
            f_reload_group ${instances_group_name}
        done
    else
        f_reload_group ${instances_group_name}
    fi
}

f_start() {

    local segment config_group_file instances_group
    local instances_group_name=$1
    RETVAL=0

    ls ${RBDIR}/etc/sysconfig/${prog}-* 2>/dev/null | grep -q "${prog}-[0-9][0-9]*$"
    if [ $? -ne 0 ]; then
        # There is no config group file ... exiting
        return 1
    elif [ "x${instances_group_name}" != "x" ]; then
        for config_group_file in $(ls ${RBDIR}/etc/sysconfig/${prog}-* | grep "${prog}-[0-9][0-9]*$" | sort); do
            cat ${config_group_file} | grep "^INSTANCES_GROUP_NAME" | grep -q "${instances_group_name}"
            if [ $? -eq 0 ]; then
                # found!
                instances_group=$(f_get_config_value "${config_group_file}" 'INSTANCES_GROUP')
                [ "x${instances_group}" == "x" ] && instances_group="$(echo ${config_group_file} | sed 's/.*-\([0-9]*\)$/\1/')"
                f_start_group ${instances_group}
                break
            fi
        done
    else
        # loop over config group files
        for config_group_file in $(ls ${RBDIR}/etc/sysconfig/${prog}-* | grep "${prog}-[0-9][0-9]*$" | sort); do
            instances_group=$(f_get_config_value "${config_group_file}" 'INSTANCES_GROUP')
            [ "x${instances_group}" == "x" ] && instances_group="$(echo ${config_group_file} | sed 's/.*-\([0-9]*\)$/\1/')"
            f_start_group ${instances_group}
        done
    fi
}

## vim:ts=4:sw=4:expandtab:ai:nowrap:formatoptions=croqln:
