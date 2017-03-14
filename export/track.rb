module Export
  ACCEPTABLE_EXTENSIONS = ['mp3', 'mp4', 'm4a', 'aiff', 'aif', 'wav']

  class Track < Struct.new(:id, :persistent_id, :name, :sort_name, :artist, :sort_artist, :album, :sort_album,
    :genre, :duration, :start, :finish, :track, :track_count, :disc, :disc_count, :play_count, :location)

    def file
      # location is like "Macintosh HD:Users:Brendan:Music:iTunes:iTunes Music:artist:album:song.mp3"
      # so we turn the : into /, remove the drive name and lop off what the config provides
      location.gsub(':', '/').gsub(/^.+?\//, '/').gsub(Config['music_path'], '')
    end

    def ext
      file.split('.').last.downcase
    end

    def valid_extension?
      ACCEPTABLE_EXTENSIONS.index(ext) != nil
    end
  end
end
