module Export
  class Driver
    def initialize(database, library, progress)
      @database = database
      @library = library
      @progress = progress
    end

    def go!
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
