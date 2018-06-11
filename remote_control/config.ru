require 'bundler/setup'
require 'thin'
require 'faye/websocket'
require_relative 'app.rb'

Faye::WebSocket.load_adapter('thin')
run App

