require 'yaml'
require 'fileutils'
require 'thread'

module TicketBot
  class Configuration

    CONFIG_FILE = File.expand_path('../../../settings.yml', __dir__)

    def initialize
      @data = load_config
      @lock = Mutex.new
    end

    # Generic reader
    def [](key)
      @lock.synchronize { @data[key] }
    end

    # Generic writer
    def []=(key, value)
      @lock.synchronize do
        @data[key] = value
        save_config_unsafe
      end
    end

    private

    def load_config
      # 1. Define strictly the keys you care about
      defaults = {
        org_id: nil,
        my_agent_id: nil
      }

        # 1. Create file if missing
      unless File.exist?(CONFIG_FILE)
        # Ensure directory exists first
        dirname = File.dirname(CONFIG_FILE)
        FileUtils.mkdir_p(dirname) unless File.directory?(dirname)
        
        # Write defaults to the new file
        File.open(CONFIG_FILE, 'w') { |f| f.write(defaults.to_yaml) }
        puts "ℹ️ Settings file was not found.! \n Created new configuration file at #{CONFIG_FILE}"
      end

      begin
        loaded_data = YAML.load_file(CONFIG_FILE, symbolize_names: true)

        # 3. Edge Case: Empty file
        return defaults if loaded_data.nil? || loaded_data == false

        defaults.merge(loaded_data)

      rescue StandardError => e
        puts "⚠️ Config Load Error: #{e.message}. Settings all configurations to 'nil'."
        defaults
      end
    end

    def save_config_unsafe
      dirname = File.dirname(CONFIG_FILE)
      FileUtils.mkdir_p(dirname) unless File.directory?(dirname)

      File.open(CONFIG_FILE, 'w') { |f| f.write(@data.to_yaml) }
    end
  end
end