module Export
  class Library
    TOTAL_TRACK_COUNT = 'tell application "iTunes" to get count of tracks in library playlist 1'
    TRACK_INFO = <<-SCRIPT
      tell application "iTunes"
        set thisTrack to track %d of library playlist 1

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
        output & location of thisTrack as text
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
  end
end
