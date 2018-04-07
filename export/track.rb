module Export
  ACCEPTABLE_EXTENSIONS = ['mp3', 'mp4', 'm4a', 'aiff', 'aif', 'wav']

  class Track < Struct.new(:id, :name, :sort_name_unclean, :artist, :sort_artist_unclean, :album, :sort_album_unclean,
    :genre, :duration, :start, :finish, :track, :track_count, :disc, :disc_count, :play_count, :location)

    def file
      # location is like "Macintosh HD:Users:Brendan:Music:iTunes:iTunes Music:artist:album:song.mp3"
      # so we turn the : into /, remove the drive name and lop off what the config provides
      location.gsub(':', '/').gsub(/^.+?\//, '/').gsub(Config['music_path'], '')
    end

    def sort_name
      value = clean_sort_value(sort_name_unclean.empty? ? name : sort_name_unclean)
      value != name ? value : ""
    end

    def sort_artist
      value = clean_sort_value(sort_artist_unclean || artist)
      value != album ? value : ""
    end

    def sort_album
      value = clean_sort_value(sort_album_unclean || album)
      value != album ? value : ""
    end

    def ext
      file.split('.').last.downcase
    end

    def valid_extension?
      ACCEPTABLE_EXTENSIONS.index(ext) != nil
    end

    private

    def clean_sort_value(value)
      # remove anything that isn't alphanumeric (except 0?)
      # TODO e.g. '03 Bonnie & Clyde sorting as 3, I think it's just nat sorting if it starts with a number, but this works for now
      value.gsub(/^[^a-zA-Z1-9]+/, '')
    end
  end
end
