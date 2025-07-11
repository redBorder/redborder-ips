#!/usr/bin/env ruby

require 'net/http'
require 'openssl'
require 'uri'
require 'socket'
require 'digest'
require 'base64'
require 'yaml'
require 'net/ip'
require 'system/getifaddrs'
require 'netaddr'
require 'base64'
require 'fileutils'

module Config_utils

    LOG_DIRECTORY = '/var/log/rb-register-common'
    LOG_FILE_NAME = 'register.log'

    @modelist_path="/usr/lib/redborder/mode-list.yml"

    #Function to check if mode is valid (if defined in mode-list.yml)
    #Returns true if it's valid and false if not
    #TODO: protect from exception like file not found
    def self.check_mode(mode)
        mode_list = YAML.load_file(@modelist_path)
        return mode_list.map { |x| x["name"] }.include?(mode)
    end

    # Function that return an encript key from a provided string
    # compliance with serf encrypt_key (password of 16 bytes in base64 format)
    def self.get_encrypt_key(password)
        ret = nil
        unless password.nil?
            if password.class == String
                ret = Base64.encode64(Digest::MD5.hexdigest(password)[0..15]).chomp
            end
        end
        ret
    end

    # Resolve manager dns name to ip
    def self.managerToIp(str)
      ipv4_regex = /\A(\d{1,3}\.){3}\d{1,3}\z/
      ipv6_regex = /\A(?:[A-Fa-f0-9]{1,4}:){7}[A-Fa-f0-9]{1,4}\z/
      dns_regex = /\A[a-zA-Z0-9\-]+\.[a-zA-Z0-9\-.]+\z/
      return str if str =~ ipv4_regex || str =~ ipv6_regex
      if str =~ dns_regex
        ip = `dig +short #{str}`.strip
        return ip unless ip.empty?
      end
    end

    # Generate hosts for ips to send data to the manager
    def self.hook_hosts(domain, cdomain)
      domain = managerToIp(domain)
      hosts_content = File.read('/etc/hosts')
      hosts_content.gsub!(/^.*\bdata\.redborder\.cluster\b.*$/, '')
      hosts_content.gsub!(/^.*\brbookshelf\.s3\.redborder\.cluster\b.*$/, '')
      hosts_content << "#{domain} data.#{cdomain} kafka.service kafka.#{cdomain} erchef.#{cdomain} erchef.service.#{cdomain} rbookshelf.s3.#{cdomain} #{cdomain} s3.service.#{cdomain} http2k.#{cdomain} webui.service\n"
      File.write('/etc/hosts', hosts_content)
    end

    # Replace chef server urls
    def self.replace_chef_server_url(cdomain)
      chef_paths = [
        '/etc/chef/client.rb.default',
        '/etc/chef/client.rb',
        '/etc/chef/knife.rb.default',
        '/etc/chef/knife.rb',
        '/root/.chef/knife.rb'
      ]

      chef_paths.each do |file_path|
        if File.file?(file_path)
          file_content = File.read(file_path)

          file_content.gsub!(/^chef_server_url\s+['"].*['"]/, "chef_server_url          \"https://erchef.service.#{cdomain}/organizations/redborder\"")

          File.write(file_path, file_content)
        end
      end
    end

    def self.log_file
      File.join(LOG_DIRECTORY, LOG_FILE_NAME)
    end

    # Create log file for registration without rb-register
    def self.ensure_log_file_exists

      unless Dir.exist?(LOG_DIRECTORY)
        system("mkdir -p #{LOG_DIRECTORY}")
      end

      if File.exist?(log_file)
        system("truncate -s 0 #{log_file}")
      else
        system("touch #{log_file}")
      end
    end

    # Set role for chef
    def self.update_chef_roles(mode)
      file_paths = [
        '/etc/chef/role-once.json.default',
        '/etc/chef/role.json.default'
      ]

      content = {
        "run_list": [
          "role[sensor]",
          mode == "proxy" ? "role[ipscp-sensor]" : "role[ips-sensor]"
        ],
        "redBorder": {
          "force-run-once": true
        }
      }

      file_paths.each do |file_path|
        FileUtils.mkdir_p(File.dirname(file_path))

        File.open(file_path, 'w') do |file|
          file.write(JSON.pretty_generate(content))
        end
      end
    end

    # Check credentials of the manager are correct
    def self.check_manager_credentials(host, user, pass)
      url = URI("https://#{host}/api/v1/users/login")
      params = { 'user[username]' => user, 'user[password]' => pass }
      headers = { 'Accept' => 'application/json' }

      begin
        http = Net::HTTP.new(url.host, url.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE

        response = http.post(url.path, URI.encode_www_form(params), headers)

        return response.code == '200'
      rescue StandardError => e
        puts "Error: #{e.message}"
        return false
      end
    end

    # Function to remove lines matching a pattern from specific files
    def self.remove_ssl_verify_mode_lines
      file_paths = [
        '/etc/chef/client.rb.default',
        '/etc/chef/client.rb'
      ]

      pattern = /^\s*ssl_verify_mode/

      file_paths.each do |file_path|
        if File.file?(file_path)
          lines = File.readlines(file_path)
          lines.reject! { |line| line.match?(pattern) }
          File.open(file_path, 'w') do |file|
            file.puts lines
          end
        end
      end
    end

    # Function to generate a random nodename
    # it will retrieve a random host for regular ips registration to the manager
    def self.generate_random_hostname
      characters = ('a'..'z').to_a + ('0'..'9').to_a
      random_id = Array.new(8) { characters.sample }.join
      hostname = "rbips-#{random_id}"
      hostname
    end

    # Function to get my own ip address
    def self.get_ip_address
      ip = Socket.ip_address_list.detect(&:ipv4_private?).ip_address
      ip
    end

    # Function to check a valid IPv4 IP address
    # ipv4 parameter can be a hash with two keys:
    # - :ip -> ip to be checked
    # - :netmask -> mask to be checked
    # Or can be a string with CIDR or standard notation.
    def self.check_ipv4(ipv4)
        ret = true
        begin
            # convert ipv4 from string format "192.168.1.0/255.255.255.0" into hash {:ip => "192.168.1.0", :netmask => "255.255.255.0"}
            if ipv4.class == String
                unless ipv4.match(/^(?<ip>\d+\.\d+\.\d+\.\d+)\/(?<netmask>(?:\d+\.\d+\.\d+\.\d+)|\d+)$/).nil?
                    ipv4 = ipv4.match(/^(?<ip>\d+\.\d+\.\d+\.\d+)\/(?<netmask>(?:\d+\.\d+\.\d+\.\d+)|\d+)$/)
                else
                    ret = false
                end
            end
            x = NetAddr::CIDRv4.create("#{ipv4[:ip].nil? ? "0.0.0.0" : ipv4[:ip]}/#{ipv4[:netmask].nil? ? "255.255.255.255" : ipv4[:netmask]}")
        rescue NetAddr::ValidationError => e
            # error: netmask incorrect
            ret = false
        rescue => e
            # general error
            ret = false
        end
        ret
    end

   # Function to check a valid domain. Based on rfc1123 and sethostname().
   # Suggest rfc1178
   # Max of 253 characters with hostname
   def self.check_domain(domain)
     ret = false
     unless (domain =~ /^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$/).nil?
       ret = true
     end
     ret
   end

  # Function to check a valid cloud address
   # Suggest rfc1178
   # Max of 253 characters with hostname
   def self.check_cloud_address(cloud_address)
    ret = false
    unless (cloud_address =~ /^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$/).nil?
      ret = true
    end
    ret
  end

   # Function to check hostname. # Based on rfc1123 and sethostname()
   # Max of 63 characters
   def self.check_hostname(name)
     ret = false
     unless (name =~ /^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$/).nil?
       ret = true
     end
     ret
   end

    #TODO: Function to check encrypt key format
    def self.check_encryptkey(encrypt_key)
      return true
    end

    # Function that return true if the interface dev has a default route or false if not
    def self.has_default_route?(dev)
      ret = false
      Net::IP.routes.each do |r|
        if r.to_h[:dev] == dev.to_s
          if r.to_h[:prefix] == "default"
            ret = true
            break
          end
        end
      end
      ret
    end

    # Function that retrun the gateway if exist for dev interface
    def self.get_gateway(dev)
      ret = nil
      Net::IP.routes.each do |r|
        route = r.to_h
        next unless route[:dev] == dev
        next unless route[:prefix] == "default"
        ret = route[:via]
      end
      ret
    end

    # Function that return the first route non default for one dev interface
    def self.get_first_route(dev)
      ret = {}
      Net::IP.routes.each do |r|
        route = r.to_h
        next unless route[:dev] == dev
        next unless route[:prefix] != "default"
        ret = route
        break
      end
      ret
    end

    # TODO ipv6 support
    def self.get_ipv4_network(devname)
      hsh = {}
      # looking for device with default route
      Net::IP.routes.each do |r|
          unless r.to_h[:via].nil?
              if r.to_h[:dev] == devname
                  if r.to_h[:prefix] == "default" or r.to_h[:prefix] == "0.0.0.0/0"
                      hsh[:gateway] = r.to_h[:via]
                      break
                  end
              end
          end
      end
      System.get_all_ifaddrs.each do |i|
          if i[:interface].to_s == devname
              if i[:inet_addr].ipv4?
                  hsh[:ip] = i[:inet_addr].to_s
                  hsh[:netmask] = i[:netmask].to_s
              end
          end
      end
      hsh
    end

    # Function that return a hash with route object that contains the default route
    # with maximun metric
    def self.get_default_max_metric
      ret = {}
      Net::IP.routes.each do |r|
        route = r.to_h
        route[:metric] = 1 if route[:metric].nil?
        # only perform with default routes
        if route[:prefix] == "default"
          if ret.empty?
            # first default route founded
            ret = route
          else
            # new route has metric bigger than saved route?
            if route[:metric] > ret[:metric]
              ret = route # this is the new saved route
            end
          end
        end
      end
      ret
    end

   # POSTGRESQL PARAMETER CHECKS
   #TODO
   def self.check_sql_host(host)
       return true
   end
   #TODO
   def self.check_sql_port(port)
       return true
   end
   #TODO
   def self.check_sql_superuser(superuser)
       return true
   end
   #TODO
   def self.check_sql_password(password)
       return true
   end

   #S3 PARAMETER CHECKS
   #TODO
   def self.check_accesskey(access_key)
       return true
   end
   #TODO
   def self.check_secretkey(secret_key)
       return true
   end
   #TODO
   def self.check_s3bucket(bucket)
       return true
   end
   #TODO
   def self.check_s3endpoint(endpoint)
       return true
   end

   #ELASTICACHE PARAMETER CHECKS
   #TODO
   def self.check_elasticache_cfg_address(address)
       return true
   end
   #TODO
   def self.check_elasticache_cfg_port(port)
       return true
   end

  # Function to start bpctl if the machine support it
  def self.net_init_bypass
    return true if File.exists?("/dev/bpctl")

    # trying to initialize bypass module controller
    system("/usr/bin/bpctl_start &>/dev/null")
    return File.exists?("/dev/bpctl") # True/False depending if there is no bypass hardware
  end

  # Functions that tells you if an interfaces has bypass support or not
  def self.net_get_device_bypass_support(interface)
    return false unless File.exists?("/dev/bpctl")

    # There is a hardware bypass device loaded
    system("bpctl_util #{interface} is_bypass | grep -q -i \"The interface is not Bypass-SD/TAP-SD device\"")
    return !$?.success?
  end

  def self.net_get_device_bypass_master(interface)
    return false unless net_get_device_bypass_support(interface)
    system("bpctl_util #{interface} get_bypass_slave | grep -q -i \"The interface is a slave interface\"")
    return !$?.success?
  end

  # Get real mac of interface
  def self.net_get_real_mac(interface)
    system("ip a s #{interface} | egrep -q \"bond\"")
    return system("cat /sys/class/net/#{interface}/address") unless $?.success?

    #this iface belongs to a bonding
    interface_bond=system("ip a s dev #{interface}|grep bond|tr ' ' '\n'|grep bond|head -n 1")
    return system("grep -A 10 \"Slave Interface: #{interface}\" /proc/net/bonding/#{interface_bond} | grep \"Permanent HW addr:\" | head -n 1 | awk '{print $4}'")
  end

  # return true if the interface is slave; if not returns the mac adress of the slave interface
  def self.net_get_device_bypass_slave(interface)
    if net_get_device_bypass_support(interface)
        system("bpctl_util #{interface} get_bypass_slave | grep -q -i \"The interface is a slave interface\"")
        return interface if $?.success?
        return `bpctl_util #{interface} get_bypass_slave | grep \"^slave: \" | awk '{print $3}'`.strip
    else
        return false
    end
  end

  # Function that returns the bypass master interface from the list we pass
  def self.net_port_get_bypass_master(net_dev_list)
    master_list = []
    net_dev_list.each do |netdev|
       master_list.push(netdev) if net_get_device_bypass_master(netdev)
    end
    return master_list
  end

  # TODO: DNA stuff related
  def self.net_segment_autoassign_bypass(segments = [], management_interface = "")
    segments = [] unless segments
    net_dev_list = Dir.entries("/sys/class/net/").select {|f| !File.directory? f}
    net_ports_bypass_master_list = net_port_get_bypass_master(net_dev_list)
    net_ports_bypass_master_list.each do |index_master|
      next if index_master == management_interface
      next unless segments.select{|segment| segment.key?"ports" and segment["ports"].include? index_master}.empty?
      index_slave = net_get_device_bypass_slave(index_master)
      next if index_slave == management_interface
      next unless segments.select{|segment| segment.key?"ports" and segment["ports"].include? index_slave}.empty?
      bypass_segments = segments.select{|s| s.name.start_with?"bp"} rescue []
      segment = {}
      #segment["name"] = "bpbr" + (bypass_segments.count > 0 ? bypass_segments.count.to_s : 0.to_s)
      segment["name"] = "bpbr" + (segments.count > 0 ? segments.count.to_s : 0.to_s)
      segment["ports"] = "#{index_master} #{index_slave}".split(" ")
      segment['bypass_support'] = true
      segments.push(segment)
    end
    return segments
  end

  def self.get_pf_ring_num_slots(num_segments)
    net_queues = `ls -d /sys/class/cpuid/* | wc -l`.strip.to_i
    mem_total = `cat /proc/meminfo |grep MemTotal|awk '{print $2}'`.strip.to_i
    mem_slots = 16384*1 # Default value
    num_slots = 16384*1 # 16k Default value
    if mem_total > 32000000
      num_slots = 16384*1 # 16k
    elsif mem_total > 64000000
      if num_segments == 1
        num_slots = 16384*4 # 64k
      elsif num_segments == 2
        num_slots = 16384*2 # 32k
      elsif num_segments == 3
        num_slots = 16384*2 # 32k
      else #>= 4 segments
        num_slots = 16384*1 # 16k
      end
    else # >= 64Gbytes
      if num_segments == 1
        num_slots = 16384*8 #128k
      elsif num_segments < 4
        num_slots = 16384*4 #64k
      else
        num_slots = 16384*2 #32k
      end
    end

    if num_slots > 16384 and net_queues > 8
      num_slots = num_slots / 2
    end
    return num_slots
  end

  def self.get_pf_ring_bypass_interfaces
    pf_ring_bypass_interfaces = []
    listnetdev = Dir.entries("/sys/class/net/").select {|f| !File.directory? f}
    listnetdev.each do |netdev|
        # loopback and devices with no pci nor mac are not welcome!
        next if netdev == "lo"
        if Config_utils.net_get_device_bypass_support(netdev) and Config_utils.net_get_device_bypass_master(netdev)
          netdev_slave = Config_utils.net_get_device_bypass_slave(netdev)
          # order matters need to have the slave first
          if netdev_slave and listnetdev.include?netdev_slave
            pf_ring_bypass_interfaces.push(netdev_slave)
            pf_ring_bypass_interfaces.push(netdev)
          end
        end
    end
    return pf_ring_bypass_interfaces
  end

  def self.is_local_tty
    system('tty | egrep -q "/dev/tty[S0-9][0-9]*"')
    return $?.success?
  end

  def self.has_internet?
    require "resolv"
    dns_resolver = Resolv::DNS.new()
    begin
      dns_resolver.getaddress("repo.redborder.com")
      return true
    rescue Resolv::ResolvError => e
      return false
    end
  end

  def self.get_pether_status(pether)
    if File.exists?"/sys/class/net/#{pether}/operstate"
      pether_status=`cat /sys/class/net/#{pether}/operstate`.strip
    else
      pether_status="unkn"
    end

    return pether_status
  end

  def self.get_pether_speed(pether)
    pether_speed="unkn"

    if File.exists?"/sys/class/net/#{pether}/speed"
      pether_speed=`cat /sys/class/net/#{pether}/speed 2>/dev/null`.strip
    end

    pether_speed="unkn" if pether_speed.nil? or pether_speed.empty? or pether_speed.to_s == "-1"
    return pether_speed
  end

  def self.get_pether_duplex(pether)
    pether_duplex="unkn"

    if File.exists?"/sys/class/net/#{pether}/duplex"
      pether_duplex=`cat /sys/class/net/#{pether}/duplex 2>/dev/null`.strip
    end
    pether_duplex="unkn" if pether_duplex.nil? or pether_duplex.empty?
    return pether_duplex
  end

  def self.ipmi_capable?
    return File.exists?"/dev/ipmi0"
  end

  def self.get_ipmi_properties
    net_ipmi_ip=`ipmitool lan print 1| egrep "^IP Address[ ]*:" | awk -F : '{print $2}' | sed 's/ //g'`.strip
    net_ipmi_netmask=`ipmitool lan print 1| egrep "^Subnet Mask[ ]*:" | awk -F : '{print $2}' | sed 's/ //g'`.strip
    if !Config_utils.check_ipv4({:ip => net_ipmi_ip}) and !Config_utils.check_ipv4({:netmask => net_ipmi_netmask})
      net_ipmi_ip = ""
      net_ipmi_netmask = ""
    end

    net_ipmi_gateway=`ipmitool lan print 1| egrep "^Default Gateway IP[ ]*:" | awk -F : '{print $2}' | sed 's/ //g'`.strip
    net_ipmi_gateway = "" unless Config_utils.check_ipv4({:ip => net_ipmi_gateway})

    return { :ip => net_ipmi_ip, :netmask => net_ipmi_netmask, :gateway => net_ipmi_gateway}
  end

  def self.get_network_interfaces
    interfaces = []
    `ip link show`.each_line do |line|
      if line =~ /^\d+: ([^:]+):/
        interfaces << $1 if $1 != "lo"
      end
    end
    interfaces
  end

  def self.need_to_rename_network_interfaces?
    interfaces = get_network_interfaces
    interfaces_to_rename = []
    interfaces.each do |interface|
      interfaces_to_rename << interface if interface.length > 15
    end
    interfaces_to_rename.any?
  end

end

## vim:ts=4:sw=4:expandtab:ai:nowrap:formatoptions=croqln:
