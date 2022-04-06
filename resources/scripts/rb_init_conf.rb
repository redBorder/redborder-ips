#!/usr/bin/env ruby

# Run initial server configuration from /etc/redborder/rb_init_conf.yml
# 1. Set hostname + cdomain
# 2. Configure network (on-premise only)
# 3. Configure dns (on-premise only)
# 4. Create serf configuration files
#
# note: Don't calculate encrypt_key

require 'yaml'
require 'ipaddr'
require 'netaddr'
require 'system/getifaddrs'
require 'json'
require File.join(ENV['RBLIB'].nil? ? '/usr/lib/redborder/lib' : ENV['RBLIB'],'rb_config_utils.rb')

RBETC = ENV['RBETC'].nil? ? '/etc/redborder' : ENV['RBETC']
INITCONF="#{RBETC}/rb_init_conf.yml"

init_conf = YAML.load_file(INITCONF)

cloud_address = init_conf['cloud_address']

network = init_conf['network']

segments = init_conf['segments']

# Create file with bash env variables
open("/etc/redborder/rb_init_conf.conf", "w") { |f|
  f.puts "#REBORDER ENV VARIABLES"
}


####################
# Set NETWORK      #
####################

unless network.nil? # network will not be defined in cloud deployments

  # Disable and stop NetworkManager
  system('systemctl disable NetworkManager &> /dev/null')
  system('systemctl stop NetworkManager &> /dev/null')

  # Configure DNS
  unless network['dns'].nil?
    dns = network['dns']
    open("/etc/sysconfig/network", "w") { |f|
      dns.each_with_index do |dns_ip, i|
        if Config_utils.check_ipv4({:ip => dns_ip})
          f.puts "DNS#{i+1}=#{dns_ip}"
        else
          p err_msg = "Invalid DNS Address. Please review #{INITCONF} file"
          exit 1
        end
      end
      #f.puts "SEARCH=#{cdomain}" TODO: check if this is needed.
    }
  end

  unless segments.nil?
      files_to_delete = []
      list_net_conf = Dir.entries("/etc/sysconfig/network-scripts/").select {|f| !File.directory? f}
      list_net_conf.each do |netconf|
        next unless netconf.start_with?"ifcfg-b"
        path_to_file = "/etc/sysconfig/network-scripts/#{netconf}"
        bridge_name = netconf.tr("ifcfg-","")
        if segments.select{|s| s['name'] == bridge_name}.empty?
          files_to_delete.push(path_to_file)
          # Add to delete the interface that are not part of the bridge
          devs_with_same_bridge = `grep -rnwl '/etc/sysconfig/network-scripts' -e 'BRIDGE=\"#{bridge_name}\"'`.split("\n")
          devs_with_same_bridge.each do |path_name|
            files_to_delete.push(path_dev)
          end
          files_to_delete = files_to_delete + devs_with_same_bridge
        else
          # We need to check if the interfaces are ok
          devs_with_same_bridge = `grep -rnwl '/etc/sysconfig/network-scripts' -e 'BRIDGE=\"#{bridge_name}\"'`.split("\n")
          devs_with_same_bridge.each do |path_dev|
            dev_name = path_dev.split("/").last.tr("ifcg-","")
            if segments.select{|s| s['name'] == bridge_name and s['ports'].include?dev_name}.empty?
              files_to_delete.push(path_dev)
            end
          end
        end
      end
      
      
      # Remove bridges and delete related files
      files_to_delete.each do |path_to_file|
        dev_name = path_to_file.split("/").last.tr("ifcg-","")
        system("ip link set dev #{dev_name} down")
        system("ip link del #{dev_name}") if dev_name.start_with?"ifcfg-b"

        puts "Delete file #{path_to_file}"
        File.delete(path_to_file) if File.exist?(path_to_file)
      end


      segments.each do |segment|
        # Creation of segment file
        open("/etc/sysconfig/network-scripts/ifcfg-#{segment['name']}", 'w') { |f|
          f.puts "DEVICE=#{segment['name']}"
          f.puts "TYPE=Bridge"
          f.puts "BOTPROTO=none"
          f.puts "ONBOOT=yes"
          f.puts "IPV6_AUTOCONF=no"
          f.puts "IPV6INIT=no"
          f.puts "DELAY=0"
          f.puts "STP=off"
        }
        # Add each port to the segment
        segment["ports"].each do |port|
          open("/etc/sysconfig/network-scripts/ifcfg-#{port}", 'w') { |f|
            f.puts "DEVICE=\"#{port}\""
            f.puts "BRIDGE=\"#{segment['name']}\""
            f.puts "TYPE=Ethernet"
            # TODO: ADD MAC
            #f.puts "HWADDR=\"00:e0:ed:29:f0:f1\""
            f.puts "BOOTPROTO=none"
            f.puts "NM_CONTROLLED=\"no\""
            f.puts "ONBOOT=\"yes\""
            f.puts "IPV6_AUTOCONF=no"
            f.puts "IPV6INIT=no"
            f.puts "DELAY=0"
            f.puts "STP=off"
          }
        end
      end
  end

  # Configure NETWORK
  network['interfaces'].each do |iface|
    dev = iface['device']
    iface_mode = iface['mode']
    open("/etc/sysconfig/network-scripts/ifcfg-#{dev}", 'w') { |f|
      if iface_mode != 'dhcp'
        if Config_utils.check_ipv4({:ip => iface['ip'], :netmask => iface['netmask']})  and Config_utils.check_ipv4(:ip => iface['gateway'])
          f.puts "IPADDR=#{iface['ip']}"
          f.puts "NETMASK=#{iface['netmask']}"
          f.puts "GATEWAY=#{iface['gateway']}" unless iface['gateway'].nil?
        else
          p err_msg = "Invalid network configuration for device #{dev}. Please review #{INITCONF} file"
          exit 1
        end
      end
      dev_uuid = File.read("/proc/sys/kernel/random/uuid").chomp
      f.puts "BOOTPROTO=#{iface_mode}"
      f.puts "DEVICE=#{dev}"
      f.puts "ONBOOT=yes"
      f.puts "UUID=#{dev_uuid}"
    }
  end

  # Restart NetworkManager
  system('service network restart &> /dev/null')
end

# TODO: check network connectivity. Try to resolve repo.redborder.com


####################
# Set UTC timezone #
####################

system("timedatectl set-timezone UTC")
system("ntpdate pool.ntp.org")


#Firewall rules
if !network.nil? #Firewall rules are not needed in cloud environments

  # Add rules here
  
  # Reload firewalld configuration
  # system("firewall-cmd --reload &>/dev/null")

end

# Upgrade system
system('yum install systemd -y')

###########################
# configure cloud address #
###########################
if Config_utils.check_cloud_address(cloud_address)
  IPSOPTS="-t ips -i -d -f"
  #system("/usr/lib/redborder/bin/rb_register_url.sh -u #{cloud_address} #{IPSOPTS}")
else
  p err_msg = "Invalid cloud address. Please review #{INITCONF} file"
  exit 1
end
