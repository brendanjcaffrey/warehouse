require 'rspec'
require_relative '../library'

RSpec.describe 'music text transport' do
  let(:library) { Update::Library.new }
  let(:track_id) { '0123456789ABCDEF' }
  let(:text) { "\uFEFFcafe\u0301 雪 🎵\r\nO'Brien says \"hello\" \\path \\n\n$(echo injected); `id`\n\n" }
  let(:music_stub) do
    <<~SCRIPT
      var fakeMusicApplication = function(name) {
        if (name !== 'Music') throw new Error('unexpected application');
        var values = {lyrics: 'original lyrics', comment: 'original comments'};
        var track = {};
        ['lyrics', 'comment'].forEach(function(field) {
          Object.defineProperty(track, field, {
            set: function(value) { values[field] = value; },
            get: function() { return function() {
              var other = field === 'lyrics' ? 'comment' : 'lyrics';
              var expected = other === 'lyrics' ? 'original lyrics' : 'original comments';
              if (values[other] !== expected) throw new Error('unrelated field changed');
              return values[field];
            }; }
          });
        });
        return {fileTracks: {whose: function(filter) {
          if (filter.persistentID !== '0123456789ABCDEF') throw new Error('wrong track');
          return [track];
        }}};
      };
    SCRIPT
  end

  %w[lyrics comments].each do |field|
    it "round trips #{field} through real osascript with music replaced by an in-memory stub" do
      skip 'requires macos javascript for automation' unless RUBY_PLATFORM.include?('darwin')

      constant = "Update::Library::UPDATE_#{field.upcase}"
      script = <<~SCRIPT
        #{music_stub}
        var productionRun = (function(Application) {
          if (Application !== fakeMusicApplication) throw new Error('music stub unavailable');
          #{Update::Library.const_get("UPDATE_#{field.upcase}")}
          return run;
        })(fakeMusicApplication);
        function run(argv) { return productionRun(argv); }
      SCRIPT
      stub_const(constant, script)
      allow($stdout).to receive(:puts)

      ['', text, text * 20_000].each do |value|
        expect(library.public_send("update_#{field}", track_id, value).bytes).to eq(value.bytes)
      end
    end
  end
end
