#--

# Copyright 2014 by MTN Sattelite Communications
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#++

require 'yaml'
require 'fileutils'
require 'highline/import'
require 'awesome_print'
require 'fog'
require 'find'
require 'json'
require_relative 'erbalize'

module Shipwright
    class Wizard
        def self.start()
            config = Hash.new
            if File.exists?(File.join(Dir.home, ".shipwright", "config.yml"))
                config = Utils.symbolize_keys(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "default.yml"))).merge(YAML.load_file(File.join(Dir.home, ".shipwright", "config.yml")))
            else
                config = Utils.symbolize_keys(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "default.yml")))
            end

            config[:gerrit_user] = ask("Enter your Gerrit user name:  ") if config[:gerrit_user].nil?
            config[:validator_path] = File.expand_path(ask("Enter full path to the location of mtn pipelines validator pem:  ")) if config[:validator_path].nil?
            config[:validator_client] = ask("Enter the name of your chef validation client (e.g. 'johndoe-validator'):  ") if config[:validator_client].nil?

            if config[:chef_env].nil?
                choose do |menu|
                    menu.prompt = "Which chef environment do you want to use for this ship?  "

                    menu.choice(:staging) { config[:chef_env] = "staging" }
                    menu.choice(:integration) { config[:chef_env] = "integration" }
                    menu.choice(:prod) { config[:chef_env] = "prod" }
                end
            end

            FileUtils::mkdir_p(File.join(Dir.home, ".shipwright"))
            File.open(File.join(Dir.home, ".shipwright", "config.yml"), "w") do |file|
                file.write config.to_yaml
            end

            run(config)
        end

        def self.run(config)
            puts "Cloning #{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/chef-repo"
            
            FileUtils.rm_rf("/tmp/chef-repo") if File.directory?("/tmp/chef-repo")
            pid = Process.spawn(
                "git clone #{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/chef-repo /tmp/chef-repo"
            )
            Process.wait(pid)
            abort("ERROR: failed to clone chef-repo!") unless $?.exitstatus == 0

            puts "Cloning #{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/cookbook-ship"
            FileUtils.rm_rf("/tmp/cookbook-ship") if File.directory?("/tmp/cookbook-ship")
            pid = Process.spawn(
                "git clone #{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/cookbook-ship /tmp/cookbook-ship"
            )
            Process.wait(pid)
            abort("ERROR: failed to clone cookbook-ship!") unless $?.exitstatus == 0

            ships = []
            Find.find('/tmp/cookbook-ship/recipes') do |path|
              ships << path if path =~ /mtn\-aws\-#{Regexp.escape(config[:gerrit_user])}\d+\.rb$/
            end

            # construct a ship name.
            ship_short_name = nil
            if ships.empty?
                ship_short_name = "aws-#{config[:gerrit_user]}1"
            else
                ships.sort!
                ship_short_name = "aws-#{config[:gerrit_user]}#{File.basename( ships[-1], ".*" )[-1].to_i + 1}"
            end
            ship_name = "mtn-#{ship_short_name}"
            puts "New ship name will be: '#{ship_name}'"

            # prepare a new ship recipe
            puts "Preparing new ship recipe in cookbook-ship/recipes/#{ship_name}.rb"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "ship_recipe.rb.erb"), 'r').read
            sources = {
                :ship_name => ship_name
            }
            File.open("/tmp/cookbook-ship/recipes/#{ship_name}.rb", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            puts "Creating a new public elastic ip for infra-#{ship_name}"
            aws_info = JSON.parse( IO.read("/tmp/chef-repo/data_bags/ship-in-a-bottle/aws_access.json") )
            aws = Fog::Compute::AWS.new(
                :aws_access_key_id => aws_info["aws_key"],
                :aws_secret_access_key => aws_info["aws_secret"]
            )
            elastic_ip = aws.allocate_address("vpc")[:body]
            ap elastic_ip

            puts "Adding #{elastic_ip["publicIp"]} IP address to CICD security group for HTTP, HTTPS, SSH, Serf and Gerrit"
            result = aws.authorize_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{elastic_ip["publicIp"]}/32",
                    "FromPort" => "22",
                    "ToPort" => "22",
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to allow SSH ingress for cicd") unless result[:body]["return"] == true
            result = aws.authorize_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{elastic_ip["publicIp"]}/32",
                    "FromPort" => "80",
                    "ToPort" => "80",
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to allow HTTP ingress for cicd") unless result[:body]["return"] == true
            result = aws.authorize_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{elastic_ip["publicIp"]}/32",
                    "FromPort" => "443",
                    "ToPort" => "443",
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to allow HTTPS tcp ingress for cicd") unless result[:body]["return"] == true

            result = aws.authorize_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{elastic_ip["publicIp"]}/32",
                    "FromPort" => "29418",
                    "ToPort" => "29418",
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to allow Gerrit tcp ingress for cicd") unless result[:body]["return"] == true
            
            # load global clluster port from the databag
            serf_info = JSON.parse( IO.read("/tmp/chef-repo/data_bags/serf/global_cluster.json") )
            result = aws.authorize_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{elastic_ip["publicIp"]}/32",
                    "FromPort" => serf_info["bind_port"],
                    "ToPort" => serf_info["bind_port"],
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to allow Serf tcp ingress for cicd") unless result[:body]["return"] == true
            result = aws.authorize_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{elastic_ip["publicIp"]}/32",
                    "FromPort" => serf_info["bind_port"],
                    "ToPort" => serf_info["bind_port"],
                    "IpProtocol" => "udp"
                })
            abort("ERROR: failed to allow Serf udp ingress for cicd") unless result[:body]["return"] == true

            last_run_config = Hash.new
            last_run_config[:eip_alloc] = elastic_ip["allocationId"]
            last_run_config[:eip_address] = elastic_ip["publicIp"]
            last_run_config[:aws_key] = aws_info["aws_key"]
            last_run_config[:aws_secret] = aws_info["aws_secret"]
            last_run_config[:serf_bind_port] = serf_info["bind_port"]
            File.open(File.join(Dir.home, ".shipwright", "lastrun.yml"), "w") do |file|
                file.write last_run_config.to_yaml
            end

            puts "Preparing databags for #{ship_name} and infra-#{ship_name} in chef-repo/data_bags :"
            puts "Preparing chef-repo/data_bags/ships/#{ship_name}.json"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "ship_databag.json.erb"), 'r').read
            sources = {
                :ship_name => ship_name,
                :public_ip => elastic_ip["publicIp"]
            }
            File.open("/tmp/chef-repo/data_bags/ships/#{ship_name}.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            # create the infra databags folder
            FileUtils::mkdir_p("/tmp/chef-repo/data_bags/infra-#{ship_name}")
            puts "Preparing chef-repo/data_bags/infra-#{ship_name}/dhcpd.json"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "dhcpd.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/chef-repo/data_bags/infra-#{ship_name}/dhcpd.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            puts "Preparing chef-repo/data_bags/infra-#{ship_name}/dns.json"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "dns.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/chef-repo/data_bags/infra-#{ship_name}/dns.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            puts "Preparing chef-repo/data_bags/infra-#{ship_name}/firewall.json"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "firewall.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/chef-repo/data_bags/infra-#{ship_name}/firewall.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            puts "Preparing chef-repo/data_bags/infra-#{ship_name}/variables.json"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "variables.json.erb"), 'r').read
            sources = {
                :ship_name => ship_name,
                :public_ip => elastic_ip["publicIp"],
                :ship_short_name => ship_short_name
            }
            File.open("/tmp/chef-repo/data_bags/infra-#{ship_name}/variables.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            puts "Generating zerg task"
            FileUtils::mkdir_p("/tmp/zerg-#{ship_name}")

            puts "Preparing chef_init.rb"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "chef_init.rb.erb"), 'r').read
            sources = {}
            File.open("/tmp/zerg-#{ship_name}/chef_init.rb", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            puts "Preparing templates"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "main_template.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/zerg-#{ship_name}/main_template.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "iam_template.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/zerg-#{ship_name}/iam_template.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "networking_template.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/zerg-#{ship_name}/networking_template.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "othersled_template.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/zerg-#{ship_name}/othersled_template.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "sled1_template.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/zerg-#{ship_name}/sled1_template.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }


            puts "Preparing #{ship_name}.ke file"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "zerg_task.ke.erb"), 'r').read
            rabbit_info = JSON.parse( IO.read("/tmp/chef-repo/data_bags/cicd/chef_handler_rabbit_info.json") )
            sources = {
                :aws_key_id => aws_info["aws_key"],
                :aws_secret => aws_info["aws_secret"],
                :aws_keypair => aws_info["aws_keypair"],
                :ship_name => ship_name,
                :chef_env => config[:chef_env],
                :public_ip_alloc_id => elastic_ip["allocationId"],
                :public_ip_addr => elastic_ip["publicIp"],
                :aws_bucket => "sib-#{ship_short_name}",
                :rabbit_host => rabbit_info["rabbit_host"],
                :rabbit_port => rabbit_info["rabbit_port"],
                :rabbit_user => rabbit_info["rabbit_user"],
                :rabbit_pass => rabbit_info["rabbit_password"],
                :rabbit_vhost => rabbit_info["rabbit_vhost"],
                :rabbit_queue => rabbit_info["rabbit_queue"]["name"],
                :rabbit_exchange => rabbit_info["rabbit_exchange"]["name"],
                :validator_path => config[:validator_path],
                :validator_client => config[:validator_client]
            }
            File.open("/tmp/zerg-#{ship_name}/#{ship_name}.ke", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            #init zerg and import the new task
            pid = Process.spawn(
                "zerg init",
                {
                    :chdir => Dir.home
                }
            )
            Process.wait(pid)
            abort("ERROR: failed to init zerg hive!") unless $?.exitstatus == 0

            pid = Process.spawn(
                "zerg hive import /tmp/zerg-#{ship_name}/#{ship_name}.ke --force",
                {
                    :chdir => Dir.home
                }
            )
            Process.wait(pid)
            abort("ERROR: failed to import zerg task!") unless $?.exitstatus == 0

            puts "Preparing gerrit reviews"
            pipe_cmd_in, pipe_cmd_out = IO.pipe
            pid = Process.spawn(
                "git add -A; git commit -m \"Adding a new ship in a bottle for user #{config[:gerrit_user]}\"; git review",
                {
                    :chdir => "/tmp/chef-repo",
                    :out => pipe_cmd_out
                }
            )
            Process.wait(pid)
            abort("ERROR: failed to prepare chef-repo review!") unless $?.exitstatus == 0
            pipe_cmd_out.close
            output = pipe_cmd_in.read
            chef_repo_out = output[/http:\/\/review.mtnsatcloud.com\/\d+/]
            chef_repo_id = chef_repo_out.split("/").last
            pipe_cmd_in.close

            last_run_config[:chef_repo_sha] = chef_repo_id
            File.open(File.join(Dir.home, ".shipwright", "lastrun.yml"), "w") do |file|
                file.write last_run_config.to_yaml
            end

            pipe_cmd_in, pipe_cmd_out = IO.pipe
            pid = Process.spawn(
                "git add -A; git commit -m \"Adding a new ship in a bottle for user #{config[:gerrit_user]}\"; git review",
                {
                    :chdir => "/tmp/cookbook-ship",
                    :out => pipe_cmd_out
                }
            )
            Process.wait(pid)
            abort("ERROR: failed to prepare cookbook-ship review!") unless $?.exitstatus == 0
            pipe_cmd_out.close
            output = pipe_cmd_in.read
            ship_cookbook_out = output[/http:\/\/review.mtnsatcloud.com\/\d+/]
            cookbook_ship_id = ship_cookbook_out.split("/").last
            pipe_cmd_in.close

            last_run_config[:cookbook_ship_sha] = cookbook_ship_id
            File.open(File.join(Dir.home, ".shipwright", "lastrun.yml"), "w") do |file|
                file.write last_run_config.to_yaml
            end
            
            FileUtils.rm_rf("/tmp/chef-repo")
            FileUtils.rm_rf("/tmp/cookbook-ship")

            puts "--------------------------------------------------ALL DONE!--------------------------------------------------"
            puts "Please get the two reviews below approved by someone from Platform Services team:"
            puts "      #{chef_repo_out}"
            puts "      #{ship_cookbook_out}"
            puts "                          "
            puts "Once approved and merged, start your ship cloud by running \"zerg rush #{ship_name}\" from your home folder."
            puts "                          "
            puts "Public IP: #{elastic_ip["publicIp"]}"
        end
    end
end
