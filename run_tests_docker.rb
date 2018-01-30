#!/usr/bin/env ruby

# this runs all the tests on the current code base
# any edits take effect immediately
# test output is logged to log/test_runs.log
# make sure log/ and log/test_runs.log is writeable by docker

# `docker build -f Dockerfile -t ruby_appoptics .`
# (docker-compose will build it too if missing)
#
# `docker-compose up -d`
# or to rebuild ruby_appoptics
# `docker-compose up --build -d`

require 'yaml'
travis = YAML.load_file('.travis.yml')

matrix = []
travis['rvm'].each do |rvm|
  travis['gemfile'].each do |gemfile|
    matrix << { "rvm" => rvm, "gemfile" => gemfile }
  end
end

matrix = matrix - travis['matrix']['exclude']

matrix.each do |args|
  args['rvm'] = '1.9.3-p551' if args['rvm'] =~ /1.9.3/
  `docker-compose run --rm --service-ports ruby_appoptics_apm /code/ruby-appoptics_apm/ruby_setup.sh #{args['rvm']} #{args['gemfile']}`
end

# `docker-compose down --rmi all`
