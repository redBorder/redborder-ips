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
  segments = [] if segments.nil?
  unless segments.nil?
      files_to_delete = []

      #
      # Construct files_to_delete array
      #
      list_net_conf = Dir.entries("/etc/sysconfig/network-scripts/").select {|f| !File.directory? f}
      list_net_conf.each do |netconf|
        next unless netconf.start_with?"ifcfg-b" # We only need the bridges        
        bridge = netconf.tr("ifcfg-","")

        # If the bridge is not in the yaml file of the init_conf
        # we add to delete the bridge and its interfaces
        if segments.select{|s| s['name'] == bridge}.empty?
          files_to_delete.push("/etc/sysconfig/network-scripts/#{netconf}")
          bridge_interfaces = `grep -rnwl '/etc/sysconfig/network-scripts' -e 'BRIDGE=\"#{bridge}\"'`.split("\n")
          files_to_delete +=  bridge_interfaces
        else
          # If the bridge is in the yaml file of the init_conf we dont need to delete but
          # we need to check if the interfaces that exists are part of the bridge defined
          # those who dont we add them to be deleted
          bridge_interfaces = `grep -rnwl '/etc/sysconfig/network-scripts' -e 'BRIDGE=\"#{bridge}\"'`.split("\n")
          bridge_interfaces.each do |iface_path_file|
            iface = iface_path_file.split("/").last.tr("ifcg-","")
            if segments.select{|s| s['name'] == bridge and s['ports'].include?iface}.empty?
              files_to_delete.push(iface_path_file)
            end
          end
        end
      end
      
      #
      # Remove bridges and delete related files
      #
      files_to_delete.each do |iface_path_file|
        # Get the interface name from the file path
        iface = iface_path_file.split("/").last.tr("ifcg-","")
        # Put the interface down
        puts "Stopping dev #{iface} .."
        system("ip link set dev #{iface} down")

        # If the interface is also a bridge we delete with ip link del
        # TODO: Check if with checking that start with b is enough to know if is a bridge
        if iface.start_with?"b"
          puts "Deleting dev bridge #{iface}"
          system("ip link del #{iface}") 
        end
        
        # Remove the files from /etc/sysconfig/network-scripts directory
        File.delete(iface_path_file) if File.exist?(iface_path_file)
      end

      # Create segments
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

        # Add each port (interface) to the segment
        segment["ports"].each do |iface|
          open("/etc/sysconfig/network-scripts/ifcfg-#{iface}", 'w') { |f|
            f.puts "DEVICE=\"#{iface}\""
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
