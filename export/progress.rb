require 'progress_bar'

module Export
  class Progress
    def start(message, count)
      puts message
      @bar = ProgressBar.new(count, :counter, :bar, :eta)
    end

    def increment!
      @bar.increment!
    end
  end
end
