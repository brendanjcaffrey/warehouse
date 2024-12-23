require 'rubygems'
require 'require_all'
require 'sinatra'
require 'tty-command'
require_relative 'shared/config.rb'

task :export do
  Config.set_env('local')
  require_all 'export'

  database = Export::Database.new(Config['database_username'], Config['database_name'])
  library = Export::Library.new
  progress = Export::Progress.new
  Export::Driver.new(database, library, progress).export_itunes_library!
end

task :update_library do
  Config.set_env('local')
  require_all 'export'

  database = Export::Database.new(Config['database_username'], Config['database_name'])
  library = Export::Library.new
  progress = Export::Progress.new
  Export::Driver.new(database, library, progress).update_library!
end

task :local do
  Config.set_env('local')
  require_relative 'server'

  Server.run!
end

task :remote do
  Config.set_env('remote')
  require_relative 'server'

  Server.run!
end

task :proto do
  command = TTY::Command.new
  command.run!('protoc --ruby_out=./shared messages.proto')
  command.run!('protoc --plugin="protoc-gen-ts=./web/node_modules/.bin/protoc-gen-ts" --ts_out="./web/src/generated" ./messages.proto')
end

task :build => [:proto] do
  command = TTY::Command.new
  command.run!('cd web && npm run build')
end

task :vite do
  Dir.chdir('web') do
    exec('node_modules/.bin/vite')
  end
end
