require 'net/http'
require 'json'
require_relative '../shared/jwt'
require_relative '../shared/messages_pb'

module Update
  class Updater
    def initialize(database, library)
      @database = database
      @library = library
      @local_artwork_dir = File.expand_path(Config.local.artwork_path)
    end

    def update_library!
      if Config.local.update_library
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
        artwork_updates(@database.get_artwork_updates)
      end

      return unless Config.remote.update_library

      jwt = build_jwt('export_driver_update_library', Config.remote.secret)
      response = execute_remote_request('/api/updates', jwt)
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

      flat_artwork_updates = flatten_updates(updates.artworks)
      flat_artwork_updates.each do |_, artwork_filename|
        next if has_artwork?(artwork_filename)

        response = execute_remote_request("/artwork/#{artwork_filename}", jwt)
        if response.is_a?(Net::HTTPSuccess)
          puts "Successfully fetched artwork: #{artwork_filename}"
          put_artwork(artwork_filename, response.body)
        else
          puts "HTTP request failed with status: #{response.code} #{response.message}"
          exit(1)
        end
      end
      artwork_updates(flat_artwork_updates)
    end

    private

    def execute_remote_request(path, jwt)
      uri = URI("#{Config.remote.base_url}#{path}")
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{jwt}"

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end
    end

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

    def artwork_updates(artworks)
      puts "\n=== Artworks ==="
      artworks.each do |row|
        puts @database.get_track_and_artist_name(row.first).join(' - ')
        @library.update_artwork(row.first, row.last)
      end
    end

    def has_artwork?(filename)
      File.exist?(File.join(@local_artwork_dir, filename))
    end

    def put_artwork(filename, contents)
      File.open(File.join(@local_artwork_dir, filename), 'wb') do |file|
        file.write(contents)
      end
    end
  end
end
