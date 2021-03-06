require "broken_record/logger"
require 'parallel'

module BrokenRecord
  class Scanner
    def run(model_name = nil)
      models = models_to_validate(model_name)

      BrokenRecord::Config.before_scan_callbacks.each { |callback| callback.call }

      results = BrokenRecord::Logger.parallel do |lock|
        Parallel.map(models) do |model|
          result = validate_model(model)
          BrokenRecord::Logger.report_output(result, lock)
          result
        end
      end

      BrokenRecord::Logger.report_results(results)
    end

    private

    def models_to_validate(model_name)
      if model_name
        [ model_name.constantize ]
      else
        load_all_active_record_classes
      end
    end

    def load_all_active_record_classes
      Dir.glob(Rails.root.to_s + '/app/models/**/*.rb').each { |file| require file }
      objects = Set.new
      ObjectSpace.each_object(Class) do |klass|
        if ActiveRecord::Base > klass
          # Use base_class so we don't try to validate abstract classes and so we don't validate
          # STI classes multiple times.  See active_record/inheritance.rb for more details.
          objects.add klass.base_class unless BrokenRecord::Config.classes_to_skip.include?(klass)
        end
      end

      objects.sort_by(&:name)
    end

    def validate_model(model)
      ActiveRecord::Base.connection.reconnect!

      BrokenRecord::Logger.log(model) do |logger|
        begin
          if BrokenRecord::Config.default_scopes[model]
            model_scope = model.instance_exec &BrokenRecord::Config.default_scopes[model]
          else
            model_scope = model.unscoped
          end

          model_scope.find_each do |r|
            begin
              if !r.valid?
                message = "    Invalid record in #{model} id=#{r.id}."
                r.errors.each { |attr,msg| message <<  "\n        #{attr} - #{msg}" }
                logger.log_error message
              end
            rescue Exception => msg
              logger.log_error "    Exception for record in #{model} id=#{r.id} - #{msg}."
            end
          end
        rescue Exception => msg
          logger.log_error "    Error querying model #{model} - #{msg}."
        end
      end
    end
  end
end