# frozen_string_literal: true

require 'fileutils'
require 'minitar'
require 'securerandom'

# builds cached tar bundles of music/artwork files for the watch app
module Bundles
  CAPS = { music: 50, artwork: 1000 }.freeze
  CHUNK_SIZE = 1024 * 1024

  module_function

  # creates <bundles_path>/<uuid>.tar with entries "<type>/<filename>" and
  # returns the uuid; source files are streamed in chunks so large bundles
  # never live in memory, and symlinks are dereferenced by File.open
  def create(type:, filenames:, source_path:, bundles_path:)
    FileUtils.mkdir_p(bundles_path)
    uuid = SecureRandom.uuid
    out_path = File.join(bundles_path, "#{uuid}.tar")
    tmp_path = "#{out_path}.tmp"

    File.open(tmp_path, 'wb') do |tar_io|
      Minitar::Writer.open(tar_io) do |writer|
        filenames.each do |filename|
          full_path = File.join(source_path, filename)
          size = File.size(full_path)
          writer.add_file_simple("#{type}/#{filename}", mode: 0o644, size: size, mtime: 0) do |entry_io|
            File.open(full_path, 'rb') do |file|
              while (chunk = file.read(CHUNK_SIZE))
                entry_io.write(chunk)
              end
            end
          end
        end
      end
    end

    File.rename(tmp_path, out_path)
    uuid
  end
end
