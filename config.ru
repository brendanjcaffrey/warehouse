require 'rubygems'
require 'sinatra'
require 'require_all'

require_relative 'shared/config.rb'
Config.set_env('remote')

require_relative 'serve.rb'
require_relative 'serve'

run Serve
