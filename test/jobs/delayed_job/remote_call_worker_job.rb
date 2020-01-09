# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

class DJRemoteCallWorkerJob
  @queue = :critical

  def self.perform(*args)
    # Make some random Dalli (memcache) calls and top it
    # off with an call to the background rack webserver.
    @dc = Dalli::Client.new
    @dc.get(rand(10).to_s)

    uri = URI('http://127.0.0.1:8110')
    Net::HTTP.get(uri)

    @dc.get(rand(10).to_s)
    @dc.get(rand(10).to_s)
    @dc.get_multi([:one, :two, :three, :four, :five, :six])
  end
end
