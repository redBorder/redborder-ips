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
require "getopt/std"
require File.join(ENV['RBLIB'].nil? ? '/usr/lib/redborder/lib' : ENV['RBLIB'],'rb_config_utils.rb')

RBETC = ENV['RBETC'].nil? ? '/etc/redborder' : ENV['RBETC']
INITCONF="#{RBETC}/rb_init_conf.yml"

def local_tty_warning_wizard
  puts "[!] Error: This device must be configured under local tty"
  exit 1
end

opt = Getopt::Std.getopts("hrf")
if opt["h"] 
  printf "rb_init_conf [-r] \n"
  printf "    -r                -> register sensor with manager\n"
  printf "    -f                -> force configure in non local tty\n"
  exit 1
end

# Run the wizard only in local tty
local_tty_warning_wizard unless Config_utils.is_local_tty or opt["f"]

init_conf = YAML.load_file(INITCONF)

registration_mode = init_conf['registration_mode']

if registration_mode == "proxy"
  cloud_address = init_conf['cloud_address']
else
  webui_host = init_conf['webui_host']

  webui_user = init_conf['webui_user']

  webui_pass = init_conf['webui_pass']

  ips_node_name = init_conf['ips_node_name']
end

network = init_conf['network']

ipmi = init_conf['ipmi']

segments = init_conf['segments']

management_interface = init_conf['network']['management_interface'] if init_conf['network'] && init_conf['network']['management_interface']

# Create file with bash env variables
open("/etc/redborder/rb_init_conf.conf", "w") { |f|
  f.puts "#REBORDER ENV VARIABLES"
}

# Apply config preparation
#system('systemctl stop chef-client &>/dev/null')
system('service snortd stop &>/dev/null') if File.exists?("/etc/rc.d/init.d/snortd")
# TODO: /etc/sysconfig/network-scripts/ifcfg-* is needed?
system('service kdump stop &>/dev/null')
# TODO: rm -f /etc/sysconfig/network-scripts/route-* is needed?

#
# Configuration of /etc/modprobe.d/redBorder.conf
#
system('rm -f /etc/modprobe.d/redBorder.conf')

num_segments = segments.nil? ? 0 : segments.count
num_slots = Config_utils.get_pf_ring_num_slots(num_segments)
pfring_bypass_interfaces = Config_utils.get_pf_ring_bypass_interfaces
puts "Updating pf_ring module configuration.."
system('modprobe -r pf_ring')

system('modinfo pf_ring | grep -q bypass_interfaces')
if $?.success?
  `echo "options pf_ring enable_tx_capture=0 enable_frag_coherence=1 min_num_slots=#{num_slots} bypass_interfaces=#{pfring_bypass_interfaces.join(',')}" >> /etc/modprobe.d/redBorder.conf`
else
  `echo "options pf_ring enable_tx_capture=0 enable_frag_coherence=1 min_num_slots=#{num_slots}" >> /etc/modprobe.d/redBorder.conf`
end

# Set igb RSS value to 0 for an automatic managing of queues
`echo "options igb RSS=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0" > /etc/modprobe.d/redBorderStatic.conf`

open("/etc/depmod.d/kmod-redBorder.conf", 'w') { |f|
  f.puts "# depmod.conf"
  f.puts "#"
  f.puts "# redBorder depmod configuration"
  f.puts "# override default search ordering for kmod packaging"
  f.puts "override bpctl_mod * weak-updates/bpctl_mod"
  f.puts "override pf_ring   * weak-updates/pf_ring"
  f.puts "override ixgbe * weak-updates/ixgbe"
}

system('depmod')
system('modprobe pf_ring')
sleep 3

####################
# Set IPMI         #
####################
unless ipmi.nil? or ipmi.empty?
  net_ipmi_ip = ipmi['ip'] rescue nil
  net_ipmi_netmask = ipmi['netmask'] rescue nil
  net_ipmi_gateway = ipmi['gatway'] rescue nil

  puts "Applying IPMI settings ..."

  system("ipmitool lan set 1 ipsrc static")
  system("ipmitool lan set 1 ipaddr #{net_ipmi_ip}") if net_ipmi_ip
  system("ipmitool lan set 1 netmask #{net_ipmi_netmask}") if net_ipmi_netmask
  system("ipmitool lan set 1 defgw ipaddr #{net_ipmi_gateway}") if net_ipmi_gateway
  system("ipmitool sol set force-encryption true 1")
  system("ipmitool sol set force-authentication true 1")
  system("ipmitool sol set character-accumulate-level 10 1")
  system("ipmitool sol set character-send-threshold 100 1")
  system("ipmitool sol set volatile-bit-rate 115.2 1")
  system("ipmitool sol set non-volatile-bit-rate 115.2 1")

  puts "IPMI Configuration completed"
end
####################
# Set NETWORK      #
####################

unless network.nil? # network will not be defined in cloud deployments

  # Disable and stop NetworkManager
  system('systemctl disable NetworkManager &> /dev/null')
  system('systemctl stop NetworkManager &> /dev/null')

  # Enable network service
  system('systemctl enable network &> /dev/null')
  system('systemctl start network &> /dev/null')

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

  # Delete old segmetns
  files_to_delete = []

  #
  # Construct files_to_delete array
  #
  list_net_conf = Dir.entries("/etc/sysconfig/network-scripts/").select {|f| !File.directory? f}
  list_net_conf.each do |netconf|
    next unless netconf.start_with?"ifcfg-b" # We only need the bridges        
    bridge = netconf.gsub("ifcfg-","")

    # If the bridge is not in the yaml file of the init_conf
    # we add to delete the bridge and its interfaces
    if segments.nil? or segments.select{|s| s['name'] == bridge}.empty?
      files_to_delete.push("/etc/sysconfig/network-scripts/#{netconf}")
      bridge_interfaces = `grep -rnwl '/etc/sysconfig/network-scripts' -e 'BRIDGE=\"#{bridge}\"'`.split("\n")
      files_to_delete +=  bridge_interfaces
    else
      # If the bridge is in the yaml file of the init_conf we dont need to delete but
      # we need to check if the interfaces that exists are part of the bridge defined
      # those who dont we add them to be deleted
      bridge_interfaces = `grep -rnwl '/etc/sysconfig/network-scripts' -e 'BRIDGE=\"#{bridge}\"'`.split("\n")
      bridge_interfaces.each do |iface_path_file|
        iface = iface_path_file.split("/").last.gsub("ifcfg-","")
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
    iface = iface_path_file.split("/").last.gsub("ifcfg-","")
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

  unless segments.nil?
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
        if Config_utils.net_get_device_bypass_master(iface)
          # this port is a bypass master ... need to set to standard nic
          system("bpctl_util #{iface} set_std_nic off")
          system("bpctl_util #{iface} set_bypass on")
        end
      end
    end
  end

  # Configure NETWORK 
  network['interfaces'].each do |iface|
    dev = iface['device']
    iface_mode = iface['mode']

    open("/etc/sysconfig/network-scripts/ifcfg-#{dev}", 'w') { |f|
      # Commom configuration to all interfaces
      f.puts "BOOTPROTO=#{iface_mode}"
      f.puts "DEVICE=#{dev}"
      f.puts "ONBOOT=yes"
      dev_uuid = File.read("/proc/sys/kernel/random/uuid").chomp
      f.puts "UUID=#{dev_uuid}"

      if iface_mode != 'dhcp'
        # Specific handling for static and management interfaces
        if dev == management_interface || Config_utils.check_ipv4(ip: iface['ip'], netmask: iface['netmask'], gateway: iface['gateway'])
          f.puts "IPADDR=#{iface['ip']}" if iface['ip']
          f.puts "NETMASK=#{iface['netmask']}" if iface['netmask']
          f.puts "GATEWAY=#{iface['gateway']}" if iface['gateway']
          if dev == management_interface
            f.puts "DEFROUTE=yes"
          else
            f.puts "DEFROUTE=no"
          end
        else
          p err_msg = "Invalid network configuration for device #{dev}. Please review #{INITCONF} file"
          exit 1
        end
      else
        # Specific settings for DHCP
        f.puts "PEERDNS=no"
        f.puts "DEFROUTE=no" unless dev == management_interface
      end

      if Config_utils.net_get_device_bypass_master(dev)
        # this port is a bypass master ... need to set to standard nic
        system("bpctl_util #{dev} set_std_nic on")
      end
    }
  end

  # Restart NetworkManager
  system('pkill dhclient &> /dev/null')
  puts "Restarting the network.."
  system('service network restart &> /dev/null')
  sleep 10
end

# TODO: check network connectivity. Try to resolve repo.redborder.com

unless Config_utils.has_internet?
  puts "[!] Error: Trying to resolv repo.redborder.com failed. Please check your network settings or contact your system administrator."
  exit 1
end

##############################
# Accept chef-client license #
##############################
system('chef-client --chef-license accept &>/dev/null')

####################
# Set UTC timezone #
####################

system("timedatectl set-timezone UTC")
# TODO
#system("ntpdate pool.ntp.org")


#Firewall rules
if !network.nil? #Firewall rules are not needed in cloud environments

  # Add rules here
  
  # Reload firewalld configuration
  #system("firewall-cmd --reload &>/dev/null")

end

# Upgrade system
system('yum install systemd -y')

#system('systemctl start chef-client &>/dev/null') unless opt["r"]
#TODO: check if needed: rm -f /boot/initrd*kdump.*
system('service kdump start')

###########################
# configure cloud address #
###########################
if opt["r"]
  if registration_mode == "proxy"
    if Config_utils.check_cloud_address(cloud_address)
      IPSOPTS="-t ips -i -d -f"
      system("/usr/lib/redborder/bin/rb_register_url.sh -u #{cloud_address} #{IPSOPTS}")
    else
      p err_msg = "Invalid cloud address. Please review #{INITCONF} file"
      exit 1
    end
  else
    system("sudo hostnamectl set-hostname #{ips_node_name}")
    system("/usr/lib/redborder/scripts/rb_associate_sensor.rb -u #{webui_user} -p #{webui_pass} -i #{Config_utils.get_ip_address} -m #{webui_host}")
    if $?.exitstatus == 0
      Config_utils.hook_hosts webui_host
      Config_utils.replace_chef_server_url
      # Config_utils.remove_ssl_verify_mode_lines
      puts "Sensor registered to the manager!, please wait..."
      system('/usr/lib/redborder/bin/rb_register_finish.sh > /dev/null 2>&1')
      puts "Registration and configuration finished!"
    else
      puts "Error: rb_associate_sensor.rb failed with exit status #{$?.exitstatus}. Please review #{INITCONF} file or network configuration..."
    end
  end
end
