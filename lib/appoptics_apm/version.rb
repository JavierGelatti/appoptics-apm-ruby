# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

module AppOpticsAPM
  ##
  # The current version of the gem.  Used mainly by
  # appoptics_apm.gemspec during gem build process
  module Version
    MAJOR = 4 # breaking,
    MINOR = 11 # feature,
    PATCH = 1 # fix => BFF
    OLD_RUBY = 1 # this version runs with ruby 2.2.1

    STRING = [MAJOR, MINOR, PATCH, OLD_RUBY].compact.join('.')
  end
end
