#!/usr/bin/env ruby

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

require "getopt/std"

ret=0

def usage
  printf "Usage: rb_get_sensor_rules_cloud.rb -u <uuid> -c <command>\n"
  exit 1
end

opt = Getopt::Std.getopts("u:c:h")

usage if ( opt["h"] or (opt["u"].nil? || opt["c"].nil? ) )

printf "Importing gems: "
require 'net/http'
require 'json'
require "socket"
require 'chef'
printf "done\n"
@weburl = "https://webui.service"
Chef::Config.from_file("/etc/chef/client.rb")
Chef::Config[:http_retry_count] = 5

printf "Downloading rules: #{opt["c"]} "
client_name = File.read('/etc/chef/nodename').strip
path = '/api/v1/ips/apply_job_info'
uuid=opt["u"].to_s
content=`#{opt["c"]}`
printf "-> done\n"

printf "-----------------------------------------------------------------------------------\n"
puts content
printf "-----------------------------------------------------------------------------------\n"

printf "Contacting #{@weburl}#{path} with client name #{client_name}:\n"
rest   = Chef::REST.new(@weburl, client_name, Chef::Config[:client_key])
result = rest.request(:post, "#{path}", {"X-Redborder" => "true"}, {"content" => content, "uuid" => uuid})

if result
  puts result
  printf "-----------------------------------------------------------------------------------\n"
  ret=0
else
  printf "ERROR contacting server!!\n"
  ret=1
end

exit ret

