%w{ config lib }.each {|l| $LOAD_PATH.unshift("#{File.expand_path(File.dirname(__FILE__))}/../#{l}") }

require 'satellite'
