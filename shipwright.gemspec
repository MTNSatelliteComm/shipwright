# -*- encoding: utf-8 -*-
require File.expand_path("../lib/shipwright/version", __FILE__)

Gem::Specification.new do |s|
  s.name        = "shipwright"
  s.version     = Shipwright::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["MTN Satellite Communications"]
  s.email       = ["Marat.Garafutdinov@mtnsat.com"]
  s.homepage    = "https://github.com/MTNSatelliteComm/shipwright"
  s.license     = "MIT"
  s.summary     = "Tool for creating a complete Ship-in-a-Bottle cloud"
  s.description = "Tool for creating a complete Ship-in-a-Bottle cloud"

  s.required_rubygems_version = ">= 2.0.0"
  s.rubyforge_project         = "shipwright"

  s.add_development_dependency "bundler", ">= 1.0.0"
  s.add_development_dependency "rspec", "~> 2.6"
  s.add_development_dependency "cucumber"
  s.add_development_dependency "aruba"
  s.add_development_dependency "rake"

  s.add_dependency "awesome_print"
  s.add_dependency "highline"
  s.add_dependency "fog"
  s.add_dependency "zergrush", ">= 0.0.15"

  s.files        = `git ls-files`.split("\n")
  s.executables  = `git ls-files`.split("\n").map{|f| f =~ /^bin\/(.*)/ ? $1 : nil}.compact
  s.require_path = 'lib'
end
