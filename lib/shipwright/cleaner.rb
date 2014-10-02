require 'yaml'
require 'fileutils'
require 'highline/import'
require 'awesome_print'
require 'fog'
require 'find'
require 'json'

module Shipwright
    class Cleaner
        def self.start()
            config = Hash.new
            if File.exists?(File.join(Dir.home, ".shipwright", "config.yml"))
                config = Utils.symbolize_keys(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "default.yml"))).merge(YAML.load_file(File.join(Dir.home, ".shipwright", "config.yml")))
            else
                config = Utils.symbolize_keys(YAML.load_file(File.join("#{File.dirname(__FILE__)}", "..", "..", "data", "default.yml")))
            end

            config[:gerrit_user] = ask("Enter your Gerrit user name:  ") if config[:gerrit_user].nil?
            config[:validator_path] = ask("Enter full path to the location of mtn pipelines validator pem:  ") if config[:validator_path].nil?

            FileUtils::mkdir_p(File.join(Dir.home, ".shipwright"))
            File.open(File.join(Dir.home, ".shipwright", "config.yml"), "w") do |file|
                file.write config.to_yaml
            end

            cleanup(config)
        end

        def self.destroy
            if File.exists?(File.join(Dir.home, ".shipwright", "config.yml"))
                File.delete(File.join(Dir.home, ".shipwright", "config.yml"))
            end

            if File.exists?(File.join(Dir.home, ".shipwright", "lastrun.yml"))
                File.delete(File.join(Dir.home, ".shipwright", "lastrun.yml"))
            end
            
            puts "SUCCESS!"
        end

        def self.cleanup(config)
            abort("Nothing to cleanup!") unless File.exists?(File.join(Dir.home, ".shipwright", "lastrun.yml"))
            cleanup_config = YAML.load_file(File.join(Dir.home, ".shipwright", "lastrun.yml"))

            # cleanup chef-repo change
            if cleanup_config[:chef_repo_sha] != nil
                pid = Process.spawn(
                    "ssh -p #{config[:gerrit_port]} #{config[:gerrit_user]}@#{config[:gerrit_host]} gerrit review --project chef-repo --abandon #{cleanup_config[:chef_repo_sha]},1"
                )
                Process.wait(pid)
                abort("ERROR: failed abandon chef-repo changes!") unless $?.exitstatus == 0
            end

            if cleanup_config[:cookbook_ship_sha] != nil
                # cleanup cookbook-ship change
                 pid = Process.spawn(
                    "ssh -p #{config[:gerrit_port]} #{config[:gerrit_user]}@#{config[:gerrit_host]} gerrit review --project cookbook-ship --abandon #{cleanup_config[:cookbook_ship_sha]},1"
                )
                Process.wait(pid)
                abort("ERROR: failed abandon cookbook-ship changes!") unless $?.exitstatus == 0
            end

            # cleanup ip address
            if cleanup_config[:eip_alloc] != nil
                aws = Fog::Compute::AWS.new(
                    :aws_access_key_id => cleanup_config[:aws_key],
                    :aws_secret_access_key => cleanup_config[:aws_secret]
                )
                elastic_ip = aws.release_address(cleanup_config[:eip_alloc])
                abort("ERROR: failed abandon cookbook-ship changes!") unless elastic_ip[:body]["return"] == true
            end

            # cleanup security group ingresses
            result = aws.revoke_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{cleanup_config[:eip_address]}/32",
                    "FromPort" => "22",
                    "ToPort" => "22",
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to revoke SSH ingress for cicd") unless result[:body]["return"] == true
            result = aws.revoke_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{cleanup_config[:eip_address]}/32",
                    "FromPort" => "80",
                    "ToPort" => "80",
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to revoke HTTP ingress for cicd") unless result[:body]["return"] == true
            result = aws.revoke_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{cleanup_config[:eip_address]}/32",
                    "FromPort" => "443",
                    "ToPort" => "443",
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to revoke HTTP ingress for cicd") unless result[:body]["return"] == true
            result = aws.revoke_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{cleanup_config[:eip_address]}/32",
                    "FromPort" => cleanup_config[:serf_bind_port],
                    "ToPort" => cleanup_config[:serf_bind_port],
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to revoke serf tcp ingress for cicd") unless result[:body]["return"] == true
            result = aws.revoke_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{cleanup_config[:eip_address]}/32",
                    "FromPort" => cleanup_config[:serf_bind_port],
                    "ToPort" => cleanup_config[:serf_bind_port],
                    "IpProtocol" => "udp"
                })
            abort("ERROR: failed to revoke serf udp ingress for cicd") unless result[:body]["return"] == true

            result = aws.revoke_security_group_ingress(
                "cicd", 
                {
                    "CidrIp" => "#{cleanup_config[:eip_address]}/32",
                    "FromPort" => "29418",
                    "ToPort" => "29418",
                    "IpProtocol" => "tcp"
                })
            abort("ERROR: failed to revoke Gerrit tcp ingress for cicd") unless result[:body]["return"] == true

            File.delete(File.join(Dir.home, ".shipwright", "lastrun.yml"))
            puts "SUCCESS!"
        end
    end
end