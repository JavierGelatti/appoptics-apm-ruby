# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

require "minitest_helper"

if defined?(::Rails)

  describe "Rails5x" do
    before do
      clear_all_traces
      AppOpticsAPM.config_lock.synchronize {
        @tm = AppOpticsAPM::Config[:tracing_mode]
        @collect_backtraces = AppOpticsAPM::Config[:action_controller][:collect_backtraces]
        @collect_ar_backtraces = AppOpticsAPM::Config[:active_record][:collect_backtraces]
        @sample_rate = AppOpticsAPM::Config[:sample_rate]
        @sanitize_sql = AppOpticsAPM::Config[:sanitize_sql]

        AppOpticsAPM::Config[:action_controller][:collect_backtraces] = false
        AppOpticsAPM::Config[:active_record][:collect_backtraces] = false
        AppOpticsAPM::Config[:rack][:collect_backtraces] = false
      }
      ENV['DBTYPE'] = "postgresql" unless ENV['DBTYPE']
    end

    after do
      AppOpticsAPM.config_lock.synchronize {
        AppOpticsAPM::Config[:action_controller][:collect_backtraces] = @collect_backtraces
        AppOpticsAPM::Config[:active_record][:collect_backtraces] = @collect_ar_backtraces
        AppOpticsAPM::Config[:tracing_mode] = @tm
        AppOpticsAPM::Config[:sample_rate] = @sample_rate
        AppOpticsAPM::Config[:sanitize_sql] = @sanitize_sql
      }

      uri = URI.parse('http://127.0.0.1:8140/widgets/delete_all')
      _ = Net::HTTP.get_response(uri)
    end

    it "should create a span for a partial" do
      uri = URI.parse('http://127.0.0.1:8140/hello/with_partial')

      _ = Net::HTTP.get_response(uri)

      traces = get_all_traces
      _(traces.count).must_equal 8

      _(traces[3]['Layer']).must_equal "partial"
      _(traces[3]['Label']).must_equal "entry"
      _(traces[3]['Partial']).must_equal "somepartial"
      _(traces[4]['Layer']).must_equal "partial"
      _(traces[4]['Label']).must_equal "exit"
    end

    it "should create a span for a collection" do
      uri = URI.parse('http://127.0.0.1:8140/widgets')

      _ = Net::HTTP.get_response(uri)

      traces = get_all_traces
      _(traces.count).must_equal 16

      _(traces[11]['Layer']).must_equal "collection"
      _(traces[11]['Label']).must_equal "entry"
      _(traces[11]['Partial']).must_equal "widget"
      _(traces[12]['Layer']).must_equal "collection"
      _(traces[12]['Label']).must_equal "exit"
    end

    it "should trace a request to a rails stack" do
      uri = URI.parse('http://127.0.0.1:8140/hello/world')
      r = Net::HTTP.get_response(uri)

      traces = get_all_traces

      _(traces.count).must_equal 6
      unless defined?(JRUBY_VERSION)
        # We don't test this under JRuby because the Java instrumentation
        # for the DB drivers doesn't use our test reporter hence we won't
        # see all trace events. :-(  To be improved.
        _(valid_edges?(traces)).must_equal true
      end
      validate_outer_layers(traces, 'rack')

      _(traces[0]['Layer']).must_equal "rack"
      _(traces[0]['Label']).must_equal "entry"
      _(traces[0]['URL']).must_equal "/hello/world"

      _(traces[1]['Layer']).must_equal "rails"
      _(traces[1]['Label']).must_equal "entry"
      _(traces[1]['Controller']).must_equal "HelloController"
      _(traces[1]['Action']).must_equal "world"

      _(traces[2]['Layer']).must_equal "actionview"
      _(traces[2]['Label']).must_equal "entry"

      _(traces[3]['Layer']).must_equal "actionview"
      _(traces[3]['Label']).must_equal "exit"

      _(traces[4]['Layer']).must_equal "rails"
      _(traces[4]['Label']).must_equal "exit"

      _(traces[5]['Layer']).must_equal "rack"
      _(traces[5]['Label']).must_equal "exit"

      # Validate the existence of the response header
      _(r.header.key?('X-Trace')).must_equal true
      _(r.header['X-Trace']).must_equal traces[5]['X-Trace']
    end

    # Different behavior in Rails >= 5.2.0
    # https://github.com/rails/rails/pull/30619
    it "should trace rails postgres db calls" do
      # Skip for JRuby since the java instrumentation
      # handles DB instrumentation for JRuby
      skip if defined?(JRUBY_VERSION) || ENV['DBTYPE'] != 'postgresql'

      uri = URI.parse('http://127.0.0.1:8140/hello/db')
      r = Net::HTTP.get_response(uri)

      traces = get_all_traces

      _(traces.count).must_equal 12
      _(valid_edges?(traces)).must_equal true
      validate_outer_layers(traces, 'rack')

      _(traces[2]['Layer']).must_equal "activerecord"
      _(traces[2]['Label']).must_equal "entry"
      _(traces[2]['Flavor']).must_equal "postgresql"
      _(traces[2]['Query']).must_equal "INSERT INTO \"widgets\" (\"name\", \"description\", \"created_at\", \"updated_at\") VALUES ($?, $?, $?, $?) RETURNING \"id\""
      _(traces[2]['Name']).must_equal Rails.version < '5.2.0' ? "SQL" : "Widget Create"
      _(traces[2].key?('Backtrace')).must_equal false

      _(traces[3]['Layer']).must_equal "activerecord"
      _(traces[3]['Label']).must_equal "exit"

      _(traces[4]['Layer']).must_equal "activerecord"
      _(traces[4]['Label']).must_equal "entry"
      _(traces[4]['Flavor']).must_equal "postgresql"
      # using match because there is a 1 space difference between Rails 5 and Rails 6
      _(traces[4]['Query']).must_match /SELECT\s{1,2}\"widgets\".* FROM \"widgets\" WHERE \"widgets\".\"name\" = \$\? ORDER BY \"widgets\".\"id\" ASC LIMIT \$\?/
      _(traces[4]['Name']).must_equal "Widget Load"
      _(traces[4].key?('Backtrace')).must_equal false
      _(traces[4].key?('QueryArgs')).must_equal false

      _(traces[5]['Layer']).must_equal "activerecord"
      _(traces[5]['Label']).must_equal "exit"

      _(traces[6]['Layer']).must_equal "activerecord"
      _(traces[6]['Label']).must_equal "entry"
      _(traces[6]['Flavor']).must_equal "postgresql"
      _(traces[6]['Query']).must_equal "DELETE FROM \"widgets\" WHERE \"widgets\".\"id\" = $?"
      _(traces[6]['Name']).must_equal Rails.version < '5.2.0' ? "SQL" : "Widget Destroy"
      _(traces[6].key?('Backtrace')).must_equal false
      _(traces[6].key?('QueryArgs')).must_equal false

      _(traces[7]['Layer']).must_equal "activerecord"
      _(traces[7]['Label']).must_equal "exit"

      # Validate the existence of the response header
      _(r.header.key?('X-Trace')).must_equal true
      _(r.header['X-Trace']).must_equal traces[11]['X-Trace']
    end

    # Different behavior in Rails >= 5.2.0
    # https://github.com/rails/rails/pull/30619
    # and
    # https://github.com/rails/rails/commit/213796fb4936dce1da2f0c097a054e1af5c25c2c
    it "should trace rails mysql2 db calls" do
      # Skip for JRuby since the java instrumentation
      # handles DB instrumentation for JRuby
      skip if defined?(JRUBY_VERSION) || ENV['DBTYPE'] != 'mysql2'

      AppOpticsAPM::Config[:sanitize_sql] = false

      uri = URI.parse('http://127.0.0.1:8140/hello/db')
      r = Net::HTTP.get_response(uri)

      traces = get_all_traces
      _(traces.count).must_equal 12
      _(valid_edges?(traces)).must_equal true
      validate_outer_layers(traces, 'rack')

      entry_traces = traces.select { |tr| tr['Label'] == 'entry' }
      _(entry_traces.count).must_equal 6

      exit_traces = traces.select { |tr| tr['Label'] == 'exit' }
      _(exit_traces.count).must_equal 6

      _(entry_traces[2]['Layer']).must_equal "activerecord"
      _(entry_traces[2]['Flavor']).must_equal "mysql"
      entry_traces[2]['Query'].gsub!(/\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d/, 'the_date')
      _(entry_traces[2]['Query']).must_equal "INSERT INTO `widgets` (`name`, `description`, `created_at`, `updated_at`) VALUES ('blah', 'This is an amazing widget.', 'the_date', 'the_date')"
      _(entry_traces[2]['Name']).must_equal Rails.version < '5.2.0' ? "SQL" : "Widget Create"
      _(entry_traces[2].key?('Backtrace')).must_equal false
      _(entry_traces[2].key?('QueryArgs')).must_equal Rails.version < '5.2.0' ? true : false

      _(entry_traces[3]['Layer']).must_equal "activerecord"
      _(entry_traces[3]['Flavor']).must_equal "mysql"
      # using match because there is a 1 space difference between Rails 5 and Rails 6
      _(entry_traces[3]['Query']).must_match /SELECT\s{1,2}`widgets`.* FROM `widgets` WHERE `widgets`.`name` = 'blah' ORDER BY `widgets`.`id` ASC LIMIT 1/
      _(entry_traces[3]['Name']).must_equal "Widget Load"
      _(entry_traces[3].key?('Backtrace')).must_equal false
      _(entry_traces[3].key?('QueryArgs')).must_equal Rails.version < '5.2.0' ? true : false

      # Validate the existence of the response header
      _(r.header.key?('X-Trace')).must_equal true
      _(r.header['X-Trace']).must_equal traces[11]['X-Trace']
    end

    # Different behavior in Rails >= 5.2.0
    # https://github.com/rails/rails/pull/30619
    it "should trace rails mysql2 db calls with sanitize sql" do
      # Skip for JRuby since the java instrumentation
      # handles DB instrumentation for JRuby
      skip if defined?(JRUBY_VERSION) || ENV['DBTYPE'] != 'mysql2'

      AppOpticsAPM::Config[:sanitize_sql] = true

      uri = URI.parse('http://127.0.0.1:8140/hello/db')
      r = Net::HTTP.get_response(uri)

      traces = get_all_traces
      _(traces.count).must_equal 12
      _(valid_edges?(traces)).must_equal true
      validate_outer_layers(traces, 'rack')

      entry_traces = traces.select { |tr| tr['Label'] == 'entry' }
      _(entry_traces.count).must_equal 6

      exit_traces = traces.select { |tr| tr['Label'] == 'exit' }
      _(exit_traces.count).must_equal 6

      _(entry_traces[2]['Layer']).must_equal "activerecord"
      _(entry_traces[2]['Flavor']).must_equal "mysql"
      _(entry_traces[2]['Query']).must_equal "INSERT INTO `widgets` (`name`, `description`, `created_at`, `updated_at`) VALUES (?, ?, ?, ?)"
      _(entry_traces[2]['Name']).must_equal Rails.version < '5.2.0' ? "SQL" : "Widget Create"
      _(entry_traces[2].key?('Backtrace')).must_equal false
      _(entry_traces[2].key?('QueryArgs')).must_equal false

      _(entry_traces[3]['Layer']).must_equal "activerecord"
      _(entry_traces[3]['Flavor']).must_equal "mysql"
      _(entry_traces[3]['Query']).must_match /SELECT\s{1,2}`widgets`.* FROM `widgets` WHERE `widgets`.`name` = \? ORDER BY `widgets`.`id` ASC LIMIT \?/
      _(entry_traces[3]['Name']).must_equal "Widget Load"
      _(entry_traces[3].key?('Backtrace')).must_equal false
      _(entry_traces[3].key?('QueryArgs')).must_equal false

      _(entry_traces[4]['Layer']).must_equal "activerecord"
      _(entry_traces[4]['Flavor']).must_equal "mysql"
      _(entry_traces[4]['Query']).must_equal "DELETE FROM `widgets` WHERE `widgets`.`id` = ?"
      _(entry_traces[4]['Name']).must_equal Rails.version < '5.2.0' ? "SQL" : "Widget Destroy"
      _(entry_traces[4].key?('Backtrace')).must_equal false
      _(entry_traces[4].key?('QueryArgs')).must_equal false

      # Validate the existence of the response header
      _(r.header.key?('X-Trace')).must_equal true
      _(r.header['X-Trace']).must_equal traces[11]['X-Trace']
    end



    it "should trace a request to a rails metal stack" do

      uri = URI.parse('http://127.0.0.1:8140/hello/metal')
      r = Net::HTTP.get_response(uri)

      traces = get_all_traces

      _(traces.count).must_equal 4
      unless defined?(JRUBY_VERSION)
        # We don't test this under JRuby because the Java instrumentation
        # for the DB drivers doesn't use our test reporter hence we won't
        # see all trace events. :-(  To be improved.
        _(valid_edges?(traces)).must_equal true
      end
      validate_outer_layers(traces, 'rack')

      _(traces[0]['Layer']).must_equal "rack"
      _(traces[0]['Label']).must_equal "entry"
      _(traces[0]['URL']).must_equal "/hello/metal"

      _(traces[1]['Label']).must_equal "entry"
      _(traces[1]['Controller']).must_equal "FerroController"
      _(traces[1]['Action']).must_equal "world"

      _(traces[2]['Label']).must_equal "exit"

      _(traces[3]['Layer']).must_equal "rack"
      _(traces[3]['Label']).must_equal "exit"

      # Validate the existence of the response header
      _(r.header.key?('X-Trace')).must_equal true
      _(r.header['X-Trace']).must_equal traces[3]['X-Trace']
    end

    it "should collect backtraces when true" do
      AppOpticsAPM::Config[:action_controller][:collect_backtraces] = true

      uri = URI.parse('http://127.0.0.1:8140/hello/world')
      r = Net::HTTP.get_response(uri)

      traces = get_all_traces

      _(traces.count).must_equal 6
      unless defined?(JRUBY_VERSION)
        # We don't test this under JRuby because the Java instrumentation
        # for the DB drivers doesn't use our test reporter hence we won't
        # see all trace events. :-(  To be improved.
        _(valid_edges?(traces)).must_equal true
      end
      validate_outer_layers(traces, 'rack')

      _(traces[0]['Layer']).must_equal "rack"
      _(traces[0]['Label']).must_equal "entry"
      _(traces[0]['URL']).must_equal "/hello/world"

      _(traces[1]['Layer']).must_equal "rails"
      _(traces[1]['Label']).must_equal "entry"
      _(traces[1]['Controller']).must_equal "HelloController"
      _(traces[1]['Action']).must_equal "world"
      _(traces[1].key?('Backtrace')).must_equal true

      _(traces[2]['Layer']).must_equal "actionview"
      _(traces[2]['Label']).must_equal "entry"

      _(traces[3]['Layer']).must_equal "actionview"
      _(traces[3]['Label']).must_equal "exit"

      _(traces[4]['Layer']).must_equal "rails"
      _(traces[4]['Label']).must_equal "exit"

      _(traces[5]['Layer']).must_equal "rack"
      _(traces[5]['Label']).must_equal "exit"

      # Validate the existence of the response header
      _(r.header.key?('X-Trace')).must_equal true
      _(r.header['X-Trace']).must_equal traces[5]['X-Trace']
    end

    it "should NOT collect backtraces when false" do
      AppOpticsAPM::Config[:action_controller][:collect_backtraces] = false

      uri = URI.parse('http://127.0.0.1:8140/hello/world')
      r = Net::HTTP.get_response(uri)

      traces = get_all_traces

      _(traces.count).must_equal 6
      unless defined?(JRUBY_VERSION)
        # We don't test this under JRuby because the Java instrumentation
        # for the DB drivers doesn't use our test reporter hence we won't
        # see all trace events. :-(  To be improved.
        _(valid_edges?(traces)).must_equal true
      end
      validate_outer_layers(traces, 'rack')

      _(traces[0]['Layer']).must_equal "rack"
      _(traces[0]['Label']).must_equal "entry"
      _(traces[0]['URL']).must_equal "/hello/world"

      _(traces[1]['Layer']).must_equal "rails"
      _(traces[1]['Label']).must_equal "entry"
      _(traces[1]['Controller']).must_equal "HelloController"
      _(traces[1]['Action']).must_equal "world"
      _(traces[1].key?('Backtrace')).must_equal false

      _(traces[2]['Layer']).must_equal "actionview"
      _(traces[2]['Label']).must_equal "entry"

      _(traces[3]['Layer']).must_equal "actionview"
      _(traces[3]['Label']).must_equal "exit"

      _(traces[4]['Layer']).must_equal "rails"
      _(traces[4]['Label']).must_equal "exit"

      _(traces[5]['Layer']).must_equal "rack"
      _(traces[5]['Label']).must_equal "exit"

      # Validate the existence of the response header
      _(r.header.key?('X-Trace')).must_equal true
      _(r.header['X-Trace']).must_equal traces[5]['X-Trace']
    end

    it 'should log one exception and create unbroken traces when there is an exception' do
      AppOpticsAPM::Config[:report_rescued_errors] = true
      uri = URI.parse('http://127.0.0.1:8140/hello/error')
      r = Net::HTTP.get_response(uri)

      traces = get_all_traces

      _(traces.select{ |trace| trace['Label'] == 'error' }.count).must_equal 1
      _(traces.select{ |trace| trace['Label'] == 'entry' }.count).must_equal 2
      _(traces.select{ |trace| trace['Label'] == 'exit'  }.count).must_equal 2

      error_trace = traces.find{ |trace| trace['Label'] == 'error' }
      _(error_trace['Spec']).must_equal 'error'
      _(error_trace.key?('ErrorClass')).must_equal true
      _(error_trace.key?('ErrorMsg')).must_equal true
      _(traces.select { |trace| trace['Label'] == 'error' }.count).must_equal 1
    end

    # TODO: figure out how to test this, when does this happen?
    it 'should only log one exception, when it gets raised recursively' do
      skip
    end
  end

  require_relative "rails_shared_tests"
  require_relative "rails_crud_test"
  require_relative 'rails_logger_formatter_test'
end
