require( "class" )

-------------------------------------------------------------------------------
-- A class to fetch the configuration for the mesh and return it as a file ----
-------------------------------------------------------------------------------
class "rdConfig"

--Init function for object
function rdConfig:rdConfig()
	require('rdLogger');
	require('rdExternal');
	require('luci.http');
    local uci 	= require("uci")
    

	self.version 	= "1.0.0"
	self.json	    = require("json")
	self.logger	    = rdLogger()
	self.external	= rdExternal()
	self.debug	    = true
    self.new_file   = ''
    self.old_file   = ''
    self.x		    = uci.cursor()

    self.ping_counts    = 3
    self.ok_ping_count  = 2
    self.retry_count    = 5
    self.current_try    = 0

    --Determine the Files to use--
	self.new_file = self.x.get('meshdesk', 'settings','config_file');
    self.old_file = self.x.get('meshdesk', 'settings','previous_config_file');
    self.protocol = self.x.get('meshdesk', 'internet1','protocol');
    
    --Settings For Config Captive Portal
    self.fs         = require('nixio.fs');
    self.util       = require('luci.util');
    self.sys        = require('luci.sys');
    self.f_captive_config = '/etc/MESHdesk/configs/captive_config.json';
 
end
        
function rdConfig:getVersion()
	return self.version
end

function rdConfig:log(m,p)
	if(self.debug)then
		self.logger:log(m,p)
	end
end

function rdConfig:pingTest(server)
	local handle = io.popen('ping -q -c ' .. self.ping_counts .. ' ' .. server .. ' 2>&1')
	local result = handle:read("*a")                          
	handle:close()     
	result = string.gsub(result, "[\r\n]+$", "")
	if(string.find(result," unreachable"))then --If the network is down
		return false
	end
	      
	result = string.gsub(result, "^.*transmitted,", "")       
	result = string.gsub(result, "packets.*$", "")            
	result = tonumber(result)                          
	if(result >= self.ok_ping_count)then  
		return true
	else
		return false
	end
end


--For the dynamic gateway internal testing
function rdConfig:httpTest(server,http_override)

        http_override = http_override or false --default value
      
        local proto  = self.protocol;
        if(http_override)then
            proto = 'http';
        end

        local url    = '/check_internet.txt'.."?_dc="..os.time();
        local handle = io.popen('curl --connect-timeout 10 -k -o /tmp/check_internet.txt  '..proto..'://' .. server .. url..' 2>&1')
        local result = handle:read("*a")
        handle:close()
        result = string.gsub(result, "[\r\n]", " ")
        self:log('Server Check Result: ' .. result)
        --if(string.find(result," error: "))then --If the network is down
        if((string.find(result,"rror"))or(string.find(result,'Failed to'))or(string.find(result,'timed out')))then --If the network is down
                return false
        else
                return true
        end
end

function rdConfig:fetchSettings(url,device_id,gateway,name,token_key)

	gateway = gateway or false
	if(gateway)then
		gw = "true"
	else
		gw = "false"
	end

	if(self:_file_exists(self.new_file))then
        self:log('Move '..self.new_file.." to "..self.old_file)
		os.execute("mv " .. self.new_file .. " " .. self.old_file)
	end

	local q_s       = {}
	q_s['mac']      = device_id;
	q_s['gateway']  = gw;
	q_s['token_key']= token_key;
	q_s['name']     = name;
	
	--Add fw version to know how to adapt the back-end
	q_s['version'] = '19-5';
		
	q_s['_dc']      = os.time();
	
	--If there is a VLAN setting defined we should use it
	local use_vlan = self.x.get('meshdesk', 'lan', 'use_vlan');
	if(use_vlan == '1')then
	    local vlan_number = self.x.get('meshdesk','lan', 'vlan_number');
	    q_s['vlan_number'] = vlan_number;
	end
	
	local enc_string = luci.http.build_querystring(q_s);
	enc_string       = self:_urlencode(enc_string);
	self:log('QS '..enc_string..'END')
	url = url..enc_string;
	self:log('URL is '..url..'END')
	
      	local retval = os.execute("curl -k -o '" .. self.new_file .."' '" .. url .."'")
      	self:log("The return value of curl is "..retval)
      	if(retval ~= 0)then
      		self:log("Problem executing command to fetch config")
      		return false   
      	end
	if(self:_file_exists(self.new_file))then
        self:log("Got new config file "..self.new_file)
        if(self:_file_size(self.new_file) == 0)then
            self:log("File size of zero - not cool")
            return false
        else
            return true
        end
	else
        self:log("Failed to get latest config file")
		return false
	end
end

function rdConfig:prepCaptiveConfig(dns_works,wifi_flag)

    local wifi_flag = wifi_flag or false;

    --First we need to get some values that we will use to replace values in the file
    local id_if         = self.x.get('meshdesk','settings','id_if');
    local id            = self:getMac(id_if);
    local protocol      = self.x.get('meshdesk','internet1','protocol');
    local ip            = self.x.get('meshdesk','internet1','ip');
    local dns           = self.x.get('meshdesk','internet1','dns');
    local hardware      = self.x.get('meshdesk','settings','hardware');
    
    local cp_config     = self.f_captive_config;
    local strCpConfig   = self.fs.readfile(cp_config);
    local tblCpConfig   = self.json.decode(strCpConfig);
    
    local config_ssid   = 'two';
    
    local c_int         = 'web_by_wifi';
    local c_disabled    = '1'; --By default we disable the web-by-wifi
    if(wifi_flag)then
        c_disabled = '0';   
    end
    
    if(tblCpConfig.config_settings ~= nil)then
        --Wireless adjustments--
        if(tblCpConfig.config_settings.wireless ~= nil)then
            for k,v in pairs(tblCpConfig.config_settings.wireless) do 
                for key,val in pairs(v)do
                    --Do the Channel adjustment if needed
                    if(key == 'wifi-device')then
                        --We set the channel only if wifi_flag is set...
                        if(wifi_flag)then
                            local connInfo       = self:getWiFiInfo(); -- Get the web-by-wifi connection info it will have .channel and .hwmode 
                            --also .success => true / false to indicate if we should go ahead
                            local currChannel   = tblCpConfig.config_settings.wireless[k].options.channel;
                            local currMode      = tblCpConfig.config_settings.wireless[k].options.hwmode;
                            if(connInfo.success)then
                                if(connInfo.hwmode == currMode)then --Only if the mode (freq band) is the same e.g. 11g or 11a
                                    if(connInfo.channel ~= currChannel)then
                                        tblCpConfig.config_settings.wireless[k].options.channel = connInfo.channel;
                                    end
                                end
                            end
                        end
                    end
                    
                    --Write out the SSID
                    if(key == 'wifi-iface')then
                        if(val == config_ssid)then
                            tblCpConfig.config_settings.wireless[k].options.ssid = "CONFIG #"..id;
                        end
                    
                        --Endable the client interface
                        if(val == c_int)then
                            local currDisabled = tblCpConfig.config_settings.wireless[k].options.disabled;
                            if(currDisabled ~= c_disabled)then
                                tblCpConfig.config_settings.wireless[k].options.disabled = c_disabled;
                            end
                        end
                    end
                end
            end
        end
        
        --Network adjustments--
        if(tblCpConfig.config_settings.network ~= nil)then
            for k,v in pairs(tblCpConfig.config_settings.network) do
                for key,val in pairs(v)do
                    --Do the Channel adjustment if needed
                    if(key == 'interface')then
                        if(val == 'lan')then
                            if(wifi_flag)then
                                tblCpConfig.config_settings.network[k].options.proto = 'static';
                            else
                                tblCpConfig.config_settings.network[k].options.proto = 'dhcp';
                            end
                        end
                    end
                end
            end    
        end

        
        --===Maybe we can do the Captive Portals more correct in future===--
        tblCpConfig.config_settings.captive_portals[1].radius_1 = ip;
        tblCpConfig.config_settings.captive_portals[1].coova_optional = 'ssid '..id.."\n"..'vlan '..hardware.."\n";
        --Make it more robust to fallback to IP if DNS is not working 
        if(dns_works == true)then
            self:log('*** DNS WORKS ***');
            tblCpConfig.config_settings.captive_portals[1].uam_url = protocol..'://'..dns..'/conf_dev/index.html';    
        else
            self:log('*** DNS NOT WORKING ***');
            tblCpConfig.config_settings.captive_portals[1].uam_url = protocol..'://'..ip..'/conf_dev/index.html';
        end
        local strNewCpConf = self.json.encode(tblCpConfig);
        self.fs.writefile(cp_config,strNewCpConf);

    end
end


function rdConfig:checkCaptiveWebByWiFi()
    local cp_config     = self.f_captive_config;
    local strCpConfig   = self.fs.readfile(cp_config);
    local tblCpConfig   = self.json.decode(strCpConfig);
    
    if(tblCpConfig.config_settings.wireless[3].options.disabled == '0')then
        return true;
    end
    return false;
    
end

function rdConfig:getMac(interface)
	interface = interface or "eth0"
	io.input("/sys/class/net/" .. interface .. "/address")
	t = io.read("*line")
	dashes, count = string.gsub(t, ":", "-")
	dashes = string.upper(dashes)
	return dashes
end

function rdConfig:getWiFiInfo()
    local connInfo      = {}; 
    connInfo.success    = false;
    local iwinfo        = self.sys.wifi.getiwinfo('wlan0');
    if(iwinfo.channel)then
        connInfo.success = true;
        connInfo.channel = iwinfo.channel;
        local hw_modes   = iwinfo.hwmodelist or { };
        if(hw_modes.g)then
            connInfo.hwmode  = '11g';   
        end     
    end 
    return connInfo;
end

--[[--
========================================================
=== Private functions start here =======================
========================================================
--]]--

function rdConfig._file_exists(self,name)
    local f=io.open(name,"r")                                          
        if f~=nil then io.close(f) return true else return false end       
end

function rdConfig._file_size(self,name)
    local file = io.open(name,"r");
    local size = file:seek("end")    -- get file size
    file:close()        
    return size
end 

function rdConfig._urlencode(self,str)
   if (str) then
      str = string.gsub (str, "%s+", '%%20');--escape the % with a %
   end
   return str    
end 

