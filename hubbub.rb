helpers do
  # verify subscribers callback
  # TODO: use it in /hub/subscribe
  def do_verify(url, data)
    return false unless url and data
    begin
      challenge = gen_id
      query = { 'hub.mode' => data[:mode], 
                'hub.topic' => data[:url],
                'hub.challenge' => challenge,
                'hub.verify_token' => data[:vtoken]}
      MyTimer.timeout(5) do
         res = HTTPClient.get_content(url, query)
         return false unless res and res == challenge
      end
    rescue
      return false
    end  
    return true
  end
end

# Publishers registering new topics here
get '/hub/publish' do
  erb :publish
end

# Publishers pinging this URL, when there is new content
post '/hub/publish' do
  unless params['hub.mode'] and params['hub.url'] and params['hub.mode'] == 'publish'
    throw :halt, [400, "Bad request: Expected 'hub.mode=publish' and 'hub.url'"]
  end 
  throw :halt, [400, "Bad request: Empty 'hub.url' parameter"] if params['hub.url'].empty?
  begin 
    url = [params['hub.url']].pack("m*").strip
    channel = DB[:channels].filter(:topic => url)
    if channel.first
      channel.update(:updated => Time.now)
      id = channel.first[:id]
    else  
      id = gen_id
      DB[:channels] << { :name => id, :topic => url, :created => Time.now, 
                         :type => 'pubsubhubbub', :secret => 'change_me' }
    end 
    { :id => id.to_s }.to_json 
  rescue Exception => e
    throw :halt, [404, e.to_s]
  end  
  status 204
  return "204 No Content"
end

# Subscribe to PubSubHubbub
get '/hub/subscribe' do
  erb :subscribe
end

post '/hub/subscribe' do
  mode     = params['hub.mode']
  callback = params['hub.callback']
  topic    = params['hub.topic']
  verify   = params['hub.verify']
  vtoken   = params['hub.verify_token']
  unless mode and callback and topic and verify
    throw :halt, [400, "Bad request: Expected 'hub.mode', 'hub.callback', 'hub.topic', and 'hub.verify'"]
  end
  throw :halt, [400, "Bad request: Empty 'hub.callback' or 'hub.topic'"]  if callback.empty? or topic.empty?
  throw :halt, [400, "Bad request: Unrecognized mode"] unless ['subscribe', 'unsubscribe'].include?(mode)
  
  # For now, only using the first preference of verify mode 
  verify = verify.split(',').first 
  throw :halt, [400, "Bad request: Unrecognized verification mode"] unless ['sync', 'async'].include?(verify)
  begin
    channel = DB[:channels].filter(:topic => [topic].pack("m*").strip)
    throw :halt, [404, "Not Found"] unless channel.first
    state = (verify == 'async') ? 1 : 0
    data = { :mode => mode, :verify => verify, :vtoken => vtoken, :url => topic }
    if verify == 'sync'
      raise "Verification failed"  unless do_verify(callback, data)
      state = 0
    end
    # TODO: subscribe/unsubscribe (DB manipulations)
    throw :halt, [202, "202 Scheduled for verification"] if verify == 'async'
  rescue
    throw :halt, [409, "Subscription verification failed"]
  end
  status 204
  "204 No Content"
end

# PubSubHubBub subscribers check - check the topic and secret and
# return hub.challenge or channel name for superfeedr
get '/hub/callback/:id' do
  channel = DB[:channels].filter(:name => params[:id]).first
  throw :halt, [404, "Not found"]  unless channel
  return channel[:name] if channel[:type] == 'superfeedr'
  url = [params['hub.topic']].pack("m*").strip
  unless request['hub.verify_token'] == channel[:secret] and url == channel[:topic]
    throw :halt, [404, "Not found"]
  end
  request['hub.challenge']
end  

post '/hub/callback/:id' do
  channel = DB[:channels].filter(:name => params[:id]).first
  throw :halt, [404, "Not found"] unless channel
  postman(channel[:id], atom_parse(request.body.string)).to_json
end 
