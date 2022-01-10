#!/usr/bin/lua


-- Include libraries
package.path = "../libs/?.lua;./libs/?.lua;" .. package.path

require("uci");

--Some variables
local result_file   = '/tmp/result.json'
local nfs           = require "nixio.fs";

function fetch_config_value(item)
	local handle = io.popen('uci get '..item)
	local result = handle:read("*a")
	handle:close()
	result = string.gsub(result, "[\r\n]+$", "")
	return result
end

function submitReport()
    --We will only send data from Gateway nodes
    local f=io.open('/tmp/gw',"r")
    if f==nil then return end
    
    --File seems to be there go on
    local j     = require("json")
    local x     = uci.cursor();
    
    -- Netstats
    require("rdNetstats")
    local n         = rdNetstats()
    local n_stats   = n:getWifi();
    
    require("rdSystemstats")
    local s         = rdSystemstats()
    local s_stats   = s:getStats()
     
    ----LAN INFO----
    local lan_info      = {};
    local s_lan_info    = '';
    require('ubus'); 
    local conn = ubus.connect();
    if conn then
        local namespaces = conn:objects()
        for i, n in ipairs(namespaces) do
            --LAN IPv4
            if(n == 'network.interface.lan')then
            --Swap the _4 out with .lan for NON Ipv6 - IPv6 still in development
            --if(n == 'network.interface.lan_4')then
                --local info = conn:call("network.interface.lan_4", "status",{});
                local info = conn:call("network.interface.lan", "status",{});
                if(info['ipv4-address'] ~= nil)then
                    if(info['ipv4-address'][1]['address']~= '10.50.50.50')then --The Web-By-WiFi has a fixed IP if 10.50.50.50
                        gateway = 'lan';
                        if(info['up'] == true)then
                            lan_info['lan_proto'] = info['proto'];
                            if(info['ipv4-address'] ~= nil)then
                                lan_info['lan_ip']= info['ipv4-address'][1]['address']
                            end
                            if(info['route'] ~= nil)then
                                lan_info['lan_gw']= info['route'][1]['nexthop']
                            end
                            --Add The MAC
                            require('rdNetwork');
                            local uci   = require("uci");
                            
                            local id_if = x.get('meshdesk','settings','id_if');
                            local id    = rdNetwork:getMac(id_if);
                            lan_info['mac'] = id;                   
                            s_lan_info = j.encode(lan_info);
                        end
                    end
                end
            end
            
            --LAN IPv6
            if(n == 'network.interface.lan_6')then
                local info = conn:call("network.interface.lan_6", "status",{});
                if(info['ipv6-address'] ~= nil)then
                    if(info['ipv6-address'][1]['address']~= '10.50.50.50')then --The Web-By-WiFi has a fixed IP if 10.50.50.50
                        gateway = 'lan';
                        if(info['up'] == true)then
                            lan_info['lan_proto'] = info['proto'];
                            if(info['ipv6-address'] ~= nil)then
                                lan_info['lan_ip']= info['ipv6-address'][1]['address']
                            end
                            if(info['route'] ~= nil)then
                                lan_info['lan_gw']= info['route'][1]['nexthop']
                            end
                            --Add The MAC
                            require('rdNetwork');
                            local uci   = require("uci");
                            
                            local id_if = x.get('meshdesk','settings','id_if');
                            local id    = rdNetwork:getMac(id_if);
                            lan_info['mac'] = id;                   
                            s_lan_info = j.encode(lan_info);
                        end
                    end
                end
            end
            
            
            --Web-By-Wifi
            if(n == 'network.interface.web_by_wifi')then
                local info = conn:call("network.interface.web_by_wifi", "status",{});
                gateway = 'wifi';
                if(info['up'] == true)then
                    lan_info['lan_proto'] = info['proto'];
                    if(info['ipv4-address'] ~= nil)then
                        lan_info['lan_ip']= info['ipv4-address'][1]['address']
                    end
                    if(info['route'] ~= nil)then
                        lan_info['lan_gw']= info['route'][1]['nexthop']
                    end
                    --Add The MAC
                    require('rdNetwork');
                    local uci   = require("uci");    
                    local id_if = x.get('meshdesk','settings','id_if');
                    local id    = rdNetwork:getMac(id_if);
                    lan_info['mac'] = id;                   
                    s_lan_info = j.encode(lan_info);
                end
            end   
        end
    end
    --END LAN INFO--
	
    local curl_data = '{"network_info":'..n_stats..',"system_info":'..s_stats..',"lan_info":'..s_lan_info..',"gateway":"'..gateway..'"}';
	--print(curl_data);

    local proto 	= fetch_config_value('meshdesk.internet1.protocol')
    local mode      = fetch_config_value('meshdesk.settings.mode')
    local url       = fetch_config_value('meshdesk.internet1.status_url')
    
    if(mode == 'ap')then
        url         = fetch_config_value('meshdesk.internet1.ap_status_url')
    end
    
    --13-6-18 Add a cache buster--
    url             = url.."?_dc="..os.time();
    
    local server    = fetch_config_value('meshdesk.internet1.ip');
    
    require("rdNetwork")
	local n             = rdNetwork();
	local local_ip_v6   = n:getIpV6ForInterface('br-lan');
	if(local_ip_v6)then
	    server      = x.get("meshdesk", "internet1", "ip_6");
	    server      = '['..server..']';
	end
    
    local query     = proto .. "://" .. server .. "/" .. url
    
    --Initial if not there
	nfs.writefile('/tmp/report_timestamp',os.time());

    --Remove old results                                                                                              
    os.remove(result_file)
    os.execute('curl -k -o '..result_file..' -X POST -H "Content-Type: application/json" -d \''..curl_data..'\' '..query)
    
    --Read the results
    local f=io.open(result_file,"r")
    if(f)then
        result_string = f:read("*all")
        r =j.decode(result_string)
        if(r.success)then
        
            if(r.reboot_flag ~= nil)then
                if(r.reboot_flag == true)then --Only if it is set to true
                    os.execute("reboot");
                end
            end
        
			for index, value in pairs(r.items) do
                os.execute('touch /etc/MESHdesk/mesh_status/waiting/'..value)    
            end
            
        end
    end
end

submitReport()

