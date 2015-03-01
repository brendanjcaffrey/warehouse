module Export
  class Playlist < Struct.new(:id, :name, :parent_id, :track_string)
    def tracks
      @tracks ||= track_string.split("\n")
    end
  end
end
