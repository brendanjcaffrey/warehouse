require 'net/http'
require 'json'

module Export
  class Driver
    def initialize(database, library, progress)
      @database = database
      @library = library
      @progress = progress
    end

    def update_library!
      if Config.local('update_library')
        @database.get_plays.each do |persistent_id|
          puts @database.get_track_and_artist_name(persistent_id).join(' - ')
          @library.add_play(persistent_id)
        end

        @database.get_ratings.each do |row|
          puts @database.get_track_and_artist_name(row.first).join(' - ')
          @library.update_rating(row.first, row.last)
        end
      end

      if Config.remote('update_library')
        json = JSON.parse(Net::HTTP.get(URI(Config.remote('base_url') + '/updates.json')))
        puts 'Plays:'
        json['plays'].each do |persistent_id|
          puts @database.get_track_and_artist_name(persistent_id).join(' - ')
          @library.add_play(persistent_id)
        end
        puts 'Ratings:'
        json['ratings'].each do |row|
          puts @database.get_track_and_artist_name(row.first).join(' - ')
          @library.update_rating(row.first, row.last)
        end
      end
    end

    def export_itunes_library!
      @database.clean_and_rebuild
      @skipped_tracks = {}
      @needed_folders = {}

      export_tracks ; export_playlists ; export_folders
    end

    private

    def export_tracks
      track_count = @library.total_track_count
      @progress.start('Exporting tracks...', track_count)

      track_count.times do |track_index|
        @progress.increment!
        track = @library.track_info(track_index)

        if track.valid_extension?
          @database.create_track(track)
        else
          puts "Skipping #{track.file} due to invalid extension"
          @skipped_tracks[track.id] = true
        end
      end
    end

    def export_playlists
      playlist_count = @library.total_playlist_count
      @progress.start('Exporting playlists...', playlist_count)

      playlist_count.times do |playlist_index|
        @progress.increment!
        playlist = @library.playlist_info(playlist_index)
        playlist.tracks.reject! { |track_id| @skipped_tracks.has_key?(track_id) }

        if playlist.tracks.count > 0 || (playlist.track_count != '0' && playlist.is_library == 1)
          @database.create_playlist(playlist)
          @needed_folders[playlist.parent_id] = true if playlist.parent_id != -1
        else
          puts "Skipping playlist #{playlist.name} because it has no tracks"
        end
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
