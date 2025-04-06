require 'net/http'
require 'json'
require_relative '../shared/jwt.rb'
require_relative '../shared/messages_pb.rb'

module Export
  class Driver
    def initialize(database, library, progress)
      @database = database
      @library = library
      @progress = progress
    end

    def update_library!
      if Config.local('update_library')
        play_updates(@database.get_plays)
        rating_updates(@database.get_ratings)
        name_updates(@database.get_name_updates)
        artist_updates(@database.get_artist_updates)
        album_updates(@database.get_album_updates)
        album_artist_updates(@database.get_album_artist_updates)
        genre_updates(@database.get_genre_updates)
        year_updates(@database.get_year_updates)
        start_updates(@database.get_start_updates)
        finish_updates(@database.get_finish_updates)
      end

      if Config.remote('update_library')
        uri = URI("#{Config.remote('base_url')}/api/updates")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'

        request = Net::HTTP::Get.new(uri)
        request['Authorization'] = "Bearer #{build_jwt('export_driver_update_library', Config.remote('secret'))}"
        response = http.request(request)
        updates = nil

        if response.is_a?(Net::HTTPSuccess)
          begin
            updates = UpdatesResponse.decode(response.body)
            if updates.response == :error
              puts "failed to fetch updates: #{updates.error}"
              exit(1)
            end
          rescue Google::Protobuf::ParseError => e
            puts "failed to parse protobuf: #{e.message}"
            exit(1)
          end
        else
          puts "HTTP request failed with status: #{response.code} #{response.message}"
          exit(1)
        end

        updates = updates.updates
        play_updates(updates.plays.map(&:trackId))
        rating_updates(flatten_updates(updates.ratings))
        name_updates(flatten_updates(updates.names))
        artist_updates(flatten_updates(updates.artists))
        album_updates(flatten_updates(updates.albums))
        album_artist_updates(flatten_updates(updates.albumArtists))
        genre_updates(flatten_updates(updates.genres))
        year_updates(flatten_updates(updates.years))
        start_updates(flatten_updates(updates.starts))
        finish_updates(flatten_updates(updates.finishes))
      end
    end

    def export_itunes_library!
      @database.clean_and_rebuild
      @skipped_tracks = {}
      @needed_folders = {}

      export_tracks
      export_playlists
      export_folders
      @database.set_library_metadata(@library.total_file_size)
      @database.set_export_finished
    end

    private

    def flatten_updates(updates)
      updates.map { [_1.trackId, _1.value] }
    end

    def play_updates(plays)
      puts "\n=== Plays ==="
      plays.each do |persistent_id|
        puts @database.get_track_and_artist_name(persistent_id).join(' - ')
        @library.add_play(persistent_id)
      end
    end

    def rating_updates(ratings)
      puts "\n=== Ratings ==="
      ratings.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_rating(row.first, row.last)
      end
    end

    def name_updates(names)
      puts "\n=== Names ==="
      names.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_name(row.first, row.last)
      end
    end

    def artist_updates(artists)
      puts "\n=== Artists ==="
      artists.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_artist(row.first, row.last)
      end
    end

    def album_updates(albums)
      puts "\n=== Albums ==="
      albums.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_album(row.first, row.last)
      end
    end

    def album_artist_updates(album_artists)
      puts "\n=== Album Artists ==="
      album_artists.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_album_artist(row.first, row.last)
      end
    end

    def genre_updates(genres)
      puts "\n=== Genres ==="
      genres.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_genre(row.first, row.last)
      end
    end

    def year_updates(years)
      puts "\n=== Years ==="
      years.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_year(row.first, row.last)
      end
    end

    def start_updates(starts)
      puts "\n=== Starts ==="
      starts.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_start(row.first, row.last)
      end
    end

    def finish_updates(finishes)
      puts "\n=== Finishes ==="
      finishes.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_finish(row.first, row.last)
      end
    end

    def export_tracks
      track_count = @library.total_track_count
      @progress.start('Exporting tracks...', track_count)

      track_count.times do |track_index|
        @progress.increment!
        track = @library.track_info(track_index)

        if track.valid_extension?
          @database.create_track(track)
          track.artworks.each { |artwork_filename| @database.create_track_artwork(track.id, artwork_filename) }
        else
          puts "Skipping #{track.file} due to invalid extension"
          @skipped_tracks[track.id] = true
        end
      end

      @library.cleanup_artwork
    end

    def export_playlists
      playlist_count = @library.total_playlist_count
      @progress.start('Exporting playlists...', playlist_count)

      playlist_count.times do |playlist_index|
        @progress.increment!
        playlist = @library.playlist_info(playlist_index)
        next if playlist.skip?

        playlist.tracks.reject! { |track_id| @skipped_tracks.has_key?(track_id) }

        @database.create_playlist(playlist)
        @needed_folders[playlist.parent_id] = true if playlist.parent_id != -1
      end
    end

    def export_folders
      folder_count = @library.total_folder_count
      @progress.start('Exporting folders...', folder_count)

      folder_count.times do |folder_index|
        @progress.increment!
        folder = @library.folder_info(folder_index)

        if @needed_folders.has_key?(folder.id)
          @database.create_playlist(folder)
        else
          puts "Skipping folder #{folder.name} because it has no children"
        end
      end
    end
  end
end
