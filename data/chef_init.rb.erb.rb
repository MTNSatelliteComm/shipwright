#!/usr/bin/ruby
#
#Setup chef client.
#

require 'optparse' 

domain_name = "mtnsatcloud.com"
environment = "prod"
chef_url = nil
organization = nil
ship_name = nil
sled_name = nil
bucket_name = "ship-in-a-bottle"
upload_key = false
user_account = "ubuntu"

#
# process command line
#
OptionParser.new do |o|   
    o.on('-a', '--account account', 'Running as user account') { |account| user_account = account }
    o.on('-b', '--s3-bucket bucket', 'Name of the S3 bucket. Default is ship-in-a-bottle') { |bucket| bucket_name = bucket }
    o.on('-c', '--chef-url chef', 'Chef server url') { |chef| chef_url = chef }
    o.on('-d', '--domain-name domain', 'Domain name to use. Default is mtnsatcloud.com') { |domain| domain_name = domain }
    o.on('-e', '--environment-name env', 'Chef environment. Default is prod') { |env| environment = env }
    o.on('-o', '--organization-name org', 'Chef organization') { |org| organization = org }
    o.on('-s', '--ship-name ship', 'Name of the entire ship') { |ship| ship_name = ship }
    o.on('-l', '--sled-name sled', 'Name of the current sled') { |sled| sled_name = sled }
    o.on('-u', '--upload-key', 'upload client key for later cleanup') { upload_key = true }
    o.on('-h', '--help', 'Display this help') { puts o; exit }
    o.parse!
end

abort("Chef URL is required!") unless chef_url != nil
abort("Organization name is required!") unless organization != nil
abort("Ship name is required!") unless ship_name != nil
abort("Sled name is required!") unless sled_name != nil

#
# build the node name
#
node_name = "#{ship_name}-#{sled_name}" 

#
# Setup Hostname and domainname so chef will work.
#
system("hostname #{node_name}")
system("domainname #{domain_name}")
 
ip_address = %x[ifconfig eth0|grep "inet addr"| awk '{print $2}'| cut -d: -f2| tr -d '\n']
 
File.open("/etc/hostname", "w") do |f|
    f.print <<-EOH
#{node_name}
    EOH
end
 
File.open("/etc/domainname", "w") do |f|
    f.print <<-EOH
#{domain_name}
    EOH
end
 
File.open("/etc/hosts", "a") do |f|
    f.print <<-EOH
#{ip_address} #{node_name}.#{domain_name} #{node_name}
EOH
end
 
#
# Setup client.rb file
#
File.open("/etc/chef/client.rb", "w") do |f|
        f.print <<-EOH
log_level :info
log_location STDOUT
chef_server_url "#{chef_url}/organizations/#{organization}"
validation_client_name "#{organization}-validator"
node_name "#{node_name}.#{domain_name}"
environment "#{environment}"
EOH
end


if upload_key == true
    #
    # Setup knife.rb file
    #
    File.open("/etc/chef/knife.rb", "w") do |f|
            f.print <<-EOH
    log_level :info
    log_location STDOUT
    chef_server_url "#{chef_url}/organizations/#{organization}"
    validation_client_name "#{organization}-validator"
    node_name "#{node_name}.#{domain_name}"
    EOH
    end

    #
    # try to download previous client key and delete the previously created client and node
    #
    client_key_pem = Process.spawn("s3cmd -c /home/#{user_account}/.s3cfg get s3://#{bucket_name}/#{node_name}.#{domain_name}-client.pem /etc/chef/client.pem")
    Process.wait(client_key_pem)
    if $?.exitstatus == 0
        knife_delete_pid = Process.spawn("knife node delete #{node_name}.#{domain_name} --yes --config /etc/chef/knife.rb 2>&1")
        Process.wait(knife_delete_pid)

        knife_delete_pid = Process.spawn("knife client delete #{node_name}.#{domain_name} --yes --config /etc/chef/knife.rb 2>&1")
        Process.wait(knife_delete_pid)
    end

    # cleanup the now - old client pem and knife config
    File.delete("/etc/chef/client.pem") unless !File.exist?("/etc/chef/client.pem")
    File.delete("/etc/chef/knife.rb") unless !File.exist?("/etc/chef/knife.rb")
end

# run chef client
chef_client_pid = Process.spawn("chef-client -j /etc/chef/first-boot.json 2>&1")
Process.wait(chef_client_pid)
chef_run_success = ($?.exitstatus == 0) 

if upload_key == true
    # upload client key file to s3
    s3_upload_pid = Process.spawn("s3cmd -c /home/#{user_account}/.s3cfg put /etc/chef/client.pem s3://#{bucket_name}/#{node_name}.#{domain_name}-client.pem")
    Process.wait(s3_upload_pid)
end

abort("Initial chef client run failed") unless chef_run_success == true

if upload_key == true
    abort("Failed to upload /etc/chef/client.pem to s3://#{bucket_name}/#{node_name}.#{domain_name}-client.pem") unless $?.exitstatus == 0

    # if chef run succeeded - upload the ship chef validator
    s3_upload_pid = Process.spawn("s3cmd -c /home/#{user_account}/.s3cfg put /root/.chef/peasplitter-validation.pem s3://#{bucket_name}/#{node_name}.#{domain_name}-validator.pem")
    Process.wait(s3_upload_pid)
    abort("Could not upload ship chef validator") unless $?.exitstatus == 0
end