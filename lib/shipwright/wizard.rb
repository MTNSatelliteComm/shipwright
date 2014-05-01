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
            if File.exists?(File.join("~", ".shipwright", "config.yml"))
                config = symbolize_keys(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "default.yml"))).merge(YAML.load_file(File.join("~", ".shipwright", "config.yml")))
            else
                config = symbolize_keys(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "default.yml")))
            end

            config[:gerrit_user] = ask("Enter your Gerrit user name:  ") if config[:gerrit_user].nil?
            config[:validator_path] = ask("Enter full path to the location of mtn pipelines validator pem:  ") if config[:validator_path].nil?

            FileUtils::mkdir_p(File.join("~", ".shipwright"))
            File.open(File.join("~", ".shipwright", "config.yml"), "w") do |file|
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
              ships << path if path =~ /mtn\-#{Regexp.escape(config[:gerrit_user])}\d+\.rb$/
            end

            # construct a ship name.
            ship_short_name = nil
            if ships.empty?
                ship_short_name = "#{config[:gerrit_user]}1"
            else
                ships.sort!
                ship_short_name = "#{config[:gerrit_user]}#{File.basename( ships[-1], ".*" )[-1].to_i + 1}"
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

            puts "Preparing databags for #{ship_name} and infra-#{ship_name} in chef-repo/data_bags :"
            puts "Preparing chef-repo/data_bags/ships/#{ship_name}.json"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "ship_databag.json.erb"), 'r').read
            sources = {
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

            puts "Preparing template.json"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "template.json.erb"), 'r').read
            sources = {}
            File.open("/tmp/zerg-#{ship_name}/template.json", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }


            puts "Preparing #{ship_name}.ke file"
            item_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "zerg_task.ke.erb"), 'r').read
            rabbit_info = JSON.parse( IO.read("/tmp/chef-repo/data_bags/ship-in-a-bottle/rabbit_info.json") )
            sources = {
                :aws_key_id => aws_info["aws_key"],
                :aws_secret => aws_info["aws_secret"],
                :aws_keypair => aws_info["aws_keypair"],
                :ship_name => ship_name,
                :public_ip_alloc_id => elastic_ip["allocationId"],
                :aws_bucket => "sib-#{ship_short_name}",
                :rabbit_host => rabbit_info["rabbit_host"],
                :rabbit_port => rabbit_info["rabbit_port"],
                :rabbit_user => rabbit_info["rabbit_user"],
                :rabbit_pass => rabbit_info["rabbit_password"],
                :rabbit_vhost => rabbit_info["rabbit_vhost"],
                :rabbit_queue => rabbit_info["rabbit_queue"]["name"],
                :rabbit_exchange => rabbit_info["rabbit_exchange"]["name"],
                :validator_path => config[:validator_path]
            }
            File.open("/tmp/zerg-#{ship_name}/#{ship_name}.ke", 'w') { |file| file.write(Erbalize.erbalize_hash(item_template, sources)) }

            #init zerg and import the new task
            pid = Process.spawn(
                {
                    "HIVE_CWD" => "~"
                },
                "zerg init"
            )
            Process.wait(pid)
            abort("ERROR: failed to init zerg hive!") unless $?.exitstatus == 0

            pid = Process.spawn(
                {
                    "HIVE_CWD" => "~"
                },
                "zerg hive import /tmp/zerg-#{ship_name}/#{ship_name}.ke"
            )
            Process.wait(pid)
            abort("ERROR: failed to import zerg task!") unless $?.exitstatus == 0

            puts "Preparing gerrit reviews"
            FileUtils.rm "/tmp/shipwright-commit-message" if File.exist?("/tmp/shipwright-commit-message")
            File.open("/tmp/shipwright-commit-message", 'w') { |file| file.write("Adding a new ship in a bottle for user #{config[:gerrit_user]}") }
            pid = Process.spawn(
                "git add -A; git commit -t /tmp/shipwright-commit-message; git review",
                {
                    :chdir => "/tmp/chef-repo"
                }
            )
            Process.wait(pid)
            abort("ERROR: failed to prepare chef-repo review!") unless $?.exitstatus == 0

            pid = Process.spawn(
                "git add -A; git commit -t /tmp/shipwright-commit-message; git review",
                {
                    :chdir => "/tmp/cookbook-ship"
                }
            )
            Process.wait(pid)
            abort("ERROR: failed to prepare cookbook-ship review!") unless $?.exitstatus == 0
            
            FileUtils.rm_rf("/tmp/chef-repo")
            FileUtils.rm_rf("/tmp/cookbook-ship")

            puts "SUCCESS!"
            puts "Get the two review links above approved by someone from Platform services first."
            puts "Once approved and merged, start your ship cloud by running \"zerg rush #{ship_name}\" from your home folder."
        end

        def self.symbolize_keys(hash)
            hash.inject({}) {|result, (key, value)|
                new_key = case key
                    when String then key.to_sym
                    else key
                end
                new_value = case value
                    when Hash then symbolize_keys(value)
                    else value
                end
                result[new_key] = new_value
                result
            }
        end
    end
end