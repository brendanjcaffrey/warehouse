module Export
  class Library
    SET_DELIMS = <<-SCRIPT
      set AppleScript'"'"'s text item delimiters to {}
      set oldDelims to AppleScript'"'"'s text item delimiters
    SCRIPT

    RESET_DELIMS = <<-SCRIPT
      set AppleScript'\"'\"'s text item delimiters to oldDelims
    SCRIPT

    TOTAL_TRACK_COUNT = 'tell application "iTunes" to get count of file tracks in library playlist 1'
    TRACK_INFO = <<-SCRIPT
      tell application "iTunes"
        set output to ""
        set thisTrack to file track %d

        #{SET_DELIMS}
        set output to database ID of thisTrack & "\n"
        set output to output & name of thisTrack & "\n"
        set output to output & sort name of thisTrack & "\n"
        set output to output & artist of thisTrack & "\n"
        set output to output & sort artist of thisTrack & "\n"
        set output to output & album of thisTrack & "\n"
        set output to output & sort album of thisTrack & "\n"
        set output to output & genre of thisTrack & "\n"
        set output to output & duration of thisTrack & "\n"
        set output to output & start of thisTrack & "\n"
        set output to output & finish of thisTrack & "\n"
        set output to output & track number of thisTrack & "\n"
        set output to output & track count of thisTrack & "\n"
        set output to output & disc number of thisTrack & "\n"
        set output to output & disc count of thisTrack & "\n"
        set output to output & played count of thisTrack & "\n"
        set output to output & location of thisTrack as text
        #{RESET_DELIMS}

        output
      end tell
    SCRIPT

    TOTAL_PLAYLIST_COUNT = 'tell application "iTunes" to get count of user playlists'

    PLAYLIST_INFO = <<-SCRIPT
      tell application "iTunes"
        set output to ""
        set thisPlaylist to user playlist %1$d

        #{SET_DELIMS}
        set output to output & id of thisPlaylist & "\n"
        set output to output & name of thisPlaylist & "\n"
        set output to output & special kind of thisPlaylist & "\n"

        try
          get parent of thisPlaylist
          set output to output & id of parent of thisPlaylist & "\n"
        on error
          set output to output & "-1" & "\n"
        end try

        set output to output & count of file tracks of thisPlaylist & "\n"
        #{RESET_DELIMS}

        output
      end tell
    SCRIPT

    PLAYLIST_TRACKS = <<-SCRIPT
      tell application "iTunes"
        set output to ""
        set thisPlaylist to user playlist %1$d

        #{SET_DELIMS}
        repeat with thisTrack in file tracks of user playlist %1$d
          set output to output & database ID of thisTrack & "\n"
        end repeat
        #{RESET_DELIMS}

        output
      end tell
    SCRIPT

    TOTAL_FOLDER_COUNT = 'tell application "iTunes" to get count of folder playlists'

    FOLDER_INFO = <<-SCRIPT
      tell application "iTunes"
        set output to ""
        set thisFolder to folder playlist %1$d

        #{SET_DELIMS}
        set output to output & id of thisFolder & "\n"
        set output to output & name of thisFolder & "\n"
        set output to output & special kind of thisFolder & "\n"

        try
          get parent of thisFolder
          set output to output & id of parent of thisFolder & "\n"
        on error
          set output to output & "-1" & "\n"
        end try
        #{RESET_DELIMS}

        output
      end tell
    SCRIPT

    INCREMENT_PLAYED_COUNT = <<-SCRIPT
      tell application "iTunes"
        set thisTrack to some file track of library playlist 1 whose database ID is %d
        set played count of thisTrack to (played count of thisTrack) + 1
      end tell
    SCRIPT

    def total_track_count
      `osascript -e '#{TOTAL_TRACK_COUNT}'`.to_i
    end

    def track_info(track_index)
      track_number = track_index + 1
      split = `osascript -e '#{TRACK_INFO % track_number}'`.split("\n")
      Track.new(*split)
    end

    def total_playlist_count
      `osascript -e '#{TOTAL_PLAYLIST_COUNT}'`.to_i
    end

    def playlist_info(playlist_index)
      playlist_number = playlist_index + 1
      split = `osascript -e '#{PLAYLIST_INFO % playlist_number}'`.split("\n")
      playlist = Playlist.new(*split)

      if playlist.is_library == 0 # no use having a list of all tracks for the library playlist
        playlist.track_string =  `osascript -e '#{PLAYLIST_TRACKS % playlist_number}'`
      end

      playlist
    end

    def total_folder_count
      `osascript -e '#{TOTAL_FOLDER_COUNT}'`.to_i
    end

    def folder_info(folder_index)
      folder_number = folder_index + 1
      split = `osascript -e '#{FOLDER_INFO % folder_number}'`.split("\n")
      Playlist.new(*split)
    end

    def add_play(track_id)
      `osascript -e '#{INCREMENT_PLAYED_COUNT % track_id}'`
    end
  end
end
