#!/usr/bin/lua


-- Include libraries
package.path = "../libs/?.lua;./libs/?.lua;" .. package.path

require("uci");
local utl           = require "luci.util";

--Some variables
local result_file   = '/tmp/result.json'
local gw_file       = '/tmp/gw';
local nfs           = require "nixio.fs";

function file_exists(name)                                                          
        local f=io.open(name,"r")                                                   
        if f~=nil then io.close(f) return true else return false end                
end    

function submitReport()

    local j     = require("json");
    local x     = uci.cursor();
    -- Also get the bootcycle and drift --
    local bootcycle = x.get('mesh_status','status','bootcycle');
    
    local gateway = 'none';
    
    --FIXME Artificially set drift to 0--
    local drift = 0;
    
    --[[
    local drift = x.get('mesh_status','status','drift');
    if(drift == nil)then
        drift = 0 --Set default
        x.set('mesh_status', 'status', 'drift', 0);
        x.commit('mesh_status');
    end
    --]]
    
    local c_and_d   = '"bootcycle":"'..bootcycle..'","drift":"'..drift..'"';
    
     -- Netstats
    require("rdNetstats");
    local n         = rdNetstats();
    local n_stats   = '"network_info":'..n:getWifi();
    
    require("rdSystemstats");
    local s         = rdSystemstats();
    local s_stats   = '"system_info":' .. s:getStats();
    
    -- Include Vis info --
    require('rdVis')
    local v 			= rdVis()
    local vis_string 	= "[]"
    local vis_feedback 	= v:getVis()
    if(vis_feedback)then
    vis_string = vis_feedback
    end
    -- END Vis Info --   
    local curl_data =   '{'..n_stats..','..s_stats..','..c_and_d..',"vis":'..vis_string..',"gateway":"'..gateway..'"}';
    
    local f         = nfs.access(gw_file); 
    
    if f then  
        ----Include LAN INFO----
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
               -- if(n == 'network.interface.lan_4')then
               --     local info = conn:call("network.interface.lan_4", "status",{});
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
        curl_data= '{'..n_stats..','..s_stats..','..c_and_d..','..'"lan_info":'..s_lan_info..',"vis":'..vis_string..',"gateway":"'..gateway..'"}';
    end
    
    local x         = uci.cursor();
    local j         = require("json")
    local proto     = x.get("meshdesk", "internet1", "protocol");
    local mode      = x.get("meshdesk", "internet1", "mode");
    local url       = x.get("meshdesk", "internet1", "status_url");
    --13-6-18 Add a cache buster--
    url             = url.."?_dc="..os.time();
   
    local server    = x.get("meshdesk", "internet1", "ip");
    
    require("rdNetwork")
	local n             = rdNetwork();
	local local_ip_v6   = n:getIpV6ForInterface('br-lan');
	if(local_ip_v6)then
	    server      = x.get("meshdesk", "internet1", "ip_6");
	    server      = '['..server..']';
	end
   

    local query     = proto .. "://" .. server .. "/" .. url;
    print(query);
    
    --Initial if not there
	nfs.writefile('/tmp/report_timestamp',os.time()); 
    
    --[[
    local report_timestamp = x.get("mesh_status", "status", "report_timestamp");
    if(report_timestamp == nil)then
         utl.exec("touch /etc/config/mesh_status")
         x.set('mesh_status','status','status')
         x.set('mesh_status', 'status', 'report_timestamp', os.time())
         x.commit('mesh_status')
    end
    --]]

    --Remove old results                                                                                              
    os.remove(result_file)
    
    nfs.writefile('/tmp/curl_data',curl_data);
    
    
    os.execute('curl -k -o '..result_file..' -X POST -H "Content-Type: application/json" -d \''..curl_data..'\' '..query)
    
    --Read the results
    local f=io.open(result_file,"r")
    if(f)then
        result_string = f:read("*all")
        r =j.decode(result_string);
        if(r.success)then
        
            if(r.reboot_flag ~= nil)then
                if(r.reboot_flag == true)then --Only if it is set to true
                    os.execute("reboot");
                end
            end
        
        --[[
            --NOTE 31-5-18 We comment this out to reduce writes through UCI--
            --If there was a drift value; and it is not 0; clear it
            local drift         = x.get('mesh_status','status','drift');
            local record_drift  = x.get('mesh_status','status','record_drift');
            if(tonumber(drift) ~= 0)then
                x.set('mesh_status', 'status', 'drift', 0);
            end
            --Also if the record drift flag was set; clear it
            if(tonumber(record_drift) == 1)then
                x.set('mesh_status', 'status', 'record_drift', '0');
            end           
            x.set('mesh_status', 'status', 'report_timestamp', r.timestamp);
        --]]
        
            for index, value in pairs(r.items) do
                os.execute('touch /etc/MESHdesk/mesh_status/waiting/'..value)    
            end
            --x.commit('mesh_status');
        end
        
    --else
        --There seems to be some problem reaching the server ... we need to record the drift
        --Check the current state of the record_drift flag....
        
        --[[
        --NOTE 31-5-18 We comment this out to reduce writes through UCI--
        local record_drift  = x.get('mesh_status','status','record_drift');
        if(tonumber(record_drift) == 0)then --If it was turned off turn it on
            x.set('mesh_status', 'status', 'record_drift', '1');
            --Set an initial value for the drift and then the amount of drift will be claculated from it
            local initial_uptime = nfs.readfile("/proc/uptime");                          
            initial_uptime = string.gsub(initial_uptime, "%..*","");                        
            x.set('mesh_status', 'status', 'initial_uptime', initial_uptime);
            x.commit('mesh_status');
        end 
        --]]  
                               
    end
end

submitReport()

