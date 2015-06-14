require 'net/http'
require 'json'

module Export
  class Driver
    def initialize(database, library, progress)
      @database = database
      @library = library
      @progress = progress
    end

    def go!
      if Config.local('update_plays')
        puts 'Updating local plays...'
        @database.plays.each do |database_id|
          @library.add_play(database_id)
        end
      end

      if Config.remote('update_plays')
        puts 'Updating remote plays...'
        uri = URI(Config.remote('base_url') + '/plays.json')
        JSON.parse(Net::HTTP.get(uri)).each do |database_id|
          @library.add_play(database_id)
        end
      end

      @database.build_tables
      track_count = @library.total_track_count
      @progress.start('Exporting tracks...', track_count)

      track_count.times do |track_index|
        @progress.increment!
        @database.create_track(@library.track_info(track_index))
      end

      playlist_count = @library.total_playlist_count
      @progress.start('Exporting playlists...', playlist_count)
      playlist_count.times do |playlist_index|
        @progress.increment!
        playlist = @library.playlist_info(playlist_index)
        @database.create_playlist(playlist)
      end
    end
  end
end
