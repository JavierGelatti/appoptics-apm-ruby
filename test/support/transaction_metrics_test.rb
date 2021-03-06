# Copyright (c) 2018 SolarWinds, LLC.
# All rights reserved.

require 'minitest_helper'
require 'mocha/minitest'

describe 'TransactionSettingsTest' do
  before do
    @tracing_mode = AppOpticsAPM::Config[:tracing_mode]
    @sample_rate = AppOpticsAPM::Config[:sample_rate]
    @config_map = AppOpticsAPM::Util.deep_dup(AppOpticsAPM::Config[:transaction_settings])
    @config_url_disabled = AppOpticsAPM::Config[:url_disabled_regexps]
  end

  after do
    AppOpticsAPM::Config[:transaction_settings] = AppOpticsAPM::Util.deep_dup(@config_map)
    AppOpticsAPM::Config[:url_disabled_regexps] = @config_url_disabled
    AppOpticsAPM::Config[:tracing_mode] = @tracing_mode
    AppOpticsAPM::Config[:sample_rate] = @sample_rate
  end

  describe 'metrics' do
    it 'obeys do_metrics false' do
      AppOpticsAPM::TransactionMetrics.expects(:send_metrics).never
      AppOpticsAPM.expects(:transaction_name=).never

      settings = AppOpticsAPM::TransactionSettings.new
      settings.do_sample = false
      settings.do_metrics = false

      yielded = false

      AppOpticsAPM::TransactionMetrics.metrics({}, settings) { yielded = true }
      assert yielded
    end

    it 'obeys do_metrics true' do
      AppOpticsAPM::TransactionMetrics.expects(:send_metrics).returns('name')
      AppOpticsAPM.expects(:transaction_name=).with('name')

      settings = AppOpticsAPM::TransactionSettings.new
      settings.do_sample = true
      settings.do_metrics = true

      yielded = false

      AppOpticsAPM::TransactionMetrics.metrics({}, settings) { yielded = true }
      assert yielded
    end

    it 'sends metrics when there is an error' do
      AppOpticsAPM::TransactionMetrics.expects(:send_metrics).returns('name')
      AppOpticsAPM.expects(:transaction_name=).with('name')

      settings = AppOpticsAPM::TransactionSettings.new
      settings.do_sample = true
      settings.do_metrics = true
      begin
        AppOpticsAPM::TransactionMetrics.metrics({}, settings) { raise StandardError }
      rescue
      end
    end
  end
end
