module Penman
  class SeedFileGenerator
    attr_reader :seed_code
    attr_reader :file_name
    attr_reader :timestamp

    def initialize(file_name, timestamp, seed_code)
      @seed_code = seed_code
      @file_name = file_name
      @timestamp = timestamp
    end

    def write_seed
      erb = ERB.new(File.read(Penman.config.seed_template_file))
      seed_file_name = "#{@timestamp}_#{@file_name}.rb"
      full_seed_file_path = File.join(Penman.config.seed_path, seed_file_name)
      IO.write(full_seed_file_path, erb.result(binding))

      if Penman.config.after_generate.present?
        Penman.config.after_generate.call(@timestamp, @file_name)
      end

      full_seed_file_path
    end
  end
end
