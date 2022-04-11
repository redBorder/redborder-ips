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

SEGMENT=""
STATUS=""
RET=2
RESTART_CHEF=0
GETBYPASS=0

function usage(){
    echo "ERROR: $0 -b [bpbrX|all] -s [on|off] [ -r ] [ -g ]"
    echo "    -b [bpbrX|all] -> segment to actuate"
    echo "    -s [on|off]    -> bypass mode"
    echo "    -r             -> if enabled it will wake up chef-client"
    echo "    -g             -> get the bypass mode"
    exit 2
}

while getopts "b:s:hrg" opt; do
  case $opt in
    b) SEGMENTS=$OPTARG;;
    s) STATUS=$OPTARG;;
    r) RESTART_CHEF=1;;
    g) GETBYPASS=1;;
    h) usage;;
  esac
done

if [ "x$SEGMENTS" == "xall" ]; then
    SEGMENTS="$(ls -d /sys/class/net/bpbr[0-9]* /sys/class/net/br[0-9]* 2>/dev/null | sed 's%/sys/class/net/%%')"
fi

if [ "x$SEGMENTS" != "x" -a "x$STATUS" == "xon" -o "x$STATUS" == "xoff" -o $GETBYPASS -eq 1 ]; then
    for segment in $SEGMENTS; do
        echo "$segment" | egrep -q "^bpbr[[:digit:]]+$"
        if [ $? -ne 0 ]; then
            echo "$segment" | egrep -q "^br[[:digit:]]+$"
            if [ $? -ne 0 ]; then
                usage
            fi
        fi
    done
    for segment in $SEGMENTS; do
        echo "$segment" | egrep -q "^bpbr[[:digit:]]+$"
        if [ $? -eq 0 ]; then
            MASTER=`ls /sys/class/net/$segment/brif|head -n 1`
            for port in $(ls /sys/class/net/$segment/brif); do
                echo "$port" | egrep -q "^eth[[:digit:]]+$|^dna[[:digit:]]+$"
                /usr/sbin/bin/bpctl_util $port is_bypass | grep -q "The interface is a control interface"
                if [ $? -eq 0 ]; then
                    MASTER=$port
                    break
                fi
            done
            if [ "x$MASTER" != "x"  ]; then
                echo "$MASTER" | egrep -q "^eth[[:digit:]]+$|^dna[[:digit:]]+$"
                if [ $? -eq 0 ]; then
                    if [ $GETBYPASS -eq 1 ]; then
                        echo -n "$segment ($MASTER): "
                        OUT=$(/usr/sbin/bin/bpctl_util $MASTER get_bypass)
                        echo $OUT
                        echo $OUT | grep -q " is in the Bypass mode.$"
                        if [ $? -eq 0 ]; then
                          RET=1
                        else
                          RET=0
                        fi
                    else
                        echo -n "Changing bypass for $segment ($MASTER): "
                        OUT=$(/usr/sbin/bin/bpctl_util $MASTER set_bypass $STATUS)
                        echo $OUT | grep -q " completed successfully."
                        RET=$?
                        echo $OUT
                        [ $RESTART_CHEF -eq 1 ] && /usr/lib/redborder/bin/rb_wakeup_chef.sh

                    fi
                else
                    echo "ERROR: The iface $MASTER is not valid iface"
                fi
            else
                echo "ERROR: cannot detect master iface for $segment"
            fi
        else
            echo "$segment" | egrep -q "^br[[:digit:]]+$"
            if [ $? -eq 0 ]; then
                if [ "x$STATUS" == "xon" ]; then
                    echo -n "Changing status for $segment (up): "
                    ip l set up $segment
                else
                    echo -n "Changing status for $segment (down): "
                    ip l set down $segment
                fi
            else
                usage
            fi
        fi
    done
else
    usage
fi

exit $RET

## vim:ts=4:sw=4:expandtab:ai:nowrap:formatoptions=croqln:
