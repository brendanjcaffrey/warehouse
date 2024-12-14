require_relative './runner.rb'

module Export
  class Library
    SET_DELIMS = <<-SCRIPT
      set AppleScript'"'"'s text item delimiters to {}
      set oldDelims to AppleScript'"'"'s text item delimiters
    SCRIPT

    RESET_DELIMS = <<-SCRIPT
      set AppleScript'\"'\"'s text item delimiters to oldDelims
    SCRIPT

    TOTAL_TRACK_COUNT = 'tell application "Music" to get count of file tracks in library playlist 1'
    TRACK_INFO = <<-SCRIPT
      tell application "Music"
        set output to ""
        set thisTrack to file track %d

        #{SET_DELIMS}
        set output to persistent ID of thisTrack & "\n"
        set output to output & name of thisTrack & "\n"
        set output to output & sort name of thisTrack & "\n"
        set output to output & artist of thisTrack & "\n"
        set output to output & sort artist of thisTrack & "\n"
        set output to output & album artist of thisTrack & "\n"
        set output to output & sort album artist of thisTrack & "\n"
        set output to output & album of thisTrack & "\n"
        set output to output & sort album of thisTrack & "\n"
        set output to output & genre of thisTrack & "\n"
        set output to output & year of thisTrack & "\n"
        set output to output & duration of thisTrack & "\n"
        set output to output & start of thisTrack & "\n"
        set output to output & finish of thisTrack & "\n"
        set output to output & track number of thisTrack & "\n"
        set output to output & disc number of thisTrack & "\n"
        set output to output & played count of thisTrack & "\n"
        set output to output & rating of thisTrack & "\n"
        set output to output & location of thisTrack as text
        #{RESET_DELIMS}

        output
      end tell
    SCRIPT

    TOTAL_PLAYLIST_COUNT = 'tell application "Music" to get count of user playlists'

    PLAYLIST_INFO = <<-SCRIPT
      tell application "Music"
        set output to ""
        set thisPlaylist to user playlist %1$d

        #{SET_DELIMS}
        set output to output & persistent ID of thisPlaylist & "\n"
        set output to output & name of thisPlaylist & "\n"
        set output to output & special kind of thisPlaylist & "\n"

        try
          get parent of thisPlaylist
          set output to output & persistent ID of parent of thisPlaylist & "\n"
        on error
          set output to output & "" & "\n"
        end try

        set output to output & count of file tracks of thisPlaylist & "\n"
        #{RESET_DELIMS}

        output
      end tell
    SCRIPT

    PLAYLIST_TRACKS = <<-SCRIPT
      tell application "Music"
        set output to ""
        set thisPlaylist to user playlist %1$d

        #{SET_DELIMS}
        repeat with thisTrack in file tracks of user playlist %1$d
          set output to output & persistent ID of thisTrack & "\n"
        end repeat
        #{RESET_DELIMS}

        output
      end tell
    SCRIPT

    TOTAL_FOLDER_COUNT = 'tell application "Music" to get count of folder playlists'

    FOLDER_INFO = <<-SCRIPT
      tell application "Music"
        set output to ""
        set thisFolder to folder playlist %1$d

        #{SET_DELIMS}
        set output to output & persistent ID of thisFolder & "\n"
        set output to output & name of thisFolder & "\n"
        set output to output & special kind of thisFolder & "\n"

        try
          get parent of thisFolder
          set output to output & persistent ID of parent of thisFolder & "\n"
        on error
          set output to output & "" & "\n"
        end try
        #{RESET_DELIMS}

        output
      end tell
    SCRIPT

    GET_PLAYED_COUNT = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        played count of thisTrack as string
      end tell
    SCRIPT

    INCREMENT_PLAYED_COUNT = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        set played count of thisTrack to (played count of thisTrack) + 1
      end tell
    SCRIPT

    GET_TEMPLATE = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        %s of thisTrack
      end tell
    SCRIPT

    UPDATE_TEMPLATE = <<-SCRIPT
      tell application "Music"
        set thisTrack to some file track whose persistent ID is "%s"
        set %s of thisTrack to %s
      end tell
    SCRIPT

    GET_RATING = GET_TEMPLATE % ['%s', 'rating']
    GET_NAME = GET_TEMPLATE % ['%s', 'name']
    GET_ARTIST = GET_TEMPLATE % ['%s', 'artist']
    GET_ALBUM = GET_TEMPLATE % ['%s', 'album']
    GET_ALBUM_ARTIST = GET_TEMPLATE % ['%s', 'album artist']
    GET_GENRE = GET_TEMPLATE % ['%s', 'genre']
    GET_YEAR = GET_TEMPLATE % ['%s', 'year']
    GET_START = GET_TEMPLATE % ['%s', 'start']
    GET_FINISH = GET_TEMPLATE % ['%s', 'finish']
    UPDATE_RATING = UPDATE_TEMPLATE % ['%s', 'rating', '%s']
    UPDATE_NAME = UPDATE_TEMPLATE % ['%s', 'name', '"%s"']
    UPDATE_ARTIST = UPDATE_TEMPLATE % ['%s', 'artist', '"%s"']
    UPDATE_ALBUM = UPDATE_TEMPLATE % ['%s', 'album', '"%s"']
    UPDATE_ALBUM_ARTIST = UPDATE_TEMPLATE % ['%s', 'album artist', '"%s"']
    UPDATE_GENRE = UPDATE_TEMPLATE % ['%s', 'genre', '"%s"']
    UPDATE_YEAR = UPDATE_TEMPLATE % ['%s', 'year', '%s']
    UPDATE_START = UPDATE_TEMPLATE % ['%s', 'start', '%s']
    UPDATE_FINISH = UPDATE_TEMPLATE % ['%s', 'finish', '%s']

    def total_track_count
      `osascript -e '#{TOTAL_TRACK_COUNT}'`.to_i
    end

    def track_info(track_index)
      track_offset = track_index + 1
      seen_error = false

      # this command fails every so often, but waiting and trying again usually works
      5.times do |attempt|
        cmd = "osascript -e '#{TRACK_INFO % track_offset.to_i}'"
        runner = Runner.run(cmd)
        if !runner.success?
          seen_error = true
          puts "error running cmd '#{cmd}'"
          puts "return code: #{runner.exit_status}"
          puts "attempt: #{attempt+1}"
          puts "stderr: #{runner.stderr}"
          puts "stdout: #{runner.stdout}"
          sleep 10
          next
        end

        split = runner.stdout.split("\n")
        return Track.new(*split)
      end

      jobs_webhook.execute do |builder|
        builder.content = "Unable to get track info even after retrying (track_no: #{track_offset})"
      end
      exit(1)
    end

    def total_playlist_count
      `osascript -e '#{TOTAL_PLAYLIST_COUNT}'`.to_i
    end

    def playlist_info(playlist_index)
      playlist_number = playlist_index + 1
      split = `osascript -e '#{PLAYLIST_INFO % playlist_number.to_i}'`.split("\n")
      playlist = Playlist.new(*split)

      if playlist.is_library == 0 # no use having a list of all tracks for the library playlist
        playlist.track_string = `osascript -e '#{PLAYLIST_TRACKS % playlist_number.to_i}'`
      end

      playlist
    end

    def total_folder_count
      `osascript -e '#{TOTAL_FOLDER_COUNT}'`.to_i
    end

    def folder_info(folder_index)
      folder_number = folder_index + 1
      split = `osascript -e '#{FOLDER_INFO % folder_number.to_i}'`.split("\n")
      playlist = Playlist.new(*split)
      playlist.parent_id = '' if playlist.parent_id.nil?
      playlist
    end

    def get_plays(persistent_id)
      `osascript -e '#{GET_PLAYED_COUNT % escape(persistent_id)}'`.chomp
    end

    def add_play(persistent_id)
      start_count = get_plays(persistent_id)
      puts `osascript -e '#{INCREMENT_PLAYED_COUNT % escape(persistent_id)}'`
      end_count = get_plays(persistent_id)
      puts "#{start_count} -> #{end_count}"
    end

    def get_rating(persistent_id)
      `osascript -e '#{GET_RATING % escape(persistent_id)}'`.chomp
    end

    def update_rating(persistent_id, new_rating)
      start_rating = get_rating(persistent_id)
      puts `osascript -e '#{UPDATE_RATING % [escape(persistent_id), new_rating.to_i]}'`
      end_rating = get_rating(persistent_id)
      puts "#{start_rating} -> #{end_rating}"
    end

    def get_name(persistent_id)
      `osascript -e '#{GET_NAME % escape(persistent_id)}'`.chomp
    end

    def update_name(persistent_id, new_name)
      start_name = get_name(persistent_id)
      puts `osascript -e '#{UPDATE_NAME % [escape(persistent_id), escape(new_name)]}'`
      end_name = get_name(persistent_id)
      puts "#{start_name} -> #{end_name}"
    end

    def get_artist(persistent_id)
      `osascript -e '#{GET_ARTIST % escape(persistent_id)}'`.chomp
    end

    def update_artist(persistent_id, new_artist)
      start_artist = get_artist(persistent_id)
      puts `osascript -e '#{UPDATE_ARTIST % [escape(persistent_id), escape(new_artist)]}'`
      end_artist = get_artist(persistent_id)
      puts "#{start_artist} -> #{end_artist}"
    end

    def get_album(persistent_id)
      `osascript -e '#{GET_ALBUM % escape(persistent_id)}'`.chomp
    end

    def update_album(persistent_id, new_album)
      start_album = get_album(persistent_id)
      puts `osascript -e '#{UPDATE_ALBUM % [escape(persistent_id), escape(new_album)]}'`
      end_album = get_album(persistent_id)
      puts "#{start_album} -> #{end_album}"
    end

    def get_album_artist(persistent_id)
      `osascript -e '#{GET_ALBUM_ARTIST % escape(persistent_id)}'`.chomp
    end

    def update_album_artist(persistent_id, new_album_artist)
      start_album_artist = get_album_artist(persistent_id)
      puts `osascript -e '#{UPDATE_ALBUM_ARTIST % [escape(persistent_id), escape(new_album_artist)]}'`
      end_album_artist = get_album_artist(persistent_id)
      puts "#{start_album_artist} -> #{end_album_artist}"
    end

    def get_genre(persistent_id)
      `osascript -e '#{GET_GENRE % escape(persistent_id)}'`.chomp
    end

    def update_genre(persistent_id, new_genre)
      start_genre = get_genre(persistent_id)
      puts `osascript -e '#{UPDATE_GENRE % [escape(persistent_id), escape(new_genre)]}'`
      end_genre = get_genre(persistent_id)
      puts "#{start_genre} -> #{end_genre}"
    end

    def get_year(persistent_id)
      `osascript -e '#{GET_YEAR % escape(persistent_id)}'`.chomp
    end

    def update_year(persistent_id, new_year)
      start_year = get_year(persistent_id)
      puts `osascript -e '#{UPDATE_YEAR % [escape(persistent_id), new_year.to_i]}'`
      end_year = get_year(persistent_id)
      puts "#{start_year} -> #{end_year}"
    end

    def get_start(persistent_id)
      `osascript -e '#{GET_START % escape(persistent_id)}'`.chomp
    end

    def update_start(persistent_id, new_start)
      start_start = get_start(persistent_id)
      puts `osascript -e '#{UPDATE_START % [escape(persistent_id), new_start.to_i]}'`
      end_start = get_start(persistent_id)
      puts "#{start_start} -> #{end_start}"
    end

    def get_finish(persistent_id)
      `osascript -e '#{GET_FINISH % escape(persistent_id)}'`.chomp
    end

    def update_finish(persistent_id, new_finish)
      finish_finish = get_finish(persistent_id)
      puts `osascript -e '#{UPDATE_FINISH % [escape(persistent_id), new_finish.to_i]}'`
      end_finish = get_finish(persistent_id)
      puts "#{finish_finish} -> #{end_finish}"
    end

    def escape(str)
      str.gsub('"', '\"').gsub("'", "'\"'\"'")
    end
  end
end
