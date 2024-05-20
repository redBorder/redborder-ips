#!/usr/bin/env ruby

require 'json'
require 'mrdialog'
require 'yaml'
require 'getopt/std'
require "#{ENV['RBLIB']}/rb_wiz_lib"
require "#{ENV['RBLIB']}/rb_config_utils.rb"

CONFFILE = "#{ENV['RBETC']}/rb_init_conf.yml" unless CONFFILE
DIALOGRC = "#{ENV['RBETC']}/dialogrc"
if File.exist?(DIALOGRC)
    ENV['DIALOGRC'] = DIALOGRC
end

opt = Getopt::Std.getopts("f")

# Load old configuration if any
init_conf = YAML.load_file(CONFFILE) rescue nil
init_conf_cloud_address = init_conf['cloud_address'] rescue nil
init_conf_network = init_conf['network'] rescue nil
init_conf_segments = init_conf['segments'] || [] rescue []

def cancel_wizard()

    dialog = MRDialog.new
    dialog.clear = true
    dialog.title = "SETUP wizard cancelled"

    text = <<EOF

The setup has been cancelled or stopped.

If you want to complete the setup wizard, please execute it again.

EOF
    result = dialog.msgbox(text, 11, 41)
    exit(1)

end

def local_tty_warning_wizard()

    dialog = MRDialog.new
    dialog.clear = true
    dialog.title = "SETUP wizard cancelled"

    text = <<EOF

This device must be configured under local tty.

If you want to complete the setup wizard, please execute it again in a local tty.

EOF
    result = dialog.msgbox(text, 11, 41)
    exit(1)

end

# Run the wizard only in local tty
local_tty_warning_wizard unless Config_utils.is_local_tty or opt["f"]


# init
puts "Getting data. Please wait ... "
Config_utils.net_init_bypass

puts "\033]0;redborder - setup wizard\007"

general_conf = {
    "cloud_address" => "rblive.redborder.com",
    "network" => {
        "interfaces" => [],
        "dns" => []
        },
    "segments" => []
    }

# general_conf will dump its contents as yaml conf into rb_init_conf.yml

# TODO: intro to the wizard, define color set, etc.

text = <<EOF

This wizard will guide you through the necessary configuration of the device
in order to convert it into a redborder ips sensor.

It will go through the following required steps: network configuration, 
segments configuration, and domain and DNS. After that this process will perform
a sensor regitration within the redborder manager.

Would you like to continue?

EOF

dialog = MRDialog.new
dialog.clear = true
dialog.title = "Configure wizard"
yesno = dialog.yesno(text,0,0)

unless yesno # yesno is "yes" -> true
    cancel_wizard
end

##########################
# NETWORK CONFIGURATION  #
##########################

text = <<EOF

Next, you will be able to configure network settings. If you have
the network configured manually, you can "SKIP" this step and go
to the next step.

Please, Select an option.

EOF

dialog = MRDialog.new
dialog.clear = true
dialog.title = "Configure Network"
dialog.cancel_label = "SKIP"
dialog.no_label = "SKIP"
yesno = (init_conf_network.nil? or init_conf_network['interfaces'].empty?) ? true : dialog.yesno(text,0,0)

if yesno # yesno is "yes" -> true

    # Conf for network
    netconf = NetConf.new
    loop do
        netconf.segments = init_conf_segments
        netconf.doit # launch wizard
        cancel_wizard and break if netconf.cancel
        general_conf["network"]["interfaces"] = netconf.conf
        break unless general_conf["network"]["interfaces"].empty?
    end


    # Conf for DNS
    text = <<EOF

Do you want to configure DNS servers?

If you have configured the network as Dynamic and
you get the DNS servers via DHCP, you should say
'No' to this  question.

EOF

    dialog = MRDialog.new
    dialog.clear = true
    dialog.title = "CONFIGURE DNS"
    yesno = dialog.yesno(text,0,0)

    if yesno # yesno is "yes" -> true
        # configure dns
        dnsconf = DNSConf.new
        dnsconf.doit # launch wizard
        cancel_wizard if dnsconf.cancel
        general_conf["network"]["dns"] = dnsconf.conf
    else
        general_conf["network"].delete("dns")
    end
end
##############################
# INTERFACES  CONFIGURATION  #
##############################
if general_conf["network"]["interfaces"].size >= 1
    static_interfaces = general_conf["network"]["interfaces"].select { |i| i["mode"] == "static" }
    dhcp_interfaces = general_conf["network"]["interfaces"].select { |i| i["mode"] == "dhcp" }

    if static_interfaces.size == 1
        general_conf["network"]["management_interface"] = static_interfaces[0]["device"]
    else
        interface_options = general_conf["network"]["interfaces"].map { |i| [i["device"]] }
        text = <<EOF
You have multiple network interfaces configured.
Please select one to be used as the management interface.
EOF
        dialog = MRDialog.new
        dialog.clear = true
        dialog.title = "Select Management Interface"
        management_iface = dialog.menu(text, interface_options, 10, 50)

        if management_iface.nil? || management_iface.empty?
            cancel_wizard
        else
            general_conf["network"]["management_interface"] = management_iface
        end
    end
else
    # we do not have a management interface
    cancel_wizard
end

##########################
# IPMI    CONFIGURATION  #
##########################
if Config_utils.ipmi_capable?
    text = <<EOF

Next, you will be able to configure IPMI settings. If you have
the IPMI configured manually, you can "SKIP" this step and go
to the next step.

Please, Select an option.

EOF

    dialog = MRDialog.new
    dialog.clear = true
    dialog.title = "Configure IPMI"
    dialog.cancel_label = "SKIP"
    dialog.no_label = "SKIP"
    yesno = dialog.yesno(text,0,0)

    if yesno # yesno is "yes" -> true

        # Conf for ipmi
        ipmiconf = IpmiConf.new
        ipmiconf.doit # launch wizard

        general_conf["ipmi"] = {}
        general_conf["ipmi"]["ip"] = ipmiconf.conf["IP:"] if !ipmiconf.conf.empty? and ipmiconf.conf["IP:"]
        general_conf["ipmi"]["netmask"] = ipmiconf.conf["Netmask:"] if !ipmiconf.conf.empty? and ipmiconf.conf["Netmask:"]
        general_conf["ipmi"]["gateway"] = ipmiconf.conf["Gateway:"] if !ipmiconf.conf.empty? and ipmiconf.conf["Gateway:"]
        
    end
end
##########################
# SEGMENTS CONFIGURATION #
##########################

# Conf network segments
segments_conf = SegmentsConf.new

# Get segments and management interface from the old configuration
# If there is only one interfaces this is for sure the management
if general_conf["network"]["interfaces"].count  == 1
  segments_conf.management_interface = general_conf["network"]["interfaces"].first
end
segments_conf.segments = Config_utils.net_segment_autoassign_bypass(init_conf_segments, segments_conf.management_interface) rescue []

# Get actual managment interface if user just set
unless general_conf["network"]["interfaces"].empty? # meaning the user did not skip network configuration
    # TODO: find a way to detect the managment interface in case of DHCP
    # segments_conf.management_interface = general_conf["network"]["interfaces"].first["device"] rescue nil
end

segments_conf.doit # launch wizard
cancel_wizard if segments_conf.cancel
general_conf["segments"] = segments_conf.conf rescue nil
general_conf["segments"] = nil if general_conf["segments"] and general_conf["segments"].empty?

# For each segment interfaces we need to remove it from the general_conf["network"]["interfaces"] so
# it doesnt end as part of a segment and  as managmenet interface
unless general_conf["segments"].nil?
    general_conf["segments"].each do |segment|
        general_conf["network"]["interfaces"].delete_if{ |interface| segment["ports"].include? interface["device"]}
    end
end
# Add the deleted segments to the general_conf["network"]["interfaces"] so it stays configure as dhcp
segments_conf.deleted_segments.each do |segment|
    segment["ports"].each do |port|
        general_conf["network"]["interfaces"].push({"mode" => "dhcp", "device" => "#{port}"})
    end
end

################
# Registration #
################
make_registration = true
unless init_conf_cloud_address.nil?
    dialog = MRDialog.new
    dialog.clear = true
    dialog.title = "Confirm configuration"
    text = <<EOF

There was a previous wizard execution and your IPS may had been registered already, do you want to register again?

EOF
    make_registration = dialog.yesno(text,0,0)
end

if make_registration 
    ###############################
    # CLOUD ADDRESS CONFIGURATION #
    ###############################

    # Conf for hostname and domain
    cloud_address_conf = CloudAddressConf.new
    cloud_address_conf.doit # launch wizard
    cancel_wizard if cloud_address_conf.cancel
    general_conf["cloud_address"] = cloud_address_conf.conf[:cloud_address]
end

###############################
#     BUILD DESCRIPTION       #
###############################

# Confirm
text = <<EOF

You have selected the following parameter values for your configuration:

EOF

unless general_conf["network"]["interfaces"].empty?
    text += "- Networking:\n"
    general_conf["network"]["interfaces"].each do |i|
        text += "    device: #{i["device"]}\n"
        text += "    mode: #{i["mode"]}\n"
        if i["mode"] == "static"
            text += "    ip: #{i["ip"]}\n"
            text += "    netmask: #{i["netmask"]}\n"
            unless i["gateway"].nil? or i["gateway"] == ""
                text += "    gateway: #{i["gateway"]}\n"
            end
        end
        text += "\n"
    end
end

unless general_conf["network"]["dns"].nil? or general_conf["network"]["dns"].empty?
    text += "- DNS:\n"
    general_conf["network"]["dns"].each do |dns|
        text += "    #{dns}\n"
    end
end

unless general_conf["ipmi"].nil? or general_conf["ipmi"].empty?
    text += "- IPMI Network Configuration:\n"
    text += "Ip: #{general_conf['ipmi']['ip']}\n"
    text += "Netmask: #{general_conf['ipmi']['netmask']}\n"
    text += "Gateway: #{general_conf['ipmi']['gateway']}\n"
end


unless general_conf["segments"].nil? or general_conf["segments"].empty?
    text += "- Segments:\n"
    general_conf["segments"].each do |s|
        text += "    name: #{s["name"]} | ports: #{s["ports"]} | bypass_support: #{s["bypass_support"]}\n"
    end
end

text += "\n- Make Registration: #{make_registration}\n"

text += "\n- Cloud address: #{general_conf["cloud_address"]}\n" if make_registration

text += "\nPlease, is this configuration ok?\n \n"

dialog = MRDialog.new
dialog.clear = true
dialog.title = "Confirm configuration"
yesno = dialog.yesno(text,0,0)

unless yesno # yesno is "yes" -> true
    cancel_wizard
end

File.open(CONFFILE, 'w') {|f| f.write general_conf.to_yaml } #Store

#exec("#{ENV['RBBIN']}/rb_init_conf.sh")
command_opts = ""
command_opts = "-r" if make_registration
command_opts += " -f" if opt["f"]
command = "#{ENV['RBBIN']}/rb_init_conf #{command_opts}"



dialog = MRDialog.new
dialog.clear = false
dialog.title = "Applying configuration"
dialog.prgbox(command,20,100, "Executing rb_init_conf")

## vim:ts=4:sw=4:expandtab:ai:nowrap:formatoptions=croqln:
