#!/usr/bin/env ruby

require 'base64'
require 'json'
require 'net/http'
require 'nokogiri'
require 'open-uri'
require 'optparse'
require 'rexml/document'
require 'securerandom'
require 'time'
require 'uri'

class Radiko

  AUTHKEY_VALUE = "bcd151073c03b352e1ef2fd66c32209da9ca0afa"
 
  def initialize(options)
    @options = options
  end

  def auth1
    uri = URI("https://radiko.jp/v2/api/auth1")
    req = Net::HTTP::Get.new(uri)
    req["X-Radiko-App"] = "pc_html5"
    req["X-Radiko-App-Version"] = "0.0.1"
    req["X-Radiko-Device"] = "pc"
    req["X-Radiko-User"] = "dummy_user"
  
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) {|http| http.request(req)}

    {
      authtoken: res["X-Radiko-AuthToken"],
      keyoffset: res["X-Radiko-KeyOffset"].to_i,
      keylength: res["X-Radiko-KeyLength"].to_i
    }
  end
  
  def auth2(authtoken, keyoffset, keylength)

    partialkey = AUTHKEY_VALUE.byteslice(keyoffset, keylength)
    partialkey_base64 = Base64.strict_encode64(partialkey)

    uri = URI("https://radiko.jp/v2/api/auth2")
    req = Net::HTTP::Get.new(uri)
    req["X-Radiko-Device"] = "pc"
    req["X-Radiko-User"] = "dummy_user"
    req["X-Radiko-AuthToken"] = authtoken
    req["X-Radiko-PartialKey"] = partialkey_base64

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) {|http| http.request(req)}
    if res.code.to_i != 200
      raise "auth2 failed"
    end
  end

  def download(authtoken, station_id, fromtime, totime, output)
    lsid = SecureRandom.hex(16)
  
    playlist_url = "https://radiko.jp/v2/api/ts/playlist.m3u8?station_id=#{station_id}&ft=#{fromtime}00&to=#{totime}00&l=15"
    headers = "-headers 'X-Radiko-Authtoken: #{authtoken}'"
    cmd = %Q(ffmpeg -loglevel quiet #{headers} -i "#{playlist_url}" -vn -c copy -bsf:a aac_adtstoasc "#{output}")
    pp cmd
    # Execute the ffmpeg command
    system(cmd)
  end
  

  def self.to_unixtime(datetime)
    begin
      Time.strptime(datetime, "%Y%m%d%H%M").to_i
    rescue ArgumentError
      return -1
    end
  end

  def self.login(mail, password)
    uri = URI.parse("https://radiko.jp/v4/api/member/login")
    response = Net::HTTP.post_form(uri, { "mail" => mail,"pass" => password })
    login_json = JSON.parse(response.body)

    radiko_session = login_json["radiko_session"]
    areafree = login_json["areafree"]

    return false if radiko_session.nil? || areafree != 1
    radiko_session
  end

  def self.logout(radiko_session)
    uri = URI.parse("https://radiko.jp/v4/api/member/logout")
    Net::HTTP.post_form(uri, { "radiko_session" => radiko_session })
    radiko_session = ""
  end

  def self.finalize(radiko_session)
    logout(radiko_session) unless radiko_session.nil?
  end

  def self.parse_station_and_datetime(url)
    station_id = url.match(%r{^https?://radiko\.jp/[^/]+/([^/]+)/[^/]+/(\d{12})$})&.captures&.first
    fromtime = url.match(%r{^https?://radiko\.jp/[^/]+/([^/]+)/[^/]+/(\d{12})$})&.captures&.last
    [station_id, fromtime]
  end

  def self.to_datetime(timestamp)
    begin
      time = Time.at(timestamp).utc.strftime("%Y%m%d%H%M")
    rescue ArgumentError
      return ""
    end
  end

  def self.parse_options(argv)
    options = {
      station_id: nil,
      fromtime: nil,
      totime: nil,
      duration: nil,
      mail: nil,
      url: nil,
      password: nil,
      output: nil
    }

    opt_parser = OptionParser.new do |opts|
      opts.banner = "Usage: radiko_recorder.rb [options]"

      opts.on("-s", "--station-id ID", "Station ID") {|station_id| options[:station_id] = station_id}
      opts.on("-f", "--fromtime TIME", "Record start datetime"){|fromtime| options[:fromtime] = fromtime}
      opts.on("-t", "--totime TIME", "Record end datetime"){|totime| options[:totime] = totime}
      opts.on("-d", "--duration MINUTES", "Record minutes"){|duration|options[:duration] = duration.to_i}
      opts.on("-m", "--mail MAIL", "Email address for Radiko premium"){|mail|options[:mail] = mail}
      opts.on("-u", "--url URL", "URL of the program"){|url| options[:url] = url}
      opts.on("-p", "--password PASSWORD", "Password for Radiko premium"){|password|options[:password] = password}
      opts.on("-o", "--output FILENAME", "Output file name"){|output|options[:output] = output}
    end

    opt_parser.parse!(argv)
    options
  end

end

options = Radiko.parse_options(ARGV)

if options[:url]
  station_id, fromtime = Radiko.parse_station_and_datetime(options[:url])
  options[:station_id] ||= station_id
  options[:fromtime] ||= fromtime
end

utime_from = Radiko.to_unixtime(options[:fromtime])
utime_to = 0

if options[:totime]
    utime_to = Radiko.to_unixtime(options[:totime])
end
if options[:duration] && options[:totime].nil?
    utime_to = utime_from + (options[:duration] * 60)
    options[:totime] = Radiko.to_datetime(utime_to)
end
if options[:output].nil?
    output = "#{options[:station_id]}_#{options[:fromtime]}_#{options[:totime]}.m4a"
else
    if options[:output] !~ /\.m4a$/
        options[:output] = "#{options[:output]}.m4a"
    end
end

if options[:mail] && options[:password]
    radiko_session = Radiko.login(options[:mail], options[:password])
    if radiko_session.nil?
        puts "Cannot login Radiko premium"
        Radiko.finalize(radiko_session)
        exit 1
    end
end

radiko = Radiko.new(options)
auth1_res = radiko.auth1
radiko.auth2(auth1_res[:authtoken], auth1_res[:keyoffset], auth1_res[:keylength])

output = options[:output] || "#{options[:station_id]}_#{options[:fromtime]}_#{options[:totime]}.m4a"
radiko.download(auth1_res[:authtoken], options[:station_id], options[:fromtime], options[:totime], output)

Radiko.finalize(radiko_session)

