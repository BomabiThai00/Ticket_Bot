require 'logger'
require 'fileutils'

module TicketBot
  class Log
    def self.instance
      @logger ||= setup
    end

    def self.setup
      FileUtils.mkdir_p('logs')
      file = File.open('logs/bot.log', 'a')
      
      # MultiIO allows writing to both Terminal and File
      logger = Logger.new(MultiIO.new(STDOUT, file))
      
      logger.level = Logger::INFO
      logger.formatter = proc do |severity, datetime, progname, msg|
        "[#{datetime.strftime('%H:%M:%S')}] #{severity}: #{msg}\n"
      end
      logger
    end
  end

  class MultiIO
    def initialize(*targets)
      @targets = targets
    end
    def write(*args)
      @targets.each { |t| t.write(*args) }
    end
    def close
      @targets.each(&:close)
    end
  end
end
