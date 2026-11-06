# frozen_string_literal: true

require 'time'
require_relative '../helpers'

describe Helpers do
  describe '#timestamp_to_ns' do
    [
      ['2026-11-05 20:16:52', 0],
      ['2026-11-05 20:16:52.1', 100_000_000],
      ['2026-11-05 20:16:52.123456', 123_456_000],
      ['2026-11-05 20:16:52.123456789', 123_456_789],
      ['2026-11-05 20:16:52.000000001', 1]
    ].each do |timestamp, nanoseconds|
      it "converts #{timestamp} to exact utc nanoseconds" do
        helpers = Object.new.extend(described_class)
        expected = (Time.utc(2026, 11, 5, 20, 16, 52).to_i * 1_000_000_000) + nanoseconds

        expect(helpers.timestamp_to_ns(timestamp)).to eq(expected)
      end
    end
  end
end
