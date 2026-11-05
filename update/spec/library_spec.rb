require 'rspec'
require 'json'
require_relative '../library'

RSpec.describe 'music library text updates' do
  subject(:library) { Update::Library.new }

  let(:command) { instance_double(TTY::Command) }
  let(:track_id) { '0123456789ABCDEF' }
  let(:text) { "\uFEFFcafe\u0301 雪 🎵\r\nO'Brien says \"hello\" \\n \\path\n$(touch /tmp/should-not-exist); `id`\n\n" }

  before do
    allow(TTY::Command).to receive(:new).and_return(command)
    allow(command).to receive(:run).and_raise('unexpected music execution')
  end

  %w[lyrics comments].each do |field|
    describe "#update_#{field}" do
      it 'transports exact text as json data and preserves the read-back line endings' do
        request_path = nil
        allow(command).to receive(:run) do |*args|
          expect(args.take(4)).to eq(['osascript', '-l', 'JavaScript', '-e'])
          script, path = args.last(2)
          property = field == 'comments' ? 'comment' : field
          expect(script).to include("track.#{property} = request.value", "JSON.stringify(track.#{property}())")
          expect(script).not_to include(text, track_id)
          request_path = path
          expect(JSON.parse(File.read(path))).to eq('track_id' => track_id, 'value' => text)
          instance_double(TTY::Command::Result, out: "#{JSON.generate(text)}\n")
        end

        result = nil
        expect { result = library.public_send("update_#{field}", track_id, text) }.to output("updated #{field}\n").to_stdout
        expect(result).to eq(text)
        expect(File.exist?(request_path)).to be(false)
      end

      it 'writes and reads an explicit empty value' do
        allow(command).to receive(:run) do |*, path|
          expect(JSON.parse(File.read(path))['value']).to eq('')
          instance_double(TTY::Command::Result, out: "\"\"\n")
        end

        expect(library.public_send("update_#{field}", track_id, '')).to eq('')
      end

      it 'keeps large text out of the command arguments' do
        large_text = text * 20_000
        allow(command).to receive(:run) do |*args|
          expect(args.join.bytesize).to be < 10_000
          expect(JSON.parse(File.read(args.last))['value']).to eq(large_text)
          instance_double(TTY::Command::Result, out: "#{JSON.generate(large_text)}\n")
        end

        expect(library.public_send("update_#{field}", track_id, large_text)).to eq(large_text)
      end

      it 'cleans up request data and propagates automation failures' do
        request_path = nil
        allow(command).to receive(:run) do |*, path|
          request_path = path
          raise 'automation denied'
        end

        expect { library.public_send("update_#{field}", track_id, text) }.to raise_error('automation denied')
        expect(File.exist?(request_path)).to be(false)
      end

      it 'rejects a changed or missing read-back value and cleans up request data' do
        ['changed text', nil].each do |saved_text|
          request_path = nil
          allow(command).to receive(:run) do |*, path|
            request_path = path
            instance_double(TTY::Command::Result, out: JSON.generate(saved_text))
          end

          expect { library.public_send("update_#{field}", track_id, text) }.to raise_error('music text read-back does not match the queued value')
          expect(File.exist?(request_path)).to be(false)
        end
      end
    end
  end
end
