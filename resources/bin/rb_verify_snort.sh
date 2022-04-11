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
  echo "USAGE:   $0 path_snort.conf|instancegroupid"
  echo "example: $0 /etc/snort/0/snort.conf"
  echo "example: $0 0"
  echo "example: $0 1"
  exit 0
}

RES_COL=69
MOVE_TO_COL="echo -en \\033[${RES_COL}G"
RAND=""

function set_color() {
  if [ "x$BOOTUP" != "xnone" ]; then
    green="echo -en \\033[1;32m"
    red="echo -en \\033[1;31m"
    yellow="echo -en \\033[1;33m"
    orange="echo -en \\033[0;33m"
    blue="echo -en \\033[1;34m"
    black="echo -en \\033[1;30m"
    white="echo -en \\033[255m"
    cyan="echo -en \\033[0;36m"
    purple="echo -en \\033[0;35m"
    browm="echo -en \\033[0;33m"
    gray="echo -en \\033[0;37m"
    norm="echo -en \\033[1;0m"
    eval \$$1
  fi
}

function e_ok() {
  [ "x$BOOTUP" != "xnone" ] && $MOVE_TO_COL || echo -n "      "
  echo -n "["
  set_color green
  echo -n $"  OK  "
  set_color norm
  echo -n "]"
  [ "x$BOOTUP" != "xnone" ] && echo -ne "\r"
  echo
  return 0
}

function e_fail() {
  [ "x$BOOTUP" != "xnone" ] && $MOVE_TO_COL || echo -n "      "
  echo -n "["
  set_color red
  echo -n $"FAILED"
  set_color norm
  echo -n "]"
  [ "x$BOOTUP" != "xnone" ] && echo -ne "\r"
  echo
  return 1
}

function get_random_group(){
  RAND=$(($RANDOM %1000))
   
  while : ;do
    grep -q "INSTANCES_GROUP=\"$RAND\"" /etc/sysconfig/snort-*
    if [ $? -ne 0 ]; then
      break
    else
      RAND=$(($RANDOM %1000))
    fi
  done
}

ret=0
dir="/tmp/rb_verify_snort$$"

for conf in $*; do
  [ ! -f $conf ] && conf=/etc/snort/$conf/snort.conf
  if [ -f $conf ]; then
    echo "Checking $conf: "
    get_random_group
    rm -rf $dir
    mkdir -p $dir
      if [ $ret -eq 0 ]; then
        echo -n "  - checking Snort configuration (span mode)   "
        nice -n 19 ionice -c2 -n7 env INSTANCES_GROUP=$RAND /usr/bin/snort -T -c $conf -l $dir --perfmon-file $dir/snort.stats -G 0 &>$dir/snort-out.log 
        ret=$?
        if [ $ret -eq 0 ]; then
          e_ok
          echo -n "  - checking Snort configuration (inline mode) "
          nice -n 19 ionice -c2 -n7 env INSTANCES_GROUP=$RAND /usr/bin/snort -T -c $conf -l $dir --perfmon-file $dir/snort.stats -Q -G 0 &>$dir/snort-out.log
          ret=$?
          if [ $ret -eq 0 ]; then
            e_ok
          else
            e_fail
            echo "Last logs: "
            tail -n 5 $dir/snort-out.log
          fi
        else
          e_fail
          echo "Last logs: "
          tail -n 5 $dir/snort-out.log
        fi 
      fi
    rm -rf $dir
    rm -rf /dev/shm/SFShmemMgmt.$RAND.* /dev/shm/SFIPReputation.rt.$RAND.*
  else
    echo "ERROR: file $conf not found"
  fi
done

exit $ret

