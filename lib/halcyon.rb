#!/usr/bin/env ruby
#--
#  Created by Matt Todd on 2007-12-14.
#  Copyright (c) 2007. All rights reserved.
#++

$:.unshift File.dirname(__FILE__)

%w(rubygems rack merb-core/core_ext merb-core/dispatch/router json uri logger).each {|dep|require dep}

module Halcyon
  
  VERSION = [0,5,0] unless defined?(Halcyon::VERSION)
  
  autoload :Application, 'halcyon/application'
  autoload :Client, 'halcyon/client'
  autoload :Controller, 'halcyon/controller'
  autoload :Exceptions, 'halcyon/exceptions'
  autoload :Logging, 'halcyon/logging'
  autoload :Runner, 'halcyon/runner'
  
  class << self
    
    attr_accessor :app
    attr_accessor :config
    attr_accessor :logger
    
    def version
      VERSION.join('.')
    end
    
    def root
      self.config[:root] || Dir.pwd rescue Dir.pwd
    end
    
  end
  
end
