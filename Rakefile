require 'rubygems'
require 'require_all'
require 'sinatra'
require_relative 'shared/config.rb'

task :export do
  Config.set_env('local')
  require_all 'export'

  database = Export::Database.new(Config['database_username'], Config['database_name'])
  library = Export::Library.new
  progress = Export::Progress.new
  Export::Driver.new(database, library, progress).export_itunes_library!
end

task :update_plays do
  Config.set_env('local')
  require_all 'export'

  database = Export::Database.new(Config['database_username'], Config['database_name'])
  library = Export::Library.new
  progress = Export::Progress.new
  Export::Driver.new(database, library, progress).update_plays!
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
  require_relative 'export/playlist'

  database = Export::Database.new(Config['database_username'], 'test_itunes_streamer')
  database.clean_and_rebuild
  database.create_track(Export::Track.new(1, 'test_title', '', 'test_artist', '', 'test_album',
                                          '', 'test_genre', 1.23, 0.1, 1.22, 1, 10, 1, 2, 5,
                                          ':__test.mp3'))
  database.create_playlist(Export::Playlist.new(2, 'test_playlist', -1, "3\n4\n5"))
  `echo "1.mp3 contents" > spec/__test.mp3`
  puts `rspec`
  `rm spec/__test.mp3`
end
