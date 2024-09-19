#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'mrdialog'
require 'yaml'
require 'logger'
require 'getopt/std'
require "#{ENV['RBLIB']}/rb_wiz_lib"
require "#{ENV['RBLIB']}/rb_config_utils.rb"

CONFFILE = "#{ENV['RBETC']}/rb_init_conf.yml" unless defined?(CONFFILE)
DIALOGRC = "#{ENV['RBETC']}/dialogrc"
ENV['DIALOGRC'] = DIALOGRC if File.exist?(DIALOGRC)

opt = Getopt::Std.getopts('f')

def cancel_change_segments
  dialog = MRDialog.new
  dialog.clear = true
  dialog.title = 'Segments change wizard cancelled'

  text = <<~HEREDOC

    The segments change has been cancelled or stopped.

    If you want to complete the change, please execute it again.

  HEREDOC
  dialog.msgbox(text, 11, 41)
  exit(1)
end

# Display a warning dialog to the user if not in a local tty.
#
# This function uses `MRDialog` to create a dialog window. If the script is not being run in a local TTY, this message
# is shown.
# @example
#   local_tty_warning_wizard unless Config_utils.is_local_tty or opt["f"]
def local_tty_warning_wizard
  dialog = MRDialog.new
  dialog.clear = true
  dialog.title = 'SETUP wizard cancelled'

  text = <<~HEREDOC

    This device must be configured under local tty.

    If you want to complete the setup wizard, please execute it again in a local tty.

  HEREDOC
  dialog.msgbox(text, 11, 41)
  exit(1)
end

# Run the wizard only in local tty
local_tty_warning_wizard unless Config_utils.is_local_tty || opt['f']

# Load configuration from a YAML file.
#
# @param file [String] the path to the YAML configuration file.
# @return [Hash] the configuration loaded from the file, or an empty hash if loading fails.
def load_config(file)
  YAML.load_file(file) rescue {}
end

# Save configuration to a YAML file.
#
# @param file [String] the path to the YAML file where the configuration will be saved.
# @param config [Hash] the configuration data to save.
def save_config(file, config)
  File.open(file, 'w') { |f| f.write(config.to_yaml) }
end

# Display a warning dialog to the user about deleting all network segment configurations.
#
# This function uses `MRDialog` to create a dialog window. If the user selects 'No', the program exits.
def warn_user_about_segment_deletion
  dialog = MRDialog.new
  dialog.clear = true
  dialog.title = 'Warning: Delete All Segments'
  text =  '\nAll existing network segment configurations will be deleted.'
  text += '\nThis action cannot be undone.'
  text += '\nDo you want to continue?'
  choice = dialog.yesno(text, 10, 50)
  exit(1) if choice == false
end

# Delete all existing bridge interfaces from the system.
#
# This function removes all network bridge interfaces that start with "br".
def delete_existing_br_interfaces
  br_interfaces = Dir.entries('/sys/class/net/').select { |f| f.start_with?('br') }
  br_interfaces.each do |br_iface|
    system("ip link set #{br_iface} down")
    system("brctl delbr #{br_iface}")
  end
end

warn_user_about_segment_deletion
delete_existing_br_interfaces

init_conf = load_config(CONFFILE)

segments_conf = SegmentsConf.new
segments_conf.doit
init_conf['segments'] = segments_conf.conf rescue nil
init_conf['segments'] = nil if init_conf['segments'] && init_conf['segments'].empty?

cancel_change_segments if segments_conf.cancel

# Create or update network configuration scripts for a segment.
#
# @param segment [Hash] a hash representing a network segment, including its name and ports.
# @param init_conf [Hash] the initial configuration data.
def create_or_update_network_scripts(segment, init_conf)
  logger = Logger.new(STDOUT)
  logger.info("Starting update for segment: #{segment['name']}")
  if segment['ports'].empty?
    return logger.warn("No ports to configure for segment #{segment['name']}. Skipping configuration.")
  end

  manage_network_interfaces(init_conf['segments'])
  write_network_config_files(segment)
end

# Manage network interfaces by deleting unnecessary configuration files.
#
# @param segments [Array<Hash>] an array of hashes representing network segments.
def manage_network_interfaces(segments)
  files_to_delete = find_files_to_delete(segments)
  delete_network_interfaces(files_to_delete)
end

# Find network configuration files to delete based on the current segments.
#
# @param segments [Array<Hash>] an array of hashes representing network segments.
# @return [Array<String>] an array of file paths to delete.
def find_files_to_delete(segments)
  files_to_delete = []
  list_net_conf = Dir.entries('/etc/sysconfig/network-scripts/').select { |f| f.start_with?('ifcfg-b') && !File.directory?(f) }

  list_net_conf.each do |netconf|
    bridge = netconf.gsub('ifcfg-', '') # Extract bridge name from file name
    next unless segments.nil? || segments.none? { |s| s['name'] == bridge }

    files_to_delete.push("/etc/sysconfig/network-scripts/#{netconf}")
    bridge_interfaces = `grep -rnwl '/etc/sysconfig/network-scripts' -e 'BRIDGE="#{bridge}"'`.split("\n")
    files_to_delete += bridge_interfaces
  end

  files_to_delete.uniq
end

# Delete network interfaces by removing their configuration files and stopping them.
#
# @param files_to_delete [Array<String>] an array of file paths to delete.
def delete_network_interfaces(files_to_delete)
  files_to_delete.each do |iface_path_file|
    iface = iface_path_file.split('/').last.gsub('ifcfg-', '') # Extract interface name from file name
    puts "Stopping dev #{iface} .."
    system("ip link set dev #{iface} down") # Deactivate the interface
    if iface.start_with?('b')
      puts "Deleting dev bridge #{iface}"
      system("brctl delbr #{iface}")
    end
    File.delete(iface_path_file) if File.exist?(iface_path_file)
  end
end

# Write network configuration files for a given segment.
#
# @param segment [Hash] a hash representing a network segment, including its name and ports.
def write_network_config_files(segment)
  logger = Logger.new(STDOUT)
  begin
    segment_file = "/etc/sysconfig/network-scripts/ifcfg-#{segment['name']}"
    File.open(segment_file, 'w') do |f|
      f.puts "DEVICE=#{segment['name']}"
      f.puts 'TYPE=Bridge'
      f.puts 'BOOTPROTO=none'
      f.puts 'ONBOOT=yes'
      f.puts 'IPV6_AUTOCONF=no'
      f.puts 'IPV6INIT=no'
      f.puts 'DELAY=0'
      f.puts 'STP=off'
    end
    logger.info("Segment file created: #{segment_file}")

    segment['ports'].each do |iface|
      iface_file = "/etc/sysconfig/network-scripts/ifcfg-#{iface}"
      File.open(iface_file, 'w') do |f|
        f.puts "DEVICE=\"#{iface}\""
        f.puts "BRIDGE=\"#{segment['name']}\""
        f.puts 'TYPE=Ethernet'
        f.puts 'BOOTPROTO=none'
        f.puts 'NM_CONTROLLED=\"no\"'
        f.puts 'ONBOOT=\"yes\"'
        f.puts 'IPV6_AUTOCONF=no'
        f.puts 'IPV6INIT=no'
        f.puts 'DELAY=0'
        f.puts 'STP=off'
      end
      logger.info("Interface file created: #{iface_file}")
    end

    # Restart network to apply changes
    system('pkill dhclient &> /dev/null')
    system('service network restart &> /dev/null')
    sleep 10
    logger.info('Network restart completed.')
  rescue => e
    logger.error("Error during segment configuration: #{e.message}")
  end
end

init_conf['segments']&.each do |segment|
  create_or_update_network_scripts(segment, init_conf)
end

save_config(CONFFILE, init_conf)
init_conf = load_config(CONFFILE)
system('pkill dhclient &> /dev/null')
system('service network restart &> /dev/null')
sleep 10

system('ohai -d /etc/chef/ohai/plugins/ redborder')

puts 'Executing rb_wakeup_chef'
system('rb_wake_up.sh')
