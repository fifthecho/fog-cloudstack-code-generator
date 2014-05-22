require 'inifile'
require 'cgi'
require 'openssl'
require 'base64'
require 'uri'
require 'net/http'
require 'fog/core'
require 'fog/json'
require 'fileutils'
require 'erb'

def initialize_connection(api_url, api_key, secret_key, use_ssl=nil)
  @api_url    = api_url
  @api_key    = api_key
  @secret_key = secret_key
  @use_ssl    = use_ssl
end

def api_call_to_snakecase(name)
  tempArray = name.split(/([a-z]*)([A-Z]*[a-z]*)?/)
  tempArray.delete_if { |x| x == "" }
  tempString = ""
  for element in tempArray
    case element
      when "ACLList"
        element = "ACL_List"
      when "VMSnapshot"
        element = "VM_Snapshot"
      when "LBStickiness"
        element = "LB_Stickiness"
      when "VMAffinity"
        element = "VM_Affinity"
      when "VPCOfferings"
        element = "VPC_Offerings"
      when "LBHealth"
        element = "LB_Health"
      when "SSHKey"
        element = "SSH_Key"
      when "ACLItem"
        element = "ACL_Item"
      when "ACLLists"
        element = "ACL_Lists"
      when "VMPassword"
        element = "VM_Password"
    end
    tempString += "_" + element
  end
  return tempString[1..-1].downcase
end

def request(params)
  params['response'] = 'json'
  params['apiKey'] = @api_key

  data = params.map{ |k,v| "#{k.to_s}=#{CGI.escape(v.to_s).gsub(/\+|\ /, "%20")}" }.sort.join('&')

  signature = OpenSSL::HMAC.digest 'sha1', @secret_key, data.downcase
  signature = Base64.encode64(signature).chomp
  signature = CGI.escape(signature)

  url = "#{@api_url}?#{data}&signature=#{signature}"
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = @use_ssl
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  request = Net::HTTP::Get.new(uri.request_uri)

  http.request(request)
end

# Currently this uses a CloudMonkey config, I'll move this to a fog config shortly
configpath = ENV['HOME'] + "/.cloudmonkey/config"
cloudmonkeyconfig = IniFile.load(configpath)

cloudstackKey = cloudmonkeyconfig['user']['apikey']
cloudstackSecret = cloudmonkeyconfig['user']['secretkey']
cloudstackURL = cloudmonkeyconfig['server']['protocol'] + "://" + cloudmonkeyconfig['server']['host'] +
    ":" + cloudmonkeyconfig['server']['port'] + cloudmonkeyconfig['server']['path']
ssl = false
if cloudmonkeyconfig['server']['protocol'].downcase == "https"
  ssl = true
end


initialize_connection(cloudstackURL, cloudstackKey, cloudstackSecret, ssl)
requestparams = {command: 'listApis'}
response = request(requestparams)
response = Fog::JSON.decode(response.body)

apis = response['listapisresponse']['api']

# Ensure directory structure for requests

path = 'lib/fog/cloudstack/requests/compute/'
mockpath = 'Mocks/cloudstack/compute/'
FileUtils.mkdir_p(path) unless File.directory?(path)

# Now create the files. This could probably be a part of the loop above, but I'd rather be safe & know directories exist.
apis = response['listapisresponse']['api']
template_file = File.read("class_template.erb")
@snake_requests = []

for api in apis
  @description = api['description']
  @apicall = api['name']
  @apicall_snake = api_call_to_snakecase(api['name'])
  @snake_requests << api_call_to_snakecase(api['name'])
  @params = []
  for param in api['params']
    if param['required'] == true
      @params << param['name']
    end
  end

  # If someone has written a mock, throw that in the request file.
  mockfile = mockpath + @apicall_snake + ".erb"
  if File.file?(mockfile)
    @mock_template = File.new(mockfile, "r")
  else
    @mock_template = nil
  end

  template = ERB.new(template_file)
  filename = path + @apicall_snake + ".rb"
  real_file = File.new(filename, "w+")
  real_file.syswrite(template.result())
  print "Creating " + filename + "\n"
end

#Now we create the compute template to handle all of the requests we've built.
@snake_requests.sort!
ctemplate_file = File.read("compute_template.erb")
ctemplate = ERB.new(ctemplate_file)
ctemplate_out = File.new("lib/fog/cloudstack/compute.rb", "w+")
ctemplate_out.syswrite(ctemplate.result())
print "Creating compute.rb \n"
