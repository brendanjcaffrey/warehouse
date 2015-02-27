module Export
  class Track < Struct.new(:id, :name, :sort_name, :artist, :sort_artist, :album, :sort_album,
    :genre, :duration, :start, :finish, :track, :track_count, :disc, :disc_count, :play_count, :location)
    def file
      location.split(':', 2)[1].gsub(/^Users:.*?:Music:/, '').gsub(':', '/')
    end
  end
end
