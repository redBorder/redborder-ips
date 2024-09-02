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

function usage(){
    echo "ERROR: $0 [-w pcap_file][-n <group_name>][-g gid][-s sid][-l timestamp][-u timestamp][-o origin][-d destination][-v][-p]"
    exit 1
}

#set -x

tmpdir="/tmp/rb_u2pcap$$" 
trap "rm -rf $tmpdir" EXIT

pcapfile=""
groups=""
group=""
gid=""
sid=""
ltime=""
utime=""
origin=""
destination=""
verbose=0
printcmd=0
separator="---------------------------------------------------------------------------------------------------------"

while getopts "hn:w:g:s:l:u:o:d:vp" opt; do
  case $opt in
    w) pcapfile=$OPTARG;;
    n) group=$OPTARG;;
    g) gid=$OPTARG;;
    s) sid=$OPTARG;;
    l) ltime=$OPTARG;;
    u) utime=$OPTARG;;
    o) origin=$OPTARG;;
    d) destination=$OPTARG;;
    h) usage;;
    v) verbose=1;;
    p) printcmd=1;;
  esac
done

if [ $printcmd -eq 1 ]; then
  echo "$separator"
  echo
  echo "rb_u2pcap.sh $*"
fi

u2boat_cmd=""

[ "x$gid" != "x" ] && u2boat_cmd="$u2boat_cmd -g $gid"
[ "x$sid" != "x" ] && u2boat_cmd="$u2boat_cmd -s $sid"
[ "x$ltime" != "x" ] && u2boat_cmd="$u2boat_cmd -l $ltime"
[ "x$utime" != "x" ] && u2boat_cmd="$u2boat_cmd -u $utime"
[ "x$origin" != "x" ] && u2boat_cmd="$u2boat_cmd -o $origin"
[ "x$destination" != "x" ] && u2boat_cmd="$u2boat_cmd -d $destination"

if [ "x$group" == "x" ]; then
  for n in $(ls -d /etc/snort/* 2>/dev/null); do
    groups="$groups $(basename $n)"
  done
else
  for n in $(ls /etc/sysconfig/snort-* 2>/dev/null); do
    source $n
    if [ "x$INSTANCES_GROUP_NAME" == "x$group" ]; then
      groups="$groups $INSTANCES_GROUP"
    fi
  done
fi

if [ "x$groups" == "x" ]; then
  echo "ERROR: not valid IPS groups"
else
  uni2="$tmpdir/complete_u2"
  rm -rf $tmpdir
  mkdir -p $tmpdir
  touch $uni2

  files=""

  [ $verbose -eq 1 ] && echo "Reading unified2 files: "
  if [ "x$ltime" != "x" -o  "x$utime" != "x" ]; then
    now=$(date '+%s')
    if [ "x$ltime" != "x" ]; then
      #limit_lower=$(( $ltime - 60 ))
      limit_lower=$( echo "${ltime} - ${ltime}%60" | bc )
    else
      ltime=0
      limit_lower=0
    fi

    if [ "x$utime" != "x" ]; then
      #limit_upper=$(( $utime + 60 ))
      limit_upper=$( echo "${utime} + 60 - ${utime}%60" | bc )
    else
      utime=99999999999
      limit_upper=99999999999
    fi

    for g in $groups; do
      for instance in $(ls -d /var/log/snort/$g/* 2>/dev/null); do 
        flag1=0
        flag2=0
        for filetime in $(ls $instance/snort.log.*[0-9] $instance/archive/snort.log.*[0-9] 2>/dev/null | sed 's/.*snort\.log\.//' | sort -r); do
          if [ $flag1 -eq 0 -o $flag2 -eq 0 ]; then
            if [ $filetime -le $ltime -o $filetime -le $limit_lower -o $filetime -le $utime -o $filetime -le $limit_upper ]; then
              fileexist=0
              if [ -f $instance/snort.log.$filetime ]; then
                fileexist=1
                files="$files $instance/snort.log.$filetime"
              fi
              if [ -f $instance/archive/snort.log.$filetime ]; then
                fileexist=1
                files="$files $instance/archive/snort.log.$filetime"
              fi
              if [ $fileexist -eq 1 ]; then
                [ $filetime -lt $ltime -a $filetime -lt $limit_lower ] && flag1=1
                [ $filetime -lt $utime -a $filetime -lt $limit_upper ] && flag2=1
              fi
            fi
          fi
        done
      done
    done  
  else
    for g in $groups; do 
      for n in $(ls /var/log/snort/$g/instance-*/snort.log.*[0-9] 2>/dev/null); do
        files="$files $n"
      done
    done 
  
    for g in $groups; do 
      for n in $(ls /var/log/snort/$g/instance-*/archive/snort.log.*[0-9] 2>/dev/null); do
        files="$files $n"
      done
    done 
  fi
    
  if [ "x$pcapfile" != "x" ]; then
    for n in $files; do      
      [ $verbose -eq 1 ] && echo "    * $n"
      nice -n 19 ionice -c2 -n7 cat $n >> $uni2
    done

   # if [ -f $uni2 ]; then
   #   echo "Generating pcap on $pcapfile"
      #nice -n 19 ionice -c2 -n7 /usr/bin/u2boat $u2boat_cmd -t pcap $uni2 $pcapfile #u2boat_cmd filter is not working anymore
   # else
   #   echo "ERROR: file $uni2 not found!"
   # fi
  else
    for n in $files; do      
      [ $verbose -eq 1 ] && echo "    * $n"
      nice -n 19 ionice -c2 -n7 /usr/bin/u2spewfoo $n | sed "s/^(IPv6 Event)$/$separator\n\n(IPv6 Event)/" | sed "s/^(Event)$/$separator\n\n(Event)/" | awk -v sig_id_param="$sid" -v gen_id_param="$gid" -v ip_source_param="$origin" -v ip_dest_param="$destination" -v start_param="$ltime" -v end_param="$utime" '
/^\(Event\)/ {
    # Init capturing block and print previous
    if (found && capture) {
        print block
        print packet_block
    }
    block = $0
    start_packet_block = 0
    packet_block = ""
    capture = 1
    found = 0
    next
}

/^\tsensor id:/ && capture {
    #Get event second
    event_second = $9
    block = block ORS $0
    next
}

/^\tsig id:/ && capture {
    #Get sig and gid
    sig_id = $3
    gen_id = $6
    block = block ORS $0
    next
}

/^\tpriority:/ && capture {
    # Get origin and destination
    ip_source = $5
    ip_dest = $8
    block = block ORS $0

    # Verify values
    if (ip_source == ip_source_param && ip_dest == ip_dest_param && sig_id == sig_id_param && gen_id == gen_id_param && event_second >= start_param && event_second <= end_param) {
        found = 1
    }
    next
}

/^Packet/ && capture {
    # Init Capture packet
    start_packet_block = 1
    packet_block = $0
    next
}

start_packet_block && capture {
    # capture packet
    packet_block = packet_block ORS $0
    next
}

capture {
 block = block ORS $0
 next
}

END {
    # Print blocks
    if (found && capture) {
        print block
        print packet_block
    }
}
'
    done
    echo "$separator"
    echo
  fi
  rm -rf $tmpdir
fi
