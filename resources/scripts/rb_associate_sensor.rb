#!/usr/bin/ruby

#######################################################################
## Copyright (c) 2014 ENEO Tecnología S.L.
## This file is part of redBorder.
## redBorder is free software: you can redistribute it and/or modify
## it under the terms of the GNU Affero General Public License License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
## redBorder is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU Affero General Public License License for more details.
## You should have received a copy of the GNU Affero General Public License License
## along with redBorder. If not, see <http://www.gnu.org/licenses/>.
########################################################################

require 'json'
require "socket"
require "getopt/std"
require 'net/http'

def usage
  printf "Usage: rb_associate_sensor.rb -u username -p password -i ipaddress -m ip_manager\n"
  exit 1
end


opt = Getopt::Std.getopts("u:p:i:m:h")

if opt["h"]
  usage
end

if opt["u"].nil? || opt["p"].nil? || opt["i"].nil? || opt['m'].nil?
  usage
end

client_name = Socket.gethostname.split(".").first

http = Net::HTTP.new(opt['m'], 443)
http.use_ssl = true
http.verify_mode = OpenSSL::SSL::VERIFY_NONE

path = '/sensors/associate_v2.json'

data = { 'username' => opt['u'], 'password' => opt['p'], 'sensor_name' => client_name, 'ipaddress' => opt['i'] }

headers = {
  'Content-Type' => 'application/json'
}

resp, data = http.post(path, data.to_json, headers)

if resp.code != '200'
  puts resp.body
  exit 1
end

response_json = JSON.parse(resp.body)

# It's necessary to delete double quote from content files
client_api_key = response_json['client_api_key'].gsub("\"", '')
encrypted_data_bag_secret = response_json['encrypted_data_bag_secret'].gsub("\"", '')
erchef_file_name = response_json['erchef_cert']['name']
erchef_file_content = response_json['erchef_cert']['content'].gsub("\"", '')

dir_paths = [
  '/etc/chef',
  '/root/.chef/trusted_certs',
  '/home/redborder/.chef/trusted_certs'
]

# Ensure dirs exists before saving
dir_paths.each do |path|
  Dir.mkdir(path) unless Dir.exist?(path)
end

# Create /etc/chef/client.pem file
File.open("/etc/chef/client.pem", "w+") do |f|
  client_api_key.split('\n').each do |l|
    f.puts l
  end
end

# Create /etc/chef/encrypted_data_bag_secret file
File.open("/etc/chef/encrypted_data_bag_secret", "w+") do |f|
  encrypted_data_bag_secret.split('\n').each do |l|
    f.puts l
  end
end

# Create /root/.chef/trusted_certs/*.crt
File.open("/root/.chef/trusted_certs/#{erchef_file_name}", "w+") do |f|
  erchef_file_content.split('\n').each do |l|
    f.puts l
  end
end

# Create /home/redborder/.chef/trusted_certs/*.crt
File.open("/home/redborder/.chef/trusted_certs/#{erchef_file_name}", "w+") do |f|
  erchef_file_content.split('\n').each do |l|
    f.puts l
  end
end

# Create /etc/chef/nodename file
File.open("/etc/chef/nodename", "w+") do |f|
  f.puts "rbips-#{response_json['sensor_id']}"
end

exit 0
