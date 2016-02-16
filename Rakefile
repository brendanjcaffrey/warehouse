require 'require_all'
require 'sinatra'
require_relative 'shared/config.rb'

task :export do
  Config.set_env('local')
  require_all 'export'

  database = Export::Database.new(Config['database_username'], Config['database_name'])
  library = Export::Library.new
  progress = Export::Progress.new
  Export::Driver.new(database, library, progress).go!
end

task :local do
  Config.set_env('local')
  require_relative 'serve'

  Serve.run!
end

task :remote do
  Config.set_env('remote')
  require_relative 'serve'

  Serve.run!
end

task :test do
  require_relative 'shared/config'
  Config.set_env('local')

  require_relative 'export/database'
  require_relative 'export/track'

  database = Export::Database.new(Config['database_username'], 'test_itunes_streamer')
  database.build_tables
  database.create_track(Export::Track.new(1, 'test_title', '', 'test_artist', '', 'test_album',
                                          '', 'test_genre', 1.23, 0.1, 1.22, 1, 10, 1, 2, 5,
                                          ':__test.mp3'))
  `echo "1.mp3 contents" > __test.mp3`
  puts `rspec`
  `rm __test.mp3`
end
