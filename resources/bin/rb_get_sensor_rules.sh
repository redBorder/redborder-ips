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

source /etc/profile.d/rvm.sh
source /etc/profile.d/redborder*

PID=$(ps aux |grep /usr/lib/redborder/bin/rb_get_sensor_rules.rb |grep -v grep | grep -v vim | awk '{print $2}')

if [ "x$PID" == "x" ]; then
  if [ "x$*" == "x" ]; then
    pushd /etc/snort &>/dev/null
    counter=0
    for g in $(ls * -d 2>/dev/null | sort -n); do
      for n in $(ls -d /etc/snort/$g/snort-binding-* 2>/dev/null | sort); do
        file="${n}/rb_get_sensor_rules.sh"
        [ $counter -ne 0 ] && echo "--"
        if [ -f $file ]; then
          /bin/env BOOTUP=none bash $file
        else
          echo "$(dirname $file) has never been compiled!!"
        fi
        counter=$(( $counter + 1 ))
      done
    done
    popd &>/dev/null
  else
    /usr/lib/redborder/bin/rb_get_sensor_rules $*
  fi
else
  echo "There is other instance running ($PID). Exiting!"
fi
