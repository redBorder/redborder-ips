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

# Create file with bash env variables
open("/etc/redborder/rb_init_conf.conf", "w") { |f|
  f.puts "#REBORDER ENV VARIABLES"
}

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
  system("/usr/lib/redborder/bin/rb_register_url.sh -u #{cloud_address} #{IPSOPTS}")
else
  p err_msg = "Invalid cloud address. Please review #{INITCONF} file"
  exit 1
end
