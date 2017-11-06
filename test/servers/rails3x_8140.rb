##
# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

#  This is a Rails stack that launches on a background
#  thread and listens on port 8140.
#
require "rails/all"
require "action_controller/railtie"
require 'rack/handler/puma'
require File.expand_path(File.dirname(__FILE__) + '/../models/widget')

AppOptics.logger.info "[appoptics/info] Starting background utility rails app on localhost:8140."

if ENV['DBTYPE'] == 'mysql2'
  AppOptics::Test.set_mysql2_env
elsif ENV['DBTYPE'] == 'mysql'
  AppOptics::Test.set_mysql_env
else
  AppOptics.logger.warn "Unidentified DBTYPE: #{ENV['DBTYPE']}" unless ENV['DBTYPE'] == "postgresql"
  AppOptics.logger.debug "Defaulting to postgres DB for background Rails server."
  AppOptics::Test.set_postgresql_env
end

ActiveRecord::Base.establish_connection(ENV['DATABASE_URL'])

unless ActiveRecord::Base.connection.table_exists? 'widgets'
  CreateWidgets.migrate(:up)
end

class Rails32MetalStack < Rails::Application
  routes.append do
    get "/hello/world" => "hello#world"
    get "/hello/metal" => "ferro#world"
    get "/hello/db"    => "hello#db"
    get "/hello/servererror" => "hello#servererror"
  end

  config.cache_classes = true
  config.eager_load = false
  config.active_support.deprecation = :stderr
  config.middleware.delete "Rack::Lock"
  config.middleware.delete "ActionDispatch::Flash"
  config.middleware.delete "ActionDispatch::BestStandardsSupport"
  config.secret_token = "498374i49qkuweoiuoqwehisuakshdhksadhaisdy78o34y138974xyqu9rmye8yrpiokeuioqwzyo8uxftoyqiuxrhm3iou1hrzmjk"
  config.secret_key_base = "2048671-96803948"
end

#################################################
#  Controllers
#################################################

class HelloController < ActionController::Base
  def world
    render :text => "Hello world!"
  end

  def db
    # Create a widget
    w1 = Widget.new(:name => 'blah', :description => 'This is an amazing widget.')
    w1.save

    # query for that widget
    w2 = Widget.where(:name => 'blah').first
    w2.delete

    render :text => "Hello database!"
  end

  def servererror
    render :plain => "broken", :status => 500
  end
end

class FerroController < ActionController::Metal
  include AbstractController::Rendering

  def world
    render :text => "Hello world!"
  end

  include AppOpticsMethodProfiling
  profile_method :world, 'world'
end

Rails32MetalStack.initialize!

Thread.new do
  Rack::Handler::Puma.run(Rails32MetalStack.to_app, {:Host => '127.0.0.1', :Port => 8140})
end

sleep(2)
