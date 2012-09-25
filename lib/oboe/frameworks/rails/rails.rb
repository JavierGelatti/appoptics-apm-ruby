
module Oboe
  module Inst
    module Rails
      def self.load_initializer
        # Force load the tracelytics Rails initializer if there is one
        # Prefer oboe.rb but give priority to tracelytics.rb if it exists
        if ::Rails::VERSION::MAJOR > 2
          rails_root = "#{::Rails.root.to_s}"
        else
          rails_root = "#{RAILS_ROOT}"
        end

        if File.exists?("#{rails_root}/config/initializers/tracelytics.rb")
          tr_initializer = "#{rails_root}/config/initializers/tracelytics.rb"
        else 
          tr_initializer = "#{rails_root}/config/initializers/oboe.rb"
        end
        require tr_initializer if File.exists?(tr_initializer)
      end

      def self.load_instrumentation
        pattern = File.join(File.dirname(__FILE__), 'inst', '*.rb')
        Dir.glob(pattern) do |f|
          begin
            require f
          rescue => e
            $stderr.puts "[oboe/loading] Error loading rails insrumentation file '#{f}' : #{e}"
          end
        end
        if ::Rails::VERSION::MAJOR > 2
          puts "Tracelytics oboe gem #{Gem.loaded_specs['oboe'].version.to_s} successfully loaded."
        else
          puts "Tracelytics oboe gem #{Oboe::Version::STRING} successfully loaded." 
        end
      end
    end
  end
end

if defined?(::Rails)
  if ::Rails::VERSION::MAJOR > 2
    module Oboe
      class Railtie < ::Rails::Railtie
        config.after_initialize do
          Oboe::Inst::Rails.load_instrumentation
        end
      end
    end
  else
    Oboe::Inst::Rails.load_initializer
    Oboe::Inst::Rails.load_instrumentation
  end
end
