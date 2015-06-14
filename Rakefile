require 'require_all'
require_relative 'shared/config.rb'

task :export do
  Config.set_env('local')
  require_all 'export'

  database = Export::Database.new(Config['database_name'])
  library = Export::Library.new
  progress = Export::Progress.new
  Export::Driver.new(database, library, progress).go!
end

task :serve do
  Config.set_env('local')
  require_relative 'serve'

  Sinatra::Application.run!
end

task :remote do
  Config.set_env('remote')
  require_relative 'serve'

  Sinatra::Application.run!
end
