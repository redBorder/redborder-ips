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

f_get_pid_value() {

    local pid=$1
    local key=$2
    local value=""
    if [ -e /proc/${pid}/environ ]; then
        value=$(cat /proc/${pid}/environ 2>/dev/null | tr '\0' '\n' | grep "^${key}=" | sed 's/^[^=]*=\(.*\)$/\1/' | sed 's/"//g')
    fi

    echo "${value}"

}

function get_sum_or_avg_stats() {

    local key_to_ask=$1
    local key value key_value
    local -A h_stats_param
    local key_value_list="time|null pkt_drop_percent|avg wire_mbits_per_sec.realtime|sum alerts_per_second|sum kpackets_wire_per_sec.realtime|sum \
        avg_bytes_per_wire_packet|avg patmatch_percent|avg syns_per_second|sum synacks_per_second|sum new_sessions_per_second|sum \
        deleted_sessions_per_second|sum total_sessions|sum max_sessions|sum stream_flushes_per_second|sum stream_faults|avg stream_timeouts|avg \
        frag_creates_per_second|sum frag_completes_per_second|sum frag_inserts_per_second|sum frag_deletes_per_second|sum \
        frag_autofrees_per_second|sum frag_flushes_per_second|sum current_frags|sum max_frags|sum frag_timeouts|avg frag_faults|sum \
        iCPUs|null usr[0]|avg sys[0]|avg idle[0]|avg wire_mbits_per_sec.realtime|sum ipfrag_mbits_per_sec.realtime|sum \
        ipreass_mbits_per_sec.realtime|sum rebuilt_mbits_per_sec.realtime|sum mbits_per_sec.realtime|sum avg_bytes_per_wire_packet|avg \
        avg_bytes_per_ipfrag_packet|avg avg_bytes_per_ipreass_packet|avg avg_bytes_per_rebuilt_packet|avg avg_bytes_per_packet|avg \
        kpackets_wire_per_sec.realtime|sum kpackets_ipfrag_per_sec.realtime|sum kpackets_ipreass_per_sec.realtime|sum \
        kpackets_rebuilt_per_sec.realtime|sum kpackets_per_sec.realtime|sum pkt_stats.pkts_recv|sum pkt_stats.pkts_drop|sum \
        total_blocked_packets|sum new_udp_sessions_per_second|sum deleted_udp_sessions_per_second|sum total_udp_sessions|sum \
        max_udp_sessions|sum max_tcp_sessions_interval|sum curr_tcp_sessions_initializing|sum curr_tcp_sessions_established|sum \
        curr_tcp_sessions_closing|sum tcp_sessions_midstream_per_second|sum tcp_sessions_closed_per_second|sum \
        tcp_sessions_timedout_per_second|sum tcp_sessions_pruned_per_second|sum tcp_sessions_dropped_async_per_second|sum \
        current_attribute_hosts|sum attribute_table_reloads|sum mpls_mbits_per_sec.realtime|sum avg_bytes_per_mpls_packet|avg \
        kpackets_per_sec_mpls.realtime|sum total_tcp_filtered_packets|sum total_udp_filtered_packets|sum ip4::trim|null \
        ip4::tos|null ip4::df|null ip4::rf|null ip4::ttl|null ip4::opts|null icmp4::echo|null ip6::ttl|null ip6::opts|null icmp6::echo|null \
        tcp::syn_opt|null tcp::opt|null tcp::pad|null tcp::rsv|null tcp::ns|null tcp::urg|null tcp::urp|null tcp::trim|null tcp::ecn_pkt|null \
        tcp::ecn_ssn|null tcp::ts_ecr|null tcp::ts_nop|null tcp::ips_data|null tcp::block|null total_injected_packets|sum \
        frag3_mem_in_use|sum stream5_mem_in_use|sum total_alerts_per_second|sum ratio_syn_synacks|avg"

    for key_value in ${key_value_list}; do
        key=$(echo ${key_value} | awk -F "|" '{print $1}')
        value=$(echo ${key_value} | awk -F "|" '{print $2}')
        h_stats_param[${key}]=${value}
    done

    echo "${h_stats_param[${key_to_ask}]}"
}

function read_snort_stats() {

    local l_instances_group=$1
    local pid_list pid instances_group instance
    local -A h_instances_group

    pid_list=$(pidof snort)
    for pid in ${pid_list}; do
        instances_group=$(f_get_pid_value ${pid} 'INSTANCES_GROUP')
        instance=$(f_get_pid_value ${pid} 'INSTANCE')
        h_instances_group[${instances_group}]="${h_instances_group[${instances_group}]} ${instance}"
    done

    if [ "x${l_instances_group}" != "x" ]; then
        for instance in $(echo ${h_instances_group[${l_instances_group}]} | tr ' ' '\n' | sort); do
            #echo "INSTANCE_GROUP: ${l_instances_group}, INSTANCE: ${instance}"
            read_file_stats ${l_instances_group} ${instance}
        done
    else
        for instances_group in ${!h_instances_group[@]}; do
            for instance in $(echo ${h_instances_group[${instances_group}]} | tr ' ' '\n' | sort); do
                #echo "INSTANCE_GROUP: ${instances_group}, INSTANCE: ${instance}"
                read_file_stats ${instances_group} ${instance}
            done
        done
    fi

    return 0
}

function read_file_stats() {
    local instances_group=$1
    local instance=$2
    local my_file_stats=/var/log/snort/${instances_group}/instance-${instance}/stats/snort.stats
    local -a my_vars_list my_values_list
    local -A my_stats_hash
    local n key value extra_stats

    my_vars_list=( $(cat ${my_file_stats} | grep "^#time" | sed 's/^#//' | tail -n 1 | tr ',' ' ') )
    if [ ${#my_vars_list[@]} -eq 0 ]; then
        #echo "Stats format does not exist! ... exiting"
        return 1
    fi
    my_values_list=( $(tail -n 1 ${my_file_stats} | grep -v "^#" | tr ',' ' ') )
    if [ ${#my_values_list[@]} -eq 0 ]; then
        #echo "Stats values does not exist! ... exiting"
        #exit 1
        return 1
    fi
    for n in $(seq 0 $((${#my_vars_list[@]}-1))); do
        key=${my_vars_list[$n]}
        value=${my_values_list[$n]}
        my_stats_hash[$key]=$value
    done
    echo
    echo "Instance ${instance}"
    echo "=========="
    echo
    for key in ${my_vars_list[@]}; do
        extra_stats=""
        if [ "x${key}" == "xtime" ]; then
            extra_stats="($(date -d @${my_stats_hash[$key]}))"
        fi
        echo "$key: ${my_stats_hash[$key]} ${extra_stats}"
    done
    echo
}

function read_file(){
    local my_file_stats="$1"
    local my_result=""
    local deltatime my_tmp_result

    my_vars_list=$(cat ${my_file_stats} | grep "^#time" | sed 's/^#//' | tail -n 1)
    if [ -z "${my_vars_list}" ]; then
        #echo "Stats format does not exist! ... exiting"
        #exit 1
        continue
    fi
    
    my_values_list=$(tail -n 1 ${my_file_stats} | grep -v "^#")
    if [ ! -z "${my_values_list}" ]; then
        my_vars_list=($(echo ${my_vars_list} | tr ',' ' '))
        my_values_list=($(echo ${my_values_list} | tr ',' ' '))
    
        if [ ${#my_vars_list[@]} -eq ${#my_values_list[@]} ]; then
            count=0
            for key in ${my_vars_list[@]}; do
                my_stats[$key]=${my_values_list[$count]}
                count=$(($count+1))
            done

            my_instance=$(echo ${my_file_stats} | sed 's/.*\/instance-\([0-9]*\)\/.*/\1/')
            if [ -z "${my_stats_key}" ]; then
                my_key_list="time wire_mbits_per_sec.realtime pkt_drop_percent kpackets_wire_per_sec.realtime total_sessions idle[${my_instance}] alerts_per_minute"
                for key in ${my_key_list}; do
                    if [ "x$key" == "xidle[${my_instance}]" ]; then
                        if [ "x${my_stats[$key]}" == "x" ]; then
                            my_stats[$key]=${my_stats['idle[0]']}
                        fi
                        tmp_value=$(echo "scale=3; 100-${my_stats[$key]}"|bc)
                        [ "x$tmp_value" == "x" ] && tmp_value=0
                        my_result="${my_result}${my_instance}:cpu:${tmp_value};"
                        my_result="${my_result}${my_instance}:wire_bits_per_sec_realtime:${tmp_value};"
                    elif [ "x$key" == "xalerts_per_minute" ]; then
                        key="alerts_per_second"
                        tmp_value=$(echo "scale=3; 60*${my_stats[$key]}"|bc)
                        [ "x$tmp_value" == "x" ] && tmp_value=0
                        my_result="${my_result}${my_instance}:alerts_per_minute:${tmp_value};"
                    else
                        my_result="${my_result}${my_instance}:$key:${my_stats[$key]};"
                    fi
                done
            else
                if [ "x$my_stats_key" == "xidle[0]" ]; then
                    key="idle[${my_instance}]"
                    if [ "x${my_stats[$key]}" == "x" ]; then
                        my_stats[$key]=${my_stats['idle[0]']}
                    fi
                    my_tmp_result=${my_stats[$key]}
                elif [ "x$my_stats_key" == "xratio_syn_synacks" ]; then
                    if [ "x${my_stats['synacks_per_second']}" == "x" -o "x${my_stats['synacks_per_second']}" == "x0.000" ]; then
                        my_tmp_result="0.000"
                    else
                        my_tmp_result=$(echo "scale=3; ${my_stats['syns_per_second']}/${my_stats['synacks_per_second']}"|bc 2>/dev/null)
                    fi
                elif [ "x$my_stats_key" == "xwire_bits_per_sec.realtime" -o "x$my_stats_key" == "xwire_bits_per_sec_realtime" ]; then
                    my_tmp_result=$(echo "scale=3; 1000000 * ${my_stats['wire_mbits_per_sec.realtime']}"|bc 2>/dev/null)
                elif [ "x$my_stats_key" == "xpackets_wire_per_sec.realtime" -o "x$my_stats_key" == "xpackets_wire_per_sec_realtime" ]; then
                    my_tmp_result=$(echo "scale=3; 1000 * ${my_stats['kpackets_wire_per_sec.realtime']}"|bc 2>/dev/null)
                elif [ "x$my_stats_key" == "xcpu[0]" -o "x$my_stats_key" == "xsnort_cpu" ]; then
                    my_tmp_result=$(echo "scale=3; 100 - ${my_stats['idle[0]']}"|bc 2>/dev/null)
                else
                    my_tmp_result=${my_stats[${my_stats_key}]}
                fi
                deltatime=$(($(date '+%s')-${my_stats['time']}))
                if [ ${deltatime} -gt ${SNORTDELTA} ]; then
                    my_tmp_result=""
                fi
                [ "x$my_tmp_result" != "x" -a $flag_include_time -eq 1 ] && my_tmp_result="${my_stats['time']}:${my_tmp_result}"
                my_result="${my_result}${my_tmp_result};"
            fi
        fi
    fi
    echo ${my_result}
}

function loop_read_stats() {

    local my_snort_group="$1"
    local my_stats_key="$2"
    local d n m s x

    while : ; do
        d=$(date '+%T %d/%m/%Y %Z')
        n=$(read_stats ${my_snort_group} ${my_stats_key})
        # normalizing
        n=$(echo "$n" | sed 's/;;*/;/g' | sed 's/^;//' | sed 's/;$//')
        m=$(echo "$n" | tr ';' '+')
        m=$(echo "scale=3; $m" | bc 2>/dev/null)
        s=$(get_sum_or_avg_stats ${my_stats_key})
        x=""
        if [ "x$s" == "xsum" ]; then
            x="$n, SUM=$m"
        elif [ "x$s" == "xavg" ]; then
            m=$(echo "scale=3; $m/$(echo $n | tr ';' '\n' | wc -l)" | bc 2>/dev/null)
            x="$n, AVG=$m"
        else
            # null value
            x="$n"
        fi
        echo "date: $d, ${my_stats_key}: ${x}"
        sleep 5
    done
}

function read_stats() {

    local my_snort_group="$1"
    local my_stats_key="$2"
    local my_stats_msg=""
    local allfiles=""
    local -A my_stats
    local pid instances_group instance my_file_stats my_result file_dir last_file
    
    for pid in $(pidof snort); do
        instances_group=$(f_get_pid_value ${pid} 'INSTANCES_GROUP')
        instance=$(f_get_pid_value ${pid} 'INSTANCE')
        if [ "x${instances_group}" != "x${my_snort_group}" ]; then
            continue
        else
            allfiles="${allfiles} /var/log/snort/${my_snort_group}/instance-${instance}/stats/snort.stats"
        fi
    done
    
    for my_file_stats in $(echo ${allfiles} | tr ' ' '\n' |sort); do
        if [ -f $my_file_stats ]; then
            my_result=$(read_file $my_file_stats)
            if [ "x$my_result" == "x" ]; then
                file_dir=$(dirname $my_file_stats)
                last_file=$(ls -lf --sort=time $file_dir/*-* 2>/dev/null|head -n 1)
                if [ "x$last_file" != "x" ]; then
                    my_result=$(read_file $last_file)
                fi
            fi
            [ "x${my_result}" == "x" ] && my_result=";"
        else
            my_result=";"
        fi
        my_stats_msg="${my_stats_msg}${my_result}"
    done
    
    echo "${my_stats_msg}" | sed 's/;$//'
}

function usage(){
    echo "$0 -g <groupid> [-h] [-p <param>] [-d <deltatime>] [-t] [-i]"
    echo "    -g <groupid>    snort group instances id (0, 1, 2, ...)"
    echo "    -p <param>      param to read. If it is not present it will print all of them"
    echo "    -l <grouplist>  list of params and values of a list of groups and instances of active snort processes"
    echo "    -d <deltatime>  maximum time difference between last time stat and current system time"
    echo "    -d <deltatime>  maximum time difference between last time stat and current system time"
    echo "    -t              include stats timestamp on the output (exclude option -d)"
    echo "    -i              print stats for parameter 'param' ending with sum or average, if possible, value every 5 seconds"
    echo "    -h              print this help"
}

SNORTGROUP=""
SNORTPARAM=""
SNORTDELTA=25
SUM_OR_AVG="sum"
flag_opt_list=0
flag_opt_group=0
flag_include_time=0
flag_opt_interactive=0

while getopts "hl:g:p:d:ti" opt; do
    case $opt in
        g)
            flag_opt_group=1
            SNORTGROUP=$OPTARG
            ;;
        p)
            SNORTPARAM=$OPTARG
            ;;
        d)
            SNORTDELTA=$OPTARG
            ;;

        l)
            flag_opt_list=1
            GROUPLIST=$OPTARG
            ;;
        t)
            flag_include_time=1
            ;;
        i)
            flag_opt_interactive=1
            SUM_OR_AVG=$OPTARG
            ;;
        h)
            usage
            exit 0
            ;;
    esac
done

if [ "x$SNORTDELTA" == "x" ]; then
    SNORTDELTA=25
else
    echo "${SNORTDELTA}" | grep -q "^[0-9][0-9]*$"
    if [ $? -ne 0 ]; then
        #echo "ERROR: deltatime is not numeric!"
        exit 4
    fi
fi

if [ $flag_opt_group -eq 1 -a $flag_opt_list -eq 1 ]; then
    # Not possible
    echo "ERROR: Is not possible to use -l ang -g at the same time"
    exit 1
fi

if [ $flag_opt_group -eq 1 ]; then
    if [ "x$SNORTGROUP" == "x" ]; then
        usage
        exit 1
    else
        if [ $flag_opt_interactive -eq 0 ]; then
            read_stats ${SNORTGROUP} ${SNORTPARAM}
        else
            loop_read_stats ${SNORTGROUP} ${SNORTPARAM}
        fi
    fi
elif [ $flag_opt_list -eq 1 ]; then
    # list all param/values pairs of active snort processes
    if [ "x${GROUPLIST}" == "x" ]; then
        read_snort_stats
    else
        for n in ${GROUPLIST}; do
            read_snort_stats $n
        done
    fi
    exit $?
else
    usage
    exit 1
fi


exit 0

## vim:ts=4:sw=4:expandtab:ai:nowrap:formatoptions=croqln:

