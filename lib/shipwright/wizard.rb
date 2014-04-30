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
include Grit

module Shipwright
    class Wizard
        def self.start()
            config = Hash.new
            if File.exists?(File.join("~", ".shipwright", "config.yml"))
                config = YAML.load_file(File.join("~", ".shipwright", "config.yml")).merge(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "data", "default.yml")))
            else
                config = YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "data", "default.yml"))
            end

            run(config)
        end

        def self.run(config)
            config[:github_user] = ask("Enter your Github user name:  ") if config[:github_user].nil?
            config[:github_password] = ask("Enter your Github password:  ") { |q| q.echo = "*" } if config[:github_password].nil?
            config[:gerrit_user] = ask("Enter your Gerrit user name:  ") if config[:gerrit_user].nil?

            puts "Cloning #{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/chef-repo"
            
            FileUtils.rm_rf("/tmp/chef_repo") if File.directory?("/tmp/chef_repo")
            chef_repo = Grit::Git.new('/tmp/chef_repo')
            gritty.clone({:quiet => false, :verbose => true, :progress => true, :branch => 'master'}, "#{config[:gerrit_protocol]}://#{config[:gerrit_user]}@#{config[:gerrit_host]}:#{config[:gerrit_port]}/chef-repo", "/tmp/chef_repo")
            FileUtils.rm_rf("/tmp/chef_repo")
        end
    end
end