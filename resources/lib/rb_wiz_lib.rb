#!/usr/bin/env ruby

require 'mrdialog'
require 'net/ip'
require 'system/getifaddrs'
require 'netaddr'
require 'uri'
require File.join(ENV['RBDIR'].nil? ? '/usr/lib/redborder' : ENV['RBDIR'],'lib/rb_config_utils.rb')

class WizConf

    # Read propierties from sysfs for a network devices
    def netdev_property(devname)
        netdev = {}
        IO.popen("udevadm info -q property -p /sys/class/net/#{devname} 2>/dev/null").each do |line|
            unless line.match(/^(?<key>[^=]*)=(?<value>.*)$/).nil?
                netdev[line.match(/^(?<key>[^=]*)=(?<value>.*)$/)[:key]] = line.match(/^(?<key>[^=]*)=(?<value>.*)$/)[:value]
            end
        end
        if File.exist?"/sys/class/net/#{devname}/address"
            f = File.new("/sys/class/net/#{devname}/address",'r')
            netdev["MAC"] = f.gets.chomp
            f.close
        end
        if File.exist?"/sys/class/net/#{devname}/operstate"
            f = File.new("/sys/class/net/#{devname}/operstate",'r')
            netdev["STATUS"] = f.gets.chomp
            f.close
        end

        netdev
    end

end

# Class to create a Network configuration box
class NetConf < WizConf

    attr_accessor :conf, :cancel

    def initialize
        @cancel = false
        @conf = []
        @confdev = {}
        @devmode = { "dhcp" => "Dynamic", "static" => "Static" }
        @devmodereverse = { "Dynamic" => "dhcp", "Static" => "static" }
    end

    def doit
        dialog = MRDialog.new
        dialog.clear = true
        dialog.title = "CONFIGURE NETWORK"
        loop do
            text = <<EOF

This is the network device configuration box.

Please, choose a network device to configure. Once you
have entered and configured all devices, you must select
last choise (Finalize) and 'Accept' to continue.

Any device not configured will be set to Dynamic (DHCP)
mode by default.

EOF
            items = []
            menu_data = Struct.new(:tag, :item)
            data = menu_data.new
            # loop over list of net devices
            listnetdev = Dir.entries("/sys/class/net/").select {|f| !File.directory? f}
            listnetdev.each do |netdev|
                # loopback and devices with no pci nor mac are not welcome!
                next if netdev == "lo"
                netdevprop = netdev_property(netdev)
                next unless (netdevprop["ID_BUS"] == "pci" and !netdevprop["MAC"].nil?)
                data.tag = netdev
                # set default value
                @confdev[netdev] = {"mode" => "dhcp"} if @confdev[netdev].nil?
                data.item = "MAC: "+netdevprop["MAC"]+", Vendor: "+netdevprop["ID_MODEL_FROM_DATABASE"]
                items.push(data.to_a)
            end
            data.tag = "Finalize"
            data.item = "Finalize network device configuration"
            items.push(data.to_a)
            height = 0
            width = 0
            menu_height = 4
            selected_item = dialog.menu(text, items, height, width, menu_height)

            if selected_item
                unless selected_item == "Finalize"
                    dev = DevConf.new(selected_item)
                    unless @confdev[selected_item].nil?
                        dev.conf = {'IP:' => @confdev[selected_item]["ip"],
                                    'Netmask:' => @confdev[selected_item]["netmask"],
                                    'Gateway:' => @confdev[selected_item]["gateway"],
                                    'Mode:' => @devmode[@confdev[selected_item]["mode"]]}
                    end
                    dev.doit
                    unless dev.conf.empty?
                        @confdev[selected_item] = {}
                        @confdev[selected_item]["mode"] = @devmodereverse[dev.conf['Mode:']]
                        if dev.conf['Mode:'] == "Static"
                            @confdev[selected_item]["ip"] = dev.conf['IP:']
                            @confdev[selected_item]["netmask"] = dev.conf['Netmask:']
                            unless dev.conf['Gateway:'].nil? or dev.conf['Gateway:'].empty?
                                @confdev[selected_item]["gateway"] = dev.conf['Gateway:']
                            else
                                @confdev[selected_item]["gateway"] = ""
                            end

                        end
                    end
                else
                    break
                end
            else
                # Cancel pressed
                @cancel = true
                break
            end
        end
        @confdev.each_key do |interface|
            @conf << @confdev[interface].merge("device" => interface)
        end
    end
end

class DevConf < WizConf

    attr_accessor :device_name, :conf, :cancel

    def initialize(x)
        @cancel = false
        @device_name = x
        @conf = {}
    end

    def doit
        # first, set mode dynamic or static
        dialog = MRDialog.new
        dialog.clear = true
        text = <<EOF

Please, select type of configuration:

Dynamic: set dynamic IP/Netmask and Gateway
         via DHCP client.
Static: You will provide configuration for
        IP/Netmask and Gateway, if needed.

EOF
        items = []
        radiolist_data = Struct.new(:tag, :item, :select)
        data = radiolist_data.new
        data.tag = "Dynamic"
        data.item = "IP/Netmask and Gateway via DHCP"
        if @conf['Mode:'].nil?
            data.select = true # default
        else
            if @conf['Mode:'] == "Dynamic"
                data.select = true
            else
                data.select = false
            end
        end
        items.push(data.to_a)

        data = radiolist_data.new
        data.tag = "Static"
        data.item = "IP/Netamsk and Gateway static values"
        if @conf['Mode:'].nil?
            data.select = false # default
        else
            if @conf['Mode:'] == "Static"
                data.select = true
            else
                data.select = false
            end
        end
        items.push(data.to_a)

        dialog.title = "Network Device Mode"
        selected_item = dialog.radiolist(text, items)
        exit_code = dialog.exit_code

        case exit_code
        when dialog.dialog_ok
            # OK Pressed

            # TODO ipv6 support
            if selected_item == "Static"
                dialog = MRDialog.new
                dialog.clear = true
                text = <<EOF

You are about to configure the network device #{@device_name}. It has the following propierties:
EOF
                netdevprop = netdev_property(@device_name)

                text += " \n"
                text += "MAC: #{netdevprop["MAC"]}\n"
                text += "DRIVER: #{netdevprop["ID_NET_DRIVER"]}\n" unless netdevprop["ID_NET_DRIVER"].nil?
                text += "PCI PATH: #{netdevprop["ID_PATH"]}\n" unless netdevprop["ID_PATH"].nil?
                text += "VENDOR: #{netdevprop["ID_VENDOR_FROM_DATABASE"]}\n" unless netdevprop["ID_VENDOR_FROM_DATABASE"].nil?
                text += "MODEL: #{netdevprop["ID_MODEL_FROM_DATABASE"]}\n" unless netdevprop["ID_MODEL_FROM_DATABASE"].nil?
                text += "STATUS: #{netdevprop["STATUS"]}\n" unless netdevprop["STATUS"].nil?
                text += " \n"

                @conf['IP:'] = Config_utils.get_ipv4_network(@device_name)[:ip] if @conf['IP:'].nil?
                @conf['Netmask:'] = Config_utils.get_ipv4_network(@device_name)[:netmask] if @conf['Netmask:'].nil?
                @conf['Gateway:'] = Config_utils.get_ipv4_network(@device_name)[:gateway] if @conf['Gateway:'].nil?

                flen = 20
                form_data = Struct.new(:label, :ly, :lx, :item, :iy, :ix, :flen, :ilen)

                loop do
                    items = []
                    label = "IP:"
                    data = form_data.new
                    data.label = label
                    data.ly = 1
                    data.lx = 1
                    data.item = @conf[label]
                    data.iy = 1
                    data.ix = 10
                    data.flen = flen
                    data.ilen = 0
                    items.push(data.to_a)

                    label = "Netmask:"
                    data = form_data.new
                    data.label = label
                    data.ly = 2
                    data.lx = 1
                    data.item = @conf[label]
                    data.iy = 2
                    data.ix = 10
                    data.flen = flen
                    data.ilen = 0
                    items.push(data.to_a)

                    label = "Gateway:"
                    data = form_data.new
                    data.label = label
                    data.ly = 3
                    data.lx = 1
                    data.item = @conf[label]
                    data.iy = 3
                    data.ix = 10
                    data.flen = flen
                    data.ilen = 0
                    items.push(data.to_a)

                    dialog.title = "Network configuration for #{@device_name}"
                    @conf = dialog.form(text, items, 20, 60, 0)

                    # need to check result
                    ret = true
                    if @conf.empty?
                        # Cancel was pressed
                        break
                    else
                        # ok pressed
                        @conf['Mode:'] = "Static"
                        if Config_utils.check_ipv4({:ip => @conf['IP:']}) and Config_utils.check_ipv4({:netmask => @conf['Netmask:']})
                            # seems to be ok
                            unless @conf['Gateway:'] == ""
                                if Config_utils.check_ipv4({:ip => @conf['Gateway:']})
                                    # seems to be ok
                                    ret = false
                                end
                            else
                                ret = false
                            end
                        else
                            # error!
                            ret = true
                        end
                    end
                    if ret
                        # error detected
                        dialog = MRDialog.new
                        dialog.clear = true
                        dialog.title = "ERROR in network configuration"
                        text = <<EOF

We have detected an error in network configuration.

Please, review IP/Netmask and/or Gateway address configuration.
EOF
                        dialog.msgbox(text, 10, 41)
                    else
                        # all it is ok, breaking loop
                        break
                    end
                end
            else
                # selected_item == "Dynamic"
                @conf['Mode:'] = "Dynamic"
            end

        when dialog.dialog_cancel
            # Cancel Pressed

        when dialog.dialog_esc
            # Escape Pressed

        end


    end

end

class CloudAddressConf < WizConf

    attr_accessor :conf, :cancel

    def initialize()
        @cancel = false
        @conf = {}
    end

    def doit

        host = {}
        @conf["Cloud address:"] = "rblive.redborder.com"
        
        loop do
            dialog = MRDialog.new
            dialog.clear = true
            dialog.insecure = true
            text = <<EOF

Please, set cloud address of the redborder manager.

Don't use http:// or https:// in front, introduce the url domain name of the manager.

EOF
            items = []
            form_data = Struct.new(:label, :ly, :lx, :item, :iy, :ix, :flen, :ilen, :attr)

            items = []
            label = "Cloud address:"
            data = form_data.new
            data.label = label
            data.ly = 1
            data.lx = 1
            data.item = @conf[label]
            data.iy = 1
            data.ix = 16
            data.flen = 253
            data.ilen = 0
            data.attr = 0
            items.push(data.to_a)

            dialog.title = "Cloud address configuration"
            host = dialog.mixedform(text, items, 24, 60, 0)

            if host.empty?
                # Cancel button pushed
                @cancel = true
                break
            else
                if Config_utils.check_cloud_address(host["Cloud address:"])
                    # need to confirm lenght
                    if (host["Cloud address:"].length < 254)
                        break
                    end
                end
            end

            # error, do another loop
            dialog = MRDialog.new
            dialog.clear = true
            dialog.title = "ERROR in name configuration"
            text = <<EOF

We have detected an error in cloud address configuration.

Please, review character set and length for name configuration.
EOF
            dialog.msgbox(text, 10, 41)

        end

        @conf[:cloud_address] = host["Cloud address:"]

    end

end

class DNSConf < WizConf

    attr_accessor :conf, :cancel

    def initialize()
        @cancel = false
        @conf = []
    end

    def doit

        dns = {}
        count=1
        @conf.each do |x|
            dns["DNS#{count}:"] = x
            count+=1
        end

        loop do
            dialog = MRDialog.new
            dialog.clear = true
            dialog.insecure = true
            text = <<EOF

Please, set DNS servers.

You can set up to 3 DNS servers, but only one is mandatory. Set DNS values in order, first, second (optional) and then third (optional).

Please, insert each value fo IPv4 address in dot notation.

EOF
            items = []
            form_data = Struct.new(:label, :ly, :lx, :item, :iy, :ix, :flen, :ilen, :attr)

            items = []
            label = "DNS1:"
            data = form_data.new
            data.label = label
            data.ly = 1
            data.lx = 1
            data.item = dns[label]
            data.iy = 1
            data.ix = 8
            data.flen = 16
            data.ilen = 0
            data.attr = 0
            items.push(data.to_a)

            label = "DNS2:"
            data = form_data.new
            data.label = label
            data.ly = 2
            data.lx = 1
            data.item = dns[label]
            data.iy = 2
            data.ix = 8
            data.flen = 16
            data.ilen = 0
            data.attr = 0
            items.push(data.to_a)

            label = "DNS3:"
            data = form_data.new
            data.label = label
            data.ly = 3
            data.lx = 1
            data.item = dns[label]
            data.iy = 3
            data.ix = 8
            data.flen = 16
            data.ilen = 0
            data.attr = 0
            items.push(data.to_a)

            dialog.title = "DNS configuration"
            dns = dialog.mixedform(text, items, 20, 42, 0)

            if dns.empty?
                # Cancel button pushed
                @cancel = true
                break
            else
                if Config_utils.check_ipv4({:ip=>dns["DNS1:"]})
                    unless dns["DNS2:"].empty?
                        if Config_utils.check_ipv4({:ip=>dns["DNS2:"]})
                            unless dns["DNS3:"].empty?
                                if Config_utils.check_ipv4({:ip=>dns["DNS3:"]})
                                    break
                                end
                            else
                                break
                            end
                        end
                    else
                        break
                    end
                end
            end

            # error, do another loop
            dialog = MRDialog.new
            dialog.clear = true
            dialog.title = "ERROR in DNS or search configuration"
            text = <<EOF

We have detected an error in DNS configuration.

Please, review content for DNS configuration. Remember, you
must introduce only IPv4 address in dot notation.
EOF
            dialog.msgbox(text, 12, 41)

        end

        unless dns.empty?
            @conf << dns["DNS1:"]
            unless dns["DNS2:"].empty?
                @conf << dns["DNS2:"]
                unless dns["DNS3:"].empty?
                    @conf << dns["DNS3:"]
                end
            end
        end

    end

end

## vim:ts=4:sw=4:expandtab:ai:nowrap:formatoptions=croqln:
