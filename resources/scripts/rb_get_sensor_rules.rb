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

require 'json'
require 'socket'
require 'net/http'
require "getopt/std"
require 'fileutils'
require 'base64'
require 'time'
require 'digest/sha1'
require 'openssl'
require 'net/https'

class ChefAPI

  # Public: Gets/Sets the http object.
  attr_accessor :http

  # Public: Gets/Sets the String path for the HTTP request.
  attr_accessor :path

  # Public: Gets/Sets the String client_name containing the Chef client name.
  attr_accessor :client_name

  # Public: Gets/Sets the String key_file that is path to the Chef client PEM file.
  attr_accessor :key_file

  # Public: Initialize a Chef API call.
  #
  # opts - A Hash containing the settings desired for the HTTP session and auth.
  #        :server       - The String server that is the Chef server name (required).
  #        :port         - The String port for the Chef server (default: 443).
  #        :use_ssl      - The Boolean use_ssl to use Net::HTTP SSL
  #                        functionality or not (default: true).
  #        :ssl_insecure - The Boolean ssl_insecure to skip strict SSL cert
  #                        checking (default: OpenSSL::SSL::VERIFY_PEER).
  #        :client_name  - The String client_name that is the name of the Chef
  #                        client (required).
  #        :key_file     - The String key_file that is the path to the Chef client
  #                        PEM file (required).
  def initialize(opts={})
    server            = opts[:server]
    port              = opts.fetch(:port, 443)
    use_ssl           = opts.fetch(:use_ssl, true)
    ssl_insecure      = opts[:ssl_insecure] ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
    @client_name      = opts[:client_name]
    @key_file         = opts[:key_file]

    @http             = Net::HTTP.new(server, port)
    @http.use_ssl     = use_ssl
    @http.verify_mode = ssl_insecure
  end

  # Public: Make the actual GET request to the Chef server.
  #
  # req_path - A String containing the server path you want to send with your
  #            GET request (required).
  #
  # Examples
  #
  #   get_request('/environments/_default/nodes')
  #   # => ["server1.com","server2.com","server3.com"]
  #
  # Returns different Object type depending on request.
  def get_request(req_path)
    @path = req_path

    begin
      request  = Net::HTTP::Get.new(path, headers)
      response = http.request(request)

      response.body
    rescue OpenSSL::SSL::SSLError => e
      raise "SSL error: #{e.message}."
    end
  end

  private

  # Private: Encode a String with SHA1.digest and then Base64.encode64 it.
  #
  # string - The String you want to encode.
  #
  # Examples
  #
  #   encode('hello')
  #   # => "qvTGHdzF6KLavt4PO0gs2a6pQ00="
  #
  # Returns the hashed String.
  def encode(string)
    ::Base64.encode64(Digest::SHA1.digest(string)).chomp
  end

  # Private: Forms the HTTP headers required to authenticate and query data
  # via Chef's REST API.
  #
  # Examples
  #
  #   headers
  #   # => {
  #     "Accept"                => "application/json",
  #     "X-Ops-Sign"            => "version=1.0",
  #     "X-Ops-Userid"          => "client-name",
  #     "X-Ops-Timestamp"       => "2012-07-27T20:09:25Z",
  #     "X-Ops-Content-Hash"    => "JJKXjxksmsKXM=",
  #     "X-Ops-Authorization-1" => "JFKXjkmdkDMKCMDKd+",
  #     "X-Ops-Authorization-2" => "JFJXjxjJXXJ/FFjxjd",
  #     "X-Ops-Authorization-3" => "FFJfXffffhhJjxFJff",
  #     "X-Ops-Authorization-4" => "Fjxaaj2drg5wcZ8I7U",
  #     "X-Ops-Authorization-5" => "ffjXeiiiaHskkflllA",
  #     "X-Ops-Authorization-6" => "FjxJfjkskqkfjghAjQ=="
  #   }
  #
  # Returns a Hash with the necessary headers.
  def headers
    # remove parameters from the path
    _path=path.split('?').first

    body      = ""
    timestamp = Time.now.utc.iso8601
    key       = OpenSSL::PKey::RSA.new(File.read(key_file))
    canonical = "Method:GET\nHashed Path:#{encode(_path)}\nX-Ops-Content-Hash:#{encode(body)}\nX-Ops-Timestamp:#{timestamp}\nX-Ops-UserId:#{client_name}"

    header_hash = {
      'Accept'             => 'application/json',
      'X-Ops-Sign'         => 'version=1.0',
      'X-Ops-Userid'       => client_name,
      'X-Ops-Timestamp'    => timestamp,
      'X-Ops-Content-Hash' => encode(body)
    }

    signature = Base64.encode64(key.private_encrypt(canonical))
    signature_lines = signature.split(/\n/)
    signature_lines.each_index do |idx|
      key = "X-Ops-Authorization-#{idx + 1}"
      header_hash[key] = signature_lines[idx]
    end

    header_hash
  end

end

CLIENTPEM   = "/etc/chef/client.pem"
QUIET       = 0

@reload_snort = 0
@reload_snort_ips = 0
@restart_snort = 0

ret=0

RES_COL     = 76

print "Execution: rb_get_sensor_rules.rb"
ARGV.each do |a|
  print " #{a}"
end
print "\n"

opt = Getopt::Std.getopts("hg:b:d:srfw")
if opt["h"] or opt["g"].nil? 
  printf "rb_get_sensor_rules.rb [-h] [-f] -g group_id -b binding_id -d dbversion_id\n"
  printf "    -h                -> print this help\n"
  printf "    -g group_id       -> Group Id\n"
  printf "    -b binding_id     -> Binding Id\n"
  printf "    -d dbversion_ids  -> Rule database version IDs\n"
  printf "    -s                -> Save this command into the proper rb_get_sensor_rules.sh file\n"
  printf "    -r                -> Include reputation list\n"
  printf "    -w                -> Don't rollback in case of errors\n"
  exit 1
end

@group_id      = opt["g"].to_i
savecmd        = !opt["s"].nil?
reputation     = !opt["r"].nil?
rollback       = opt["w"].nil?
binding_ids    = []

if opt["b"].is_a? Array
  binding_ids += opt["b"]
elsif !opt["b"].nil?
  binding_ids << opt["b"]
end

@weburl = "webui.service"
@client_name = File.read('/etc/chef/nodename').strip
@client_id   = @client_name.split('-').last

@v_group_dir            = "/etc/snort/#{@group_id}"
@v_iplist_dir           = "/etc/snort/#{@group_id}/iplists"
@v_iplistname           = "iplist_script.sh"
@v_iplist               = "#{@v_iplist_dir}/#{@v_iplistname}"
@v_iplist_zone          = "#{@v_iplist_dir}/zone.info"
@v_geoip_dir            = "/etc/snort/#{@group_id}/geoips"
@v_geoipname            = "geoip_script.sh"
@v_geoip                = "#{@v_geoip_dir}/#{@v_geoipname}"
@v_unicode_mapname      = "unicode.map"
@v_unicode_map          = "/etc/snort/#{@group_id}/#{@v_unicode_mapname}"

@chef=ChefAPI.new(
  server: @weburl,
  use_ssl: true,
  ssl_insecure: true,
  client_name: @client_name,
  key_file: "/etc/chef/client.pem" 
)

def print_ok(text_length=76)
  #printf("%#{RES_COL - text_length}s", "[\e[32m  OK  \e[0m]")
  printf("%#{RES_COL - text_length}s", "[  OK  ]")
  puts ""
end

def print_fail(text_length=76)
  #print sprintf("%#{RES_COL - text_length}s", "[\e[31m  FAILED  \e[0m]")
  print sprintf("%#{RES_COL - text_length}s", "[  FAILED  ]")
  puts ""
end

def get_rules(remote_name, snortrules, binding_id)

  snortrulestmp = "#{snortrules}.tmp" 
  print "Downloading #{remote_name} "
  print_length = "Downloading #{remote_name} ".length

  File.delete(snortrulestmp) if File.exist?(snortrulestmp)

  result = @chef.get_request("/sensors/#{@client_id}/#{remote_name}?group_id=#{@group_id}&binding_id=#{binding_id}")

  if result
    File.open(snortrulestmp, 'w') {|f| f.write(result)}

    v_md5sum_tmp  = Digest::MD5.hexdigest(File.read(snortrulestmp))
    v_md5sum      = File.exist?(snortrules) ? Digest::MD5.hexdigest(File.read(snortrules)) : ""

    if v_md5sum != v_md5sum_tmp
      File.zero?(@v_iplist_zone) ? @reload_snort = 1 : @restart_snort = 1
    else
      print "(not modified) "
      print_length += "(not modified) ".length
      File.delete(snortrulestmp) if File.exist?(snortrulestmp)
    end

    print_ok(print_length)
    return true
  else  
    print_fail(print_length)
    return false
  end
end

def create_sid_msg
  print "Creating sig.msg file "
  print_length = "Creating sig.msg file ".length

  snortrules_sidmsgtmp = "#{@v_sidfile}.tmp"
  File.new(snortrules_sidmsgtmp, 'w+')

  Dir.entries("/etc/snort/#{@group_id}/").select{|d| d =~ /^snort-binding-\d+$/}.each do |directory|

    File.open("/etc/snort/#{@group_id}/#{directory}/snort.rules", "r").each do |line|
      next if (/^\s*\#/.match(line) or /^\s*$/.match(line))

      v_sid = /sid:\s*(\d+);/.match(line)[1]
      v_msg = /[\(| ]msg:\s*\"([^\"]*)\";/.match(line)[1]

      if v_sid and v_msg
        File.open(snortrules_sidmsgtmp, 'a') {|f| f.print "#{v_sid} || #{v_msg}\n"}
      end
    end

    File.open("/etc/snort/#{@group_id}/#{directory}/preprocessor.rules", "r").each do |line|
      next if (/^\s*\#/.match(line) or /^\s*$/.match(line))

      v_sid = /sid:\s*(\d+);/.match(line)[1]
      v_msg = /[\(| ]msg:\s*\"([^\"]*)\";/.match(line)[1]

      if v_sid and v_msg
        File.open(snortrules_sidmsgtmp, 'a') {|f| f.print "#{v_sid} || #{v_msg}\n"}
      end
    end

    File.open("/etc/snort/#{@group_id}/#{directory}/so.rules", "r").each do |line|
      next if (/^\s*\#/.match(line) or /^\s*$/.match(line))

      v_sid = /sid:\s*(\d+);/.match(line)[1]
      v_msg = /[\(| ]msg:\s*\"([^\"]*)\";/.match(line)[1]

      if v_sid and v_msg
        File.open(snortrules_sidmsgtmp, 'a') {|f| f.print "#{v_sid} || #{v_msg}\n"}
      end
    end

  end

  v_md5sum_tmp  = Digest::MD5.hexdigest(File.read(snortrules_sidmsgtmp))
  v_md5sum      = File.exist?(@v_sidfile) ? Digest::MD5.hexdigest(File.read(@v_sidfile)) : ""

  if v_md5sum == v_md5sum_tmp
    print "(not modified) "
    print_length += "(not modified) ".length
    File.delete(snortrules_sidmsgtmp) if File.exist?(snortrules_sidmsgtmp)
  end

  print_ok(print_length)

end

def get_dynamic_rules(dbversion_ids)

  print "Downloading snort-so_rules-#{@v_snortversion} "
  print_length = "Downloading snort-so_rules-#{@v_snortversion} ".length

  FileUtils.remove_dir(@v_dynamucdirtmp) if Dir.exist?(@v_dynamucdirtmp)
  FileUtils.mkdir_p @v_dynamucdirtmp
  FileUtils.remove_dir(@v_so_rules_dir_tmp) if Dir.exist?(@v_so_rules_dir_tmp)
  FileUtils.mkdir_p @v_so_rules_dir_tmp
  File.delete @v_so_rulestmp if File.exist?(@v_so_rulestmp)

  dbversion_ids.split(",").each do |dbversion_id|

    result = @chef.get_request("/rule_versions/#{dbversion_id}/so_rules_file")

    if result
      open(@v_so_rulestmp, "wb") do |file|
        file.write(result)
      end

      system("tar xzf #{@v_so_rulestmp} -C #{@v_so_rules_dir_tmp}")

      files = find(@v_so_rules_dir_tmp, "snort-so_rules-#{@v_snortversion}.tar.gz")

      if files.empty?
        system("tar xzf #{@v_so_rules_dir_tmp}/snort-so_rules.tar.gz -C #{@v_dynamucdirtmp}")
      else
        system("tar xzf #{files.first} -C #{@v_dynamucdirtmp}")
      end
    end
  end

  system("diff -r #{@v_dynamucdirtmp} #{@v_dynamicdir} &>/dev/null")
  if $?.success?
    print "(not modified) "
    print_length += "(not modified) ".length
  else
    File.zero?(@v_iplist_zone) ? @reload_snort = 1 : @restart_snort = 1
  end

  print_ok(print_length)
  return true
end

def get_gen_msg

  print "Downloading gen-msg.map "
  print_length = "Downloading gen-msg.map ".length

  File.delete GENFILE_TMP if File.exist? GENFILE_TMP

  dbversion_ids = get_rule_db_version_ids
  dbversion_ids.each do |dbversion_id|
    result = @chef.get_request("/rule_versions/#{dbversion_id}/gen_msg_file")
    
    if result
      File.open(GENFILE_TMP, "a") do |file|
        file.write(result)
      end
    end
  end

  v_md5sum_tmp  = Digest::MD5.hexdigest(File.read(GENFILE_TMP))
  v_md5sum      = File.exists?(GENFILE) ? Digest::MD5.hexdigest(File.read(GENFILE)) : ""

  if v_md5sum != v_md5sum_tmp
    File.zero?(@v_iplist_zone) ? @reload_snort = 1 : @restart_snort = 1
  else
    print "(not modified) "
    print_length += "(not modified) ".length
    File.delete(GENFILE_TMP) if File.exist?(GENFILE_TMP)
  end

  print_ok(print_length)
  return true

end

def get_classifications
  print "Downloading classifications "
  print_length = "Downloading classifications ".length

  File.delete "#{@v_classifications}.tmp" if File.exist?("#{@v_classifications}.tmp")

  result = @chef.get_request("/sensors/#{@client_id}/classifications.txt?group_id=#{@group_id}")

  if result
    File.open("#{@v_classifications}.tmp", 'w') {|f| f.write(result)}
    v_md5sum_tmp    = Digest::MD5.hexdigest(File.read("#{@v_classifications}.tmp"))
    v_md5sum        = File.exists?(@v_classifications) ? Digest::MD5.hexdigest(File.read(@v_classifications)) : ""

    if v_md5sum != v_md5sum_tmp
      File.zero?(@v_iplist_zone) ? @reload_snort = 1 : @restart_snort = 1
    else
      print "(not modified) "
      print_length += "(not modified) ".length
      File.delete("#{@v_classifications}.tmp") if File.exist?("#{@v_classifications}.tmp")
    end

    print_ok(print_length)
    return true
  else
    print_fail(print_length)
    return false
  end
end

def get_rule_db_version_ids
  @chef.get_request("/sensors/#{@client_id}/get_rule_db_version_ids?group_id=#{@group_id}")
end

def get_thresholds(binding_id)
  print "Downloading thresholds "
  print_length = "Downloading thresholds ".length

  File.delete "#{@v_threshold}.tmp" if File.exist?("#{@v_threshold}.tmp")

  result = @chef.get_request("/sensors/#{@client_id}/thresholds.txt?group_id=#{@group_id}&binding_id=#{binding_id}")

  if result
    File.open("#{@v_threshold}.tmp", 'w') {|f| f.write(result)}
    v_md5sum_tmp    = Digest::MD5.hexdigest(File.read("#{@v_threshold}.tmp"))
    v_md5sum        = File.exists?(@v_threshold) ? Digest::MD5.hexdigest(File.read(@v_threshold)) : ""

    if v_md5sum != v_md5sum_tmp
      File.zero?(@v_iplist_zone) ? @reload_snort = 1 : @restart_snort = 1
    else
      print "(not modified) "
      print_length += "(not modified) ".length
      File.delete("#{@v_threshold}.tmp") if File.exist?("#{@v_threshold}.tmp")
    end

    print_ok(print_length)
    return true
  else
    print_fail(print_length)
    return false
  end

end

def get_unicode_map
  print "Downloading unicode.map "
  print_length = "Downloading unicode.map ".length

  File.delete "#{@v_unicode_map}.tmp" if File.exist?("#{@v_unicode_map}.tmp")

  result = @chef.get_request("/sensors/#{@client_id}/unicode_map.txt?group_id=#{@group_id}")

  if result
    File.open("#{@v_unicode_map}.tmp", 'w') {|f| f.write(result)}
    v_md5sum_tmp    = Digest::MD5.hexdigest(File.read("#{@v_unicode_map}.tmp"))
    v_md5sum        = File.exists?(@v_unicode_map) ? Digest::MD5.hexdigest(File.read(@v_unicode_map)) : ""

    if v_md5sum != v_md5sum_tmp
      # unicode.map is empty so dont use it
      if File.zero?("#{@v_unicode_map}.tmp")
        File.delete("#{@v_unicode_map}.tmp") if File.exist?("#{@v_unicode_map}.tmp")
      end
      File.zero?(@v_iplist_zone) ? @reload_snort = 1 : @restart_snort = 1
    else
      print "(not modified) "
      print_length += "(not modified) ".length
      File.delete("#{@v_unicode_map}.tmp") if File.exist?("#{@v_unicode_map}.tmp")
    end

    print_ok(print_length)
    return true
  else
    print_fail(print_length)
    return false
  end

end

def get_iplist_files
  print "Downloading iplist files "
  print_length = "Downloading iplist files ".length

  File.delete "#{@v_iplist}.tmp" if File.exist?("#{@v_iplist}.tmp")

  result = @chef.get_request("/sensors/#{@client_id}/iplist.txt?group_id=#{@group_id}")

  if result
    FileUtils.mkdir_p @v_iplist_dir
    File.open("#{@v_iplist}.tmp", File::CREAT|File::TRUNC|File::RDWR, 0755){|f| f.write(result)}
    v_md5sum_tmp    = Digest::MD5.hexdigest(File.read("#{@v_iplist}.tmp"))
    v_md5sum        = File.exists?(@v_iplist) ? Digest::MD5.hexdigest(File.read(@v_iplist)) : ""

    if v_md5sum != v_md5sum_tmp
      if File.zero?("#{@v_iplist_zone}")
        system("rm -f #{@v_iplist}; mv #{@v_iplist}.tmp #{@v_iplist}; sh #{@v_iplist}")
        if File.zero?("#{@v_iplist_zone}")
          @reload_snort = 1
        else
          @restart_snort = 1
          @reload_snort_ips = 1
        end
      else
        system("rm -f #{@v_iplist}; mv #{@v_iplist}.tmp #{@v_iplist}; sh #{@v_iplist}")
        @restart_snort = 1
        @reload_snort_ips = 1
      end
    else
      print "(not modified) "
      print_length += "(not modified) ".length
      File.delete("#{@v_iplist}.tmp") if File.exist?("#{@v_iplist}.tmp")
    end

    print_ok(print_length)
    return true
  else
    print_fail(print_length)
    return false
  end

end

def get_geoip_files
  print "Downloading geoip files "
  print_length = "Downloading geoip files ".length

  File.delete "#{@v_geoip}.tmp" if File.exist?("#{@v_geoip}.tmp")

  result = @chef.get_request("/sensors/#{@client_id}/geoip.txt?group_id=#{@group_id}")

  if result
    FileUtils.mkdir_p @v_geoip_dir

    File.open("#{@v_geoip}.tmp", File::CREAT|File::TRUNC|File::RDWR, 0755){|f| f.write(result)}
    v_md5sum_tmp    = Digest::MD5.hexdigest(File.read("#{@v_geoip}.tmp"))
    v_md5sum        = File.exists?(@v_geoip) ? Digest::MD5.hexdigest(File.read(@v_geoip)) : ""

    if v_md5sum != v_md5sum_tmp
      system("rm -f #{@v_geoip}; mv #{@v_geoip}.tmp #{@v_geoip}; sh #{@v_geoip}")
      File.zero?(@v_iplist_zone) ? @reload_snort = 1 : @restart_snort = 1
    else
      print "(not modified) "
      print_length += "(not modified) ".length
      File.delete("#{@v_geoip}.tmp") if File.exist?("#{@v_geoip}.tmp")
    end

    print_ok(print_length)
    return true
  else
    print_fail(print_length)
    return false
  end
end

def find(dir, filename="*.*")
  Dir[ File.join(dir.split(/\\/), filename) ]
end

def copy_backup( backup_dir, datestr, temp_file_path, final_file_path, filename, backups )
  if File.exist?(temp_file_path)
    if File.exist?(final_file_path)
      print "Backed to #{filename}-#{datestr}\n"
      backups << "#{backup_dir}/#{filename}-#{datestr}"
      FileUtils.copy(final_file_path, "#{backup_dir}/#{filename}-#{datestr}")
    end
    File.rename(temp_file_path, final_file_path)

    files = Dir.entries(backup_dir).select {|x| x =~ /^#{filename}-/}.sort
    if files.size > BACKUPCOUNT
      files.first(files.size-BACKUPCOUNT).each do |f|
        if File.exist?("#{backup_dir}/#{f}")
          print "Removed backup at #{backup_dir}/#{f}\n"
          File.delete("#{backup_dir}/#{f}") 
        end
      end
    end
  end
end

if !File.exists?(CLIENTPEM)
  puts "The sensor is not registered!"
  exit
end

BACKUPCOUNT             = 5
backups = []


if Dir.exist?@v_group_dir and File.exists?"#{@v_group_dir}/cpu_list"
  datestr = Time.now.strftime("%Y%m%d%H%M%S")
  
  @v_backup_dir           = "/etc/snort/#{@group_id}/backups"
  @tmp_backup_tgz         = "/tmp/rb_get_sensor_rules-#{@group_id}-#{datestr}-#{rand(1000)}.tgz"

  FileUtils.mkdir_p @v_backup_dir
  system("cd /etc/snort/#{@group_id}; tar czf #{@tmp_backup_tgz} . 2>/dev/null")
  
  get_unicode_map
  if @reload_snort == 1 or @restart_snort == 1
    copy_backup(@v_backup_dir, datestr, "#{@v_unicode_map}.tmp"     , @v_unicode_map    , @v_unicode_mapname, backups )
  end
  
  if reputation
    print "Reputation:\n"
    get_iplist_files
    get_geoip_files
  end
  
  if @reload_snort == 1 or @restart_snort == 1
    copy_backup(@v_backup_dir, datestr, "#{@v_iplist}.tmp"          , @v_iplist         , @v_iplistname, backups )
    copy_backup(@v_backup_dir, datestr, "#{@v_geoip}.tmp"           , @v_geoip          , @v_geoipname,  backups )
  end
  
  File.delete "#{@v_unicode_map}.tmp" if File.exist?("#{@v_unicode_map}.tmp")
  
  binding_ids.each do |binding_id|
    bind_match = /^([^:]+):([^:]+)$/.match(binding_id.to_s)
  
    if bind_match.nil?
      dbversion_ids = opt["d"].to_s
      binding_id=binding_id.to_i
    else
      dbversion_ids=bind_match[2].to_s
      binding_id=bind_match[1].to_i
    end
  
    if binding_id.nil? or binding_id<0
      print "Error: binding id not found or it is not valid\n"
    elsif dbversion_ids.nil? or dbversion_ids.empty?
      print "Error: dbversion id not found or it is not valid\n"
    else
      system("source /etc/snort/#{@group_id}/snort-binding-#{binding_id}/snort-bindings.conf; echo \"Binding: $BINDING_NAME\"")
      @v_rulefilename         = "snort.rules"
      @v_rulefile             = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/#{@v_rulefilename}"
      @v_prepfilename         = "preprocessor.rules"
      @v_prepfile             = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/#{@v_prepfilename}"
      @v_dynamucdirtmp        = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/dynamicrules-tmp"
      @v_dynamicdir           = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/dynamicrules"
      @v_cmdfile              = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/rb_get_sensor_rules.sh"
      @v_sidfilename          = "sid-msg.map"
      @v_sidfile              = "/etc/snort/#{@group_id}/#{@v_sidfilename}"
      @v_thresholdname        = "threshold.conf"
      @v_threshold            = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/#{@v_thresholdname}"
      @v_classificationsname  = "classification.config"
      @v_classifications      = "/etc/snort/#{@group_id}/#{@v_classificationsname}"
      @v_snortversion         = `/usr/sbin/snort --version 2>&1|grep Version|sed 's/.*Version //'|awk '{print $1}'`.chomp
      @v_so_rules_dir_tmp     = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/so_rules-tmp"
      @v_so_rulestmp          = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/snort-so_rules-tmp.tar.gz"
      @v_backup_dir           = "/etc/snort/#{@group_id}/snort-binding-#{binding_id}/backups"
  
      FileUtils.mkdir_p @v_backup_dir
      FileUtils.mkdir_p @v_dynamicdir
  
      get_rules("active_rules.txt", @v_rulefile, binding_id)
      get_rules("preprocessor_rules.txt", @v_prepfile, binding_id)
      get_dynamic_rules(dbversion_ids)
      get_classifications
      get_thresholds(binding_id)
  
      if @reload_snort == 1 or @restart_snort == 1
        datestr = Time.now.strftime("%Y%m%d%H%M%S")
      
        copy_backup(@v_backup_dir, datestr, "#{@v_rulefile}.tmp"        , @v_rulefile       , @v_rulefilename, backups )
        copy_backup(@v_backup_dir, datestr, "#{@v_prepfile}.tmp"        , @v_prepfile       , @v_prepfilename, backups )
        copy_backup(@v_backup_dir, datestr, "#{@v_classifications}.tmp" , @v_classifications, @v_classificationsname, backups )
        copy_backup(@v_backup_dir, datestr, "#{@v_threshold}.tmp"       , @v_threshold      , @v_thresholdname, backups )
      
        FileUtils.remove_dir(@v_dynamicdir) if Dir.exist?(@v_dynamicdir)
        File.rename(@v_dynamucdirtmp, @v_dynamicdir)
      
        create_sid_msg
        copy_backup(@v_backup_dir, datestr, "#{@v_sidfile}.tmp", @v_sidfile, @v_sidfilename, backups )
      end
      
      File.delete "#{@v_prepfile}.tmp" if File.exist?("#{@v_prepfile}.tmp")
      File.delete "#{@v_sidfile}.tmp" if File.exist?("#{@v_sidfile}.tmp")
      File.delete "#{@v_classifications}.tmp" if File.exist?("#{@v_classifications}.tmp")
      File.delete "#{@v_rulefile}.tmp" if File.exist?("#{@v_rulefile}.tmp")
      File.delete "#{@v_so_rulestmp}" if File.exist?("#{@v_so_rulestmp}")
      File.delete "#{@v_threshold}.tmp" if File.exist?("#{@v_threshold}.tmp")
      FileUtils.remove_dir(@v_dynamucdirtmp) if Dir.exist?(@v_dynamucdirtmp)
      
      if savecmd and @group_id and !binding_id.nil? and !dbversion_ids.nil? and !dbversion_ids.empty?
        begin
          file = File.open(@v_cmdfile, "w")
          file.write("#!/bin/bash\n\n") 
          file.write("/usr/lib/redborder/bin/rb_get_sensor_rules.rb -f -r -g '#{@group_id}' -b '#{binding_id}' -d '#{dbversion_ids}'\n")
        rescue IOError => e
          print "Error saving #{file}"
        ensure
          file.close unless file == nil
        end
      end
    end
  end

  if @reload_snort == 1 or @restart_snort == 1
    #before doing anything we need to check if it is correct
    if system("/bin/env BOOTUP=none /usr/lib/redborder/bin/rb_verify_snort.sh #{@group_id}")
      if savecmd 
        system("source /etc/sysconfig/snort-#{@group_id}; /bin/env WAIT=1 BOOTUP=none /etc/init.d/snortd softreload $INSTANCES_GROUP_NAME") if @reload_snort == 1
        system("source /etc/sysconfig/snort-#{@group_id}; /bin/env WAIT=1 BOOTUP=none /etc/init.d/snortd restart $INSTANCES_GROUP_NAME") if @restart_snort == 1
        system("source /etc/sysconfig/barnyard2-#{@group_id}; /bin/env WAIT=1 BOOTUP=none /etc/init.d/barnyard2 restart $INSTANCES_GROUP_NAME")
      else
        system("source /etc/sysconfig/snort-#{@group_id}; /bin/env WAIT=1 /etc/init.d/snortd softreload $INSTANCES_GROUP_NAME") if @reload_snort == 1
        system("source /etc/sysconfig/snort-#{@group_id}; /bin/env WAIT=1 /etc/init.d/snortd restart $INSTANCES_GROUP_NAME") if @restart_snort == 1
        system("source /etc/sysconfig/barnyard2-#{@group_id}; /bin/env WAIT=1 /etc/init.d/barnyard2 restart $INSTANCES_GROUP_NAME")
      end
      if @reload_snort_ips == 1
        sleep 15 
        text_return = `/usr/lib/redborder/bin/rb_snort_iplist #{@group_id}`
        if text_return.match(/\A(ERROR: |Failed to read the response)/) and Dir.glob("/etc/snort/#{@group_id}/iplists/*.[w|b]lf").any?
          print "The IP/Network reputation policy has not been applied. Try later and ensure that all segments is in non-bypass mode."
        end
        sleep 15
      end
    elsif rollback
      print "\n"
      print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"
      print "ERROR: configuration has errors and SNORT will not be reloaded. Rollback!! \n"
      ret=1
      if File.exists?@tmp_backup_tgz
        backups.each do |x|
          File.delete(x) if File.exist?(x)
        end
        system("cd /etc/snort/#{@group_id}; tar xzf #{@tmp_backup_tgz} . 2>/dev/null")
      end
    end
  end
else
  ret=1
  print "ERROR: the group id #{@group_id} doesn't exist or has no CPUs assigned"
end

exit ret

## vim:ts=4:sw=4:expandtab:ai:nowrap:formatoptions=croqln:
