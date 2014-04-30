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
require 'grit'
require 'awesome_print'
require 'fog'
require 'find'
require_relative 'erbalize'

include Grit

module Shipwright
    class Wizard
        def self.start()
            config = Hash.new
            if File.exists?(File.join("~", ".shipwright", "config.yml"))
                config = symbolize_keys(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "default.yml"))).merge(YAML.load_file(File.join("~", ".shipwright", "config.yml")))
            else
                config = symbolize_keys(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "default.yml")))
            end

            config[:github_user] = ask("Enter your Github user name:  ") if config[:github_user].nil?
            config[:github_password] = ask("Enter your Github password:  ") { |q| q.echo = "*" } if config[:github_password].nil?
            config[:gerrit_user] = ask("Enter your Gerrit user name:  ") if config[:gerrit_user].nil?
            config[:aws_key_id] = ask("Enter your AWS key id:  ") if config[:aws_key_id].nil?
            config[:aws_secret] = ask("Enter your AWS secret:  ") { |q| q.echo = "*" } if config[:aws_secret].nil?

            run(config)
        end

        def self.run(config)
            puts "Cloning #{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/chef-repo"
            
            FileUtils.rm_rf("/tmp/chef-repo") if File.directory?("/tmp/chef-repo")
            chef_repo = Grit::Git.new('/tmp/chef-repo')
            chef_repo.clone({:quiet => false, :verbose => true, :progress => true, :branch => 'master'}, "#{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/chef-repo", "/tmp/chef-repo")
            
            puts "Cloning #{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/cookbook-ship"
            
            FileUtils.rm_rf("/tmp/cookbook-ship") if File.directory?("/tmp/cookbook-ship")
            ships_repo = Grit::Git.new('/tmp/cookbook-ship')
            ships_repo.clone({:quiet => false, :verbose => true, :progress => true, :branch => 'master'}, "#{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/cookbook-ship", "/tmp/cookbook-ship")

            ships = []
            Find.find('/tmp/cookbook-ship/recipes') do |path|
              ships << path if path =~ /mtn\-#{Regexp.escape(config[:gerrit_user])}\d+\.rb$/
            end

            # construct a ship name.
            ship_name = nil
            if ships.empty?
                ship_name = "mtn-#{config[:gerrit_user]}1"
            else
                ships.sort!
                ship_name = "mtn-#{config[:gerrit_user]}#{File.basename( ships[-1], ".*" )[-1].to_i + 1}"
            end
            puts "New ship name will be: '#{ship_name}'"

            # prepare a new ship recipe
            puts "Preparing new ship recipe in cookbook-ship/recipes/#{ship_name}.rb"
            schema_template = File.open(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "ship_recipe.rb.erb"), 'r').read
            sources = {
                :ship_name => ship_name
            }
            File.open("/tmp/cookbook-ship/recipes/#{ship_name}.rb", 'w') { |file| file.write(Erbalize.erbalize_hash(schema_template, sources)) }

            FileUtils.rm_rf("/tmp/chef_repo")
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