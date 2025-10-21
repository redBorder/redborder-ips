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
require 'json'
require 'socket'
require 'net/http'
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
  #
  # Public: Sets the content of the body
  attr_accessor :content

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
  #        :content      - The String content contains the content of the body
  def initialize(opts={})
    server            = opts[:server]
    port              = opts.fetch(:port, 443)
    use_ssl           = opts.fetch(:use_ssl, true)
    ssl_insecure      = opts[:ssl_insecure] ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
    @client_name      = opts[:client_name]
    @key_file         = opts[:key_file]
    @content          = opts[:content]

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
  def post_request(req_path)
    @path = req_path

    begin
      request  = Net::HTTP::Post.new(path, headers)
      request.body = content
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

    body      = content
    timestamp = Time.now.utc.iso8601
    key       = OpenSSL::PKey::RSA.new(File.read(key_file))
    canonical = "Method:POST\nHashed Path:#{encode(_path)}\nX-Ops-Content-Hash:#{encode(body)}\nX-Ops-Timestamp:#{timestamp}\nX-Ops-UserId:#{client_name}"

    header_hash = {
      'Content-Type'       => 'application/json',
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

ret=0
cdomain = File.read('/etc/redborder/cdomain').strip
@weburl = "webui.#{cdomain}"

def usage
  printf "Usage: rb_get_sensor_rules_cloud.rb -u <uuid> -c <command>\n"
  exit 1
end

opt = Getopt::Std.getopts("u:c:h")

usage if ( opt["h"] or (opt["u"].nil? || opt["c"].nil? ) )

printf "Downloading rules: #{opt["c"]} "
client_name = File.read('/etc/chef/nodename').strip
path = '/api/v1/ips/apply_job_info'
uuid=opt["u"].to_s
content=`#{opt["c"]}`
printf "-> done\n"

printf "-----------------------------------------------------------------------------------\n"
puts content
printf "-----------------------------------------------------------------------------------\n"

_content_body= {
  "content" => content,
  "uuid" => uuid
}

@chef=ChefAPI.new(
  server: @weburl,
  use_ssl: true,
  ssl_insecure: true,
  client_name: client_name,
  key_file: "/etc/chef/client.pem",
  content: _content_body.to_json
)

printf "Contacting #{@weburl}#{path} with client name #{client_name}:\n"
result = @chef.post_request(path)

if result
  puts result
  printf "-----------------------------------------------------------------------------------\n"
  ret=0
else
  printf "ERROR contacting server!!\n"
  ret=1
end

exit ret
