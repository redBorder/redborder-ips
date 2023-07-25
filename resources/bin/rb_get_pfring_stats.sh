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

function usage() {
  echo "$0 -p pf_ring_param [ -h ]"
  echo "Example1: rb_get_pfring_stats.sh -p 'Reflect: Fwd Errors'"
  exit 1
}

function isnum() {
    return `echo "$1" | awk -F"\n" '{print ($0 != $0+0)}'`
}

monitor_param=""

while getopts "hp:" opt; do
  case $opt in
    p) monitor_param=$OPTARG ;;
    h) usage ;;
  esac
done

if [ "x$monitor_param" == "x" ]; then
  usage
fi

interfaces_ids_max=$(ip a |grep "eth" |grep : | grep state |wc -l)

[ "x$interfaces_ids_max" == "x" ] && interfaces_ids_max=0

output=""

for index in $(seq 1 $interfaces_ids_max); do 
  n=$(($index -1))
  count=0

  for pfile in $(ls /proc/net/pf_ring/*-eth${n}.*  2>/dev/null ); do
    value=$(grep "${monitor_param}" $pfile |head -n 1| sed 's/.*: //')
    if [ "x$value" != "x" ]; then
      isnum $value
      if [ $? -eq 0 ]; then
        count=$( echo "$count + $value " | bc )
      fi
    fi
  done
  [ $n -ne 0 ] && output="$output;"
  output="${output}${count}"
done

echo $output
