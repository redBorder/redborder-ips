#!/bin/bash

#######################################################################
# Copyright (c) 2024 ENEO Tecnología S.L.
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
######################################################################

counter=0

interfaces=$(ls /sys/class/net | grep -Ev '^(lo|br)') # Exclude loopback and bridges on rename

udev_rules_file="/etc/udev/rules.d/10-persistent-net.rules"

echo "" > $udev_rules_file

# TODO: check if we really need to rename interfaces
for interface in $interfaces; do
    mac_address=$(cat /sys/class/net/$interface/address)
    new_name="eth$counter"

    ((counter++))

    echo "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"$mac_address\", NAME=\"$new_name\"" >> $udev_rules_file
    echo "Interface $interface will be renamed to $new_name"
done

echo "Please reboot the system to apply the changes."
