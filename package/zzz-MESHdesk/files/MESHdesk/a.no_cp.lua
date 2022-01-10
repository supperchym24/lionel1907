#!/usr/bin/lua

--[[--

Startup script to get the config of the device from the config server

--]]--

-- Include libraries
package.path = "libs/?.lua;" .. package.path
require "socket"
require("rdLogger")
--External programs object
require("rdExternal")
--Configure object
require("rdConfig")
--Alfred object
require("rdAlfred")

--uci object
require('uci')
uci_cursor = uci.cursor()

local nixio   = require("nixio");
local l_uci   = require("luci.model.uci");

function fetch_config_value(item)
	local handle = io.popen('uci get '..item)
	local result = handle:read("*a")
	handle:close()
	result = string.gsub(result, "[\r\n]+$", "")
	return result
end


-- Some constants -- Replace later with uci values
previous_config_file 	= fetch_config_value('meshdesk.settings.previous_config_file')
sleep_time		        = 1
config_file		        = fetch_config_value('meshdesk.settings.config_file')
gw_dhcp_timeout		    = tonumber(fetch_config_value('meshdesk.settings.gw_dhcp_timeout'))
wifi_timeout		    = tonumber(fetch_config_value('meshdesk.settings.wifi_timeout'))
debug			        = true
l			            = rdLogger()
ext 			        = rdExternal()
alfred                  = rdAlfred()
config_server           = fetch_config_value('meshdesk.settings.config_server')

--Reboot on SOS
sos_reboot_timeout		= 30

--Rerun Checks on Failure
config_success          = false
config_repeat_counter   = 500

--======================================
---- Some general functions ------------
--======================================

function log(m,p)
	if(debug)then
		l:log(m,p)
	end
end

function sleep(sec)
    socket.select(nil, nil, sec)
end

function file_exists(name)                                                          
        local f=io.open(name,"r")                                                   
        if f~=nil then io.close(f) return true else return false end                
end                                                                                 
                                                                                                    
function file_not_exists(name)                                                      
	local f=io.open(name,"r")                                                   
        if f~=nil then io.close(f) return false else return true end                        
end

-- Read file; return contents              
function readAll(file)                     
	local f = io.open(file, "rb")      
        local content = f:read("*all")     
        f:close()                          
        return content                     
end

function getMac(interface)
	interface = interface or "eth0"
	io.input("/sys/class/net/" .. interface .. "/address")
	t = io.read("*line")
	dashes, count = string.gsub(t, ":", "-")
	dashes = string.upper(dashes)
	return dashes
end

--==============================
-- End Some general functions --
--==============================


--======================================
---- Some test functions ---------------
--======================================
function did_lan_came_up()
	local lan_up_file=fetch_config_value('meshdesk.settings.lan_up_file')
	if(file_exists(lan_up_file))then
		return true		
	else
		return false
	end
end

function did_wifi_came_up()
	local wifi_up_file=fetch_config_value('meshdesk.settings.wifi_up_file')
	if(file_exists(wifi_up_file))then
		return true		
	else
		return false
	end
end

function reboot_on_sos()
    --When the device is in SOS mode we might as well just reboot it again to keep on trying
	local start_time	= os.time()
	local loop			= true

	--**********LOOP**********
	while (loop) do
		sleep(sleep_time)
		local time_diff = os.difftime(os.time(), start_time)
		if(time_diff >= sos_reboot_timeout)then
			os.execute("reboot")
			break
		end
	end
	--**********LOOP END**********
end


--==============================
-- End Some test functions -----
--==============================

--===========================
-- Firmware Configuration ---
--===========================
function do_fw_config()

    local skip_check = fetch_config_value('meshdesk.settings.skip_fw_config');
    if(skip_check == '1')then
        return;
    end

    --kill potential existing batman_neighbours.lua instance
	ext:stop('batman_neighbours.lua')

	-- Break down the gateways --
	require("rdGateway")
	local a = rdGateway()
	a:disable()
	a:restartServices()

    require("rdNetwork")

	-- LAN we flash "I"
	log("Do Firmware configuration - if server running")
	os.execute("/etc/MESHdesk/main_led.lua start config")
    --Set meshdesk.settings.id_if (typically eth0) to a known IP Address
    local network = rdNetwork()
	network:frmwrStart()
    sleep(4) --just so it eases out
    
    --See if we can at least ping the machine running the utility
    local conf  = rdConfig();
    if(conf:pingTest(config_server))then
        require("rdFirmwareConfig")
        local f = rdFirmwareConfig()
        f:runConfig()
    end
end

--=====================
-- Start-up function --
--=====================
function wait_for_lan()
	                 
	--kill potential existing batman_neighbours.lua instance
	ext:stop('batman_neighbours.lua')
	ext:stop('heartbeat.lua')
	ext:stop('actions_checker')	
	os.execute("/etc/init.d/alfred stop")

	-- LAN we flash "A"
	log("Starting LAN wait")
	os.execute("/etc/MESHdesk/main_led.lua start lan")
	local start_time	= os.time()
	local loop			= true
	local lan_is_up		= false
	local wait_lan_counter = gw_dhcp_timeout
	
	--Do a clean start with the wireless--
	require("rdWireless")
	
	local wireless = rdWireless()
	wireless:newWireless()
	--After this we can fetch a count of the radios
	radio_count = wireless:getRadioCount()
	
    require("rdNetwork")
	
	local network = rdNetwork()
	network:dhcpStart()
	
	--**********LOOP**********
	while (wait_lan_counter > 0) do
		sleep(sleep_time)
		-- If the lan came up we will try to get the settings
		if(did_lan_came_up())then
			lan_is_up 	= true
			break	--no need to continiue
		end
		wait_lan_counter = wait_lan_counter - 1
	end
	--*********LOOP END*********
	
	--See what happended and how we should handle it
	if(lan_is_up)then
		--os.execute("/etc/MESHdesk/main_led.lua start b")
		log("sleep at least 10 seconds to make sure it got a DHCP addy")
		-- sleep at least 10 seconds to make sure it got a DHCP addy
		sleep(10)
		try_settings_through_lan()
	else
		try_wifi()		
	end	
end

function get_ip_for_hostname()
    local server        = l_uci.cursor():get('meshdesk','internet1','ip');
    local h_name        = l_uci.cursor():get('meshdesk','internet1','dns');
    local server_6      = l_uci.cursor():get('meshdesk','internet1','ip_6');
    
    require("rdNetwork")
	local n             = rdNetwork();
	local local_ip_v6   = n:getIpV6ForInterface('br-lan');
	local v6_enabled    = false;

	if(local_ip_v6)then
	    v6_enabled = true;
	end
        
    local return_table  = {fallback=true, ip=server, hostname=h_name,ip_6=server_6, v6_enabled=v6_enabled};--For now we're not updating it 
    local a             = nixio.getaddrinfo(h_name);
    if(a)then
        local ip = a[1]['address'];
        if(ip ~= server)then
            --Update the thing
            l_uci.cursor():set('meshdesk','internet1','ip', ip);
	        l_uci.cursor():save('meshdesk');
	        l_uci.cursor():commit('meshdesk'); 
        end
        return_table.ip = ip;
        return_table.fallback = false;     
    end
    return return_table;
end


function try_settings_through_lan() 
	log("LAN up now try fetch the settings")
	print("LAN up now try fetch the settings")
	
	-- See if we can ping it
	local c 				= rdConfig()
	local lan_config_fail	=true 
	local loop	= true
	local start_time	    = os.time()
	--31/5/2019 Adding a hostname to ip lookup takes more time so we shorten this to 20
	local setting_lan_counter = 20;
	
	
	--Prime the hostmane / ip table
	local server_tbl        = get_ip_for_hostname();
	local server            = server_tbl.ip;
	
	if(server_tbl.v6_enabled)then
	    server            = server_tbl.ip_6;
	end
	
	--**********LOOP**********
    while (setting_lan_counter > 0) do
    
		sleep(sleep_time);
		
		if(server_tbl.fallback)then
		    --Try again
		    log("Could not resolve "..server_tbl.hostname.." trying again");
		    server_tbl   = get_ip_for_hostname();
		    server       = server_tbl.ip;
		    if(server_tbl.v6_enabled)then
	            server  = server_tbl.ip_6;        
	        end
	    else
	        log(server_tbl.hostname.." resolved to "..server_tbl.ip.." using DNS");
		end
		
		if(c:pingTest(server))then
	        	print("Ping os server was OK try to fetch the settings")
	        	log("Ping os server was OK try to fetch the settings")
    			--local id	= "A8-40-41-13-60-E3"
    			local local_node_name   = fetch_config_value('meshdesk.settings.local_node_name');
	        	local token_key         = fetch_config_value('meshdesk.settings.token_key');
	        
    			local id_if     = fetch_config_value('meshdesk.settings.id_if')
	        	local id		= getMac(id_if)
	        	local proto 	= fetch_config_value('meshdesk.internet1.protocol')
	        	local url   	= fetch_config_value('meshdesk.internet1.url')
	        	local query     = proto .. "://" .. server .. "/" .. url
	        	
	        	if(server_tbl.v6_enabled)then
	                query     = proto .. "://[" .. server .. "]/" .. url         
	            end
	        	
	        	print("Query url is " .. query )
	        	if(c:fetchSettings(query,id,true,local_node_name,token_key))then
		        	print("Cool -> got settings through LAN")
		        	lan_config_fail=false
		        	break --We can exit the loop
	        	end
        else
	        log("Ping Controller Failed through LAN");
        end
        
        --31/5/2019
        --Add a check to confirm the lan is STILL up (if the node WAS a GW node and moved to NON-GW it will come up and go away)
        if(did_lan_came_up())then
            setting_lan_counter = setting_lan_counter - 1;
        else
            setting_lan_counter = 0;  --Zero if to introduce a FAIL      
        end	
    end
    --*** END LOOP ***

	if(lan_config_fail)then	
		log("Could not fetch settings through LAN")
		try_wifi()
	else
		configure_device(config_file)
	end
end

function try_wifi()
	local got_new_config = false
	--Here we will go through each of the radios
	log("Try to fetch the settings through the WiFi radios")
	log("Device has "..radio_count.." radios")
	local radio = 0 --first radio
	
	if(fetch_config_value('meshdesk.settings.skip_radio_0') == '1')then
	    radio = 1
	end 
	
	while(radio < radio_count) do
		log("Try to get settings using radio "..radio);
		--Bring up the Wifi
		local wifi_is_up = wait_for_wifi(radio)
		if(wifi_is_up)then
			local got_settings = try_settings_through_wifi()
			if(got_settings)then
				--flash D--
				got_new_config = true
				configure_device(config_file)
				break -- We already got the new config and can break our search of next radio
			end
		end
		--Try next radio
		radio = radio+1
	end

	if(got_new_config == false)then
		print("Settings could not be fetched through WiFi see if older ones exists")
		log("Settings could not be fetched through WiFi see if older ones exists")
		check_for_previous_settings()
	end
end

function wait_for_wifi(radio_number)

	if(radio_number == nil)then
		radio_number = 0
	end

	-- WiFi we flash "C"
	log("Try settings through WiFi network")
	if(radio_number == 0)then
	    os.execute("/etc/MESHdesk/main_led.lua start rone")
    end
	
	if(radio_number == 1)then
	    os.execute("/etc/MESHdesk/main_led.lua start rtwo")
    end
	
	-- Start the WiF interface
	require("rdWireless")
	local w = rdWireless()
                             
	w:connectClient(radio_number)
	
	local start_time	= os.time()
	local loop			= true
	local wifi_is_up	= false --default
	local wait_wifi_counter = wifi_timeout
	
	while (wait_wifi_counter > 0) do
		sleep(sleep_time);
		-- If the wifi came up we will try to get the settings
		if(did_wifi_came_up())then
			wifi_is_up = true
			break
		end	
		wait_wifi_counter = wait_wifi_counter - 1
	end

	--See what happended and how we should handle it
	if(wifi_is_up)then
		-- sleep at least 10 seconds to make sure it got a DHCP addy
		sleep(10)
		print("Wifi is up try to get the settings through WiFi")
		log("Wifi is up try to get the settings through WiFi")
	end
	return wifi_is_up
end

function try_settings_through_wifi()
	print("Wifi up now try fetch the settings")
	log("Wifi up now try fetch the settings")
	
	--======
	local mode              = fetch_config_value('meshdesk.settings.mode');
	local local_mode        = false;
	local local_node_name   = fetch_config_value('meshdesk.settings.local_node_name');
	local token_key         = fetch_config_value('meshdesk.settings.token_key');
	if(mode == 'local')then
	    local_mode      = fetch_config_value('meshdesk.settings.local_mode');    
	end
	--http://10.1.2.3/cgi-bin/luci/meshdesk/local/settings
	--======
	-- See if we can ping it
	
	 --Prime the hostmane / ip table
	local server_tbl    = get_ip_for_hostname();
	local server        = server_tbl.ip;
	
	if(server_tbl.fallback)then
	    log("Could not resolve "..server_tbl.hostname.." trying again");
    else
        log(server_tbl.hostname.." resolved to "..server_tbl.ip.." using DNS");
	end	
	
	if(local_mode == 'standard')then
	    server = '10.5.5.1';
	end
	
	local c 			= rdConfig()
	local got_settings	= false;
	                                       
	if(c:pingTest(server))then
		print("Ping os server was OK try to fetch the settings")
		log("Ping os server was OK try to fetch the settings")
--		local id	="A8-40-41-13-60-E3"
        local id_if     = fetch_config_value('meshdesk.settings.id_if')
		local id	    = getMac(id_if)
		local proto 	= fetch_config_value('meshdesk.internet1.protocol')
		local url   	= fetch_config_value('meshdesk.internet1.url')
		local query     = proto .. "://" .. server .. "/" .. url
		
		if(local_mode == 'standard')then
		    query = "http://10.5.5.1/cgi-bin/luci/meshdesk/local/settings";
		end
		
		print("Query url is " .. query )
		if(c:fetchSettings(query,id,false,local_node_name,token_key))then
			print("Funky -> got settings through WIFI")
			got_settings=true
		end
	end
	return got_settings
end

function check_for_previous_settings_removed_on_2018_May_17()
	print("Checking for previous settings")
	if(file_exists(previous_config_file))then
		print("Using previous settings")
		--os.execute("/etc/MESHdesk/main_led.lua start e")
		configure_device(previous_config_file)
	else
		--Nothing we can do but flash an SOS
		os.execute("/etc/MESHdesk/main_led.lua start sos")
		--Try again
		try_controller_modes();
	end
end

function check_for_previous_settings()
        print("Checking for previous settings")
        if(file_exists(previous_config_file))then
                print("Using previous settings")
                --os.execute("/etc/MESHdesk/main_led.lua start e")
                configure_device(previous_config_file)
		os.execute("lua /etc/MESHdesk/bailout.lua &")
        end
end


function configure_device(config)

    configure_mode();
    
	print("Configuring device according to " .. config)
	
	local contents        = readAll(config) 
	local json            = require("json")           
	local o               = json.decode(contents)  

    if(o.success == false)then --If the device was not yet assigned we need to give feedback about it
	    print("The server returned an error");
	    log("The server returned an error");

        --There might be an error message
	    if(o.error ~= nil)then
	        print(o.error);
	        log(o.error);
	        --try_controller_modes();
	        return;
	    end

        --There might also be an option to point the device to another server for its settings
        if(o.new_server ~= nil)then
            log("Setting new config server to " .. o.new_server);
            uci_cursor.set('meshdesk','internet1','dns',o.new_server);
            uci_cursor.set('meshdesk','internet1','protocol',o.new_server_protocol); --We also add the protocol
            uci_cursor.commit('meshdesk');
            reboot_on_sos();
	        return;  
        end
        
        --Also an option to change the mode
        if((o.new_mode ~= nil)and(o.new_mode ~= 'mesh'))then
            log("Changing Mode to " .. o.new_mode);
            uci_cursor.set('meshdesk','settings','mode',o.new_mode);
            uci_cursor.commit('meshdesk');
            reboot_on_sos();
	        return;  
        end

    end


	-- Do we have any batman_adv settings? --
	if(o.config_settings.batman_adv ~= nil)then   
		--print("Doing Batman-adv")
        require("rdBatman")
	    local batman = rdBatman()
	    batman:configureFromTable(o.config_settings.batman_adv)             
	end 


	-- Is this perhaps a gateway node? --
	if(o.config_settings.gateways ~= nil)then
		-- Set up the gateways --	
		require("rdGateway")
		local a = rdGateway()
		a:enable(o.config_settings) --We include everything if we want to use it in future
		
	else
		-- Break down the gateways --
		require("rdGateway")
		local a = rdGateway()
		a:disable()
	end

	-- Do we have some network settings?       
	if(o.config_settings.network ~= nil)then   
		print("Doing network")
        require("rdNetwork")
	    local network = rdNetwork()
	    network:configureFromTable(o.config_settings.network)             
	end 
	
	-- Do we have some wireless settings?      
	if(o.config_settings.wireless ~= nil)then  
		print("Doing wireless")
		require("rdWireless")           
	    local w = rdWireless()    
	    w:configureFromTable(o.config_settings.wireless) 
	end
	  
    os.execute("/etc/init.d/network reload")
    sleep(2)
    os.execute("/sbin/wifi")

	-- Do we have some system settings?
	if(o.config_settings.system ~= nil)then  
		print("Doing system")
		require("rdSystem")           
	    local s = rdSystem()    
	    s:configureFromTable(o.config_settings.system) 
	end
    
    -- Do the LED's we have configured in /etc/config/system
    os.execute("ifconfig bat0 up") 	--On the pico's it goes down
    
	if(o.config_settings.gateways ~= nil)then
		-- Set up the gateways --
		sleep(40); -- Wait for things to stabilize	
		require("rdGateway")
		local a = rdGateway()
		a:restartServices()
        --start alfred in master mode
        alfred:masterEnableAndStart()
    else
        alfred:slaveEnableAndStart()
	end

	--Start the actions checker (on every node)
	ext:startOne('/etc/MESHdesk/actions_checker.lua &','actions_checker.lua')
	--Start heartbeat (on every node)
	ext:startOne('/etc/MESHdesk/heartbeat.lua &','heartbeat.lua')
	
    --os.execute("/etc/init.d/led start")
	log("Ensure mesh0 and/or mesh1 if present is added to bat0")
	os.execute("batctl if add mesh0")
    os.execute("batctl if add mesh1")

    log('Starting Batman neighbour scan')
    ext:startOne('/etc/MESHdesk/batman_neighbours.lua &','batman_neighbours.lua')
    
    --We move it to last since it gave more trouble with 802.11s based transport
    -- Check if there are perhaps some captive portals to set up once everything has been done --
    sleep(5) -- Wait a bit before doing this part else the DHCP not work correct
    if(o.config_settings.captive_portals ~= nil)then
    	print("Doing Captive Portals")
    	require("rdCoovaChilli")
    	local a = rdCoovaChilli()
    	a:createConfigs(o.config_settings.captive_portals)                  
    	a:startPortals()
    	sleep(5)
    	a:setDnsMasq(o.config_settings.captive_portals)
    	
    end
    
    if(o.config_settings.openvpn_bridges ~= nil)then
        print("Doing OpenVPN Bridges")
        require("rdOpenvpn")
	    local v = rdOpenvpn()
        v:configureFromTable(o.config_settings.openvpn_bridges)
        os.execute("/etc/init.d/openvpn start")
    end

    config_success = true;
        
--]]--
end

--=====================
--AP Specifics Here----
--=====================

--===============================
-- AP -> Start-up function for --
--===============================
function ap_wait_for_lan()

    ext:stop('heartbeat.lua')
	ext:stop('actions_checker')	
	os.execute("/etc/init.d/alfred stop")
	                 
	-- LAN we flash "1"
	log("Starting LAN wait")
	--os.execute("/etc/MESHdesk/main_led.lua start one")
	os.execute("/etc/MESHdesk/main_led.lua start lan")
	local start_time	= os.time()
	local loop			= true
	local lan_is_up		= false
	local ap_wait_lan_counter = gw_dhcp_timeout
	
	--Do a clean start with the wireless--
	require("rdWireless")
	
	local wireless = rdWireless()
	wireless:newWireless()
	
    require("rdNetwork")
	
	local network = rdNetwork()
	network:dhcpStart()
	
	--**********LOOP**********
	while (ap_wait_lan_counter > 0) do
		sleep(sleep_time)
		-- If the lan came up we will try to get the settings
		if(did_lan_came_up())then
			lan_is_up 	= true
			break	--no need to continiue
		end
		ap_wait_lan_counter = ap_wait_lan_counter - 1
	end
	--*********LOOP END*********
	
	--See what happended and how we should handle it
	if(lan_is_up)then
		--os.execute("/etc/MESHdesk/main_led.lua start two")
		log("sleep at least 10 seconds to make sure it got a DHCP addy")
		-- sleep at least 10 seconds to make sure it got a DHCP addy
		sleep(10)
		ap_try_settings_through_lan()
	else
		print("LAN did not come up see if older config exists")
		log("LAN did not come up see if older config exists")
		ap_check_for_previous_settings()		
	end	
end


function ap_try_settings_through_lan() 
	log("LAN up now try fetch the settings")
	print("LAN up now try fetch the settings")
	
	-- See if we can ping it
	local c 				= rdConfig()
	local lan_config_fail	=true 	
	local loop      = true 
	local start_time	    = os.time()
	--31/5/2019 Adding a hostname to ip lookup takes more time so we shorten this to 20
	local ap_set_lan_counter = 20;
	
	
	--Prime the hostmane / ip table
	local server_tbl        = get_ip_for_hostname();
	local server            = server_tbl.ip;
	
	if(server_tbl.v6_enabled)then
        server  = server_tbl.ip_6;
    end
		
	--**********LOOP**********
	while (ap_set_lan_counter > 0) do
		
		sleep(sleep_time);
		
		if(server_tbl.fallback)then
		    --Try again
		    log("Could not resolve "..server_tbl.hostname.." trying again");
		    server_tbl  = get_ip_for_hostname();
		    server      = server_tbl.ip;
		    if(server_tbl.v6_enabled)then     
                server  = server_tbl.ip_6;
                log("Detected IPv6 - Trying to reach server on "..server);
            end
	    else
	        log(server_tbl.hostname.." resolved to "..server_tbl.ip.." using DNS");
		end	
		
		if(c:pingTest(server))then
	        	print("Ping os server was OK try to fetch the settings")
	        	log("Ping os server was OK try to fetch the settings")
    			--local id	= "A8-40-41-13-60-E3"
    			local id_if     = fetch_config_value('meshdesk.settings.id_if')
	        	local id		= getMac(id_if)
	        	local proto 	= fetch_config_value('meshdesk.internet1.protocol')
	        	local url   	= fetch_config_value('meshdesk.internet1.ap_url')
	        
	        	local local_node_name   = fetch_config_value('meshdesk.settings.local_node_name');
	        	local token_key         = fetch_config_value('meshdesk.settings.token_key');
	        	local query             = proto .. "://" .. server .. "/" .. url;
	        	
	        	if(server_tbl.v6_enabled)then
	                query     = proto .. "://[" .. server .. "]/" .. url         
	            end
	            
	        	print("Query url is " .. query )
	        	if(c:fetchSettings(query,id,true,local_node_name,token_key))then
		        	print("Funky -> got settings through LAN")
				
		        	lan_config_fail=false
		        	break --We can exit the loop
			else
			
	        	end
       	 	else 
		        log("Ping os server was NOT OK! - Try again")
	        end

		ap_set_lan_counter = ap_set_lan_counter - 1
    end  
    --*** END LOOP **********
        
	if(lan_config_fail)then	
		
		print("Settings could not be fetched through LAN see if older ones exists")
		log("Settings could not be fetched through LAN see if older ones exists")
		ap_check_for_previous_settings()
	else
		--flash D--
		--os.execute("/etc/MESHdesk/main_led.lua start three")
		
		ap_configure_device(config_file)
	end
end

function ap_check_for_previous_settings_removed_on_2018_May_17()
	print("Checking for previous settings")
	if(file_exists(previous_config_file))then
		print("Using previous settings")
		--os.execute("/etc/MESHdesk/main_led.lua start four")
		ap_configure_device(previous_config_file)
	else
		--Nothing we can do but flash an SOS
		os.execute("/etc/MESHdesk/main_led.lua start sos")
		--This will result in a reboot to try again
		try_controller_modes();
	end
end

function ap_check_for_previous_settings()
    print("Checking for previous settings")
    if(file_exists(previous_config_file))then
        print("Using previous settings")
        --os.execute("/etc/MESHdesk/main_led.lua start four")
        ap_configure_device(previous_config_file)
        os.execute("lua /etc/MESHdesk/bailout.lua &")
    end
end

function ap_configure_device(config)

	print("Configuring device according to " .. config)
	log("Configuring device according to " .. config)
	
	local contents        = readAll(config) 

	local json            = require("json")           
	
	local o               = json.decode(contents)

	
	if(o.success == false)then --If the device was not yet assigned we need to give feedback about it
	    print("The server returned an error");
	   

        --There might be an error message
	    if(o.error ~= nil)then
	        print(o.error);
	        log(o.error);
	        --try_controller_modes();
	        return;
	    end

        --There might also be an option to point the device to another server for its settings
        if(o.new_server ~= nil)then
            log("Setting new config server to " .. o.new_server);
            uci_cursor.set('meshdesk','internet1','dns',o.new_server);
            uci_cursor.set('meshdesk','internet1','protocol',o.new_server_protocol); --We also add the protocol
            uci_cursor.commit('meshdesk');
            reboot_on_sos();
	        return;  
        end
        
        --Also an option to change the mode
        if((o.new_mode ~= nil)and(o.new_mode ~= 'ap'))then
            log("Changing Mode to " .. o.new_mode);
            uci_cursor.set('meshdesk','settings','mode',o.new_mode);
            uci_cursor.commit('meshdesk');
            reboot_on_sos();
	        return;  
        end  
    end


	-- Is this perhaps a gateway node? --
	if(o.config_settings.gateways ~= nil)then
		-- Set up the gateways --	
		
		require("rdGateway")
		local a = rdGateway()
		a:setMode('ap')
		a:enable(o.config_settings) --We include everything if we want to use it in future
		
	else
		-- Break down the gateways --
		
		require("rdGateway")
		local a = rdGateway()
		a:setMode('ap')
		a:disable()
	end

	-- Do we have some network settings?       
	if(o.config_settings.network ~= nil)then   
		print("Doing network")
		log("Doing network")
        require("rdNetwork")
	    local network = rdNetwork()
	    network:configureFromTable(o.config_settings.network)             
	end 
	
	-- Do we have some wireless settings?      
	if(o.config_settings.wireless ~= nil)then  
		print("Doing wireless")
		log("Doing wireless")
		require("rdWireless")           
	    local w = rdWireless()    
	    w:configureFromTable(o.config_settings.wireless) 
	end
	  
    os.execute("/etc/init.d/network reload")

	-- Do we have some system settings?
	if(o.config_settings.system ~= nil)then  
		print("Doing system")
		require("rdSystem")           
	    local s = rdSystem()    
	    s:configureFromTable(o.config_settings.system) 
	end

    -- Check if there are perhaps some captive portals to set up once everything has been done --
    sleep(5) -- Wait a bit before doing this part else the DHCP not work correct

    os.execute("/etc/init.d/firewall reload") --Activate the new firewall rules especiallt NAT to LAN

    if(o.config_settings.captive_portals ~= nil)then
    	print("Doing Captive Portals")
    	require("rdCoovaChilli")
    	local a = rdCoovaChilli()
    	a:createConfigs(o.config_settings.captive_portals)                  
    	a:startPortals()
    	sleep(5)
    	a:setDnsMasq(o.config_settings.captive_portals)   		
    end
    
    if(o.config_settings.openvpn_bridges ~= nil)then
        print("Doing OpenVPN Bridges")
        require("rdOpenvpn")
	    local v = rdOpenvpn()
        v:configureFromTable(o.config_settings.openvpn_bridges)
        os.execute("/etc/init.d/openvpn start")
    end
    
    --Start Alfred for the collecting of data (No MESH)
    alfred:masterNoBatmanEnableAndStart()
    --Start the heartbeat to the server
    ext:startOne('/etc/MESHdesk/heartbeat.lua &','heartbeat.lua')
    --Start the actions checker
	ext:startOne('/etc/MESHdesk/actions_checker.lua &','actions_checker.lua')
        
	if(o.config_settings.gateways ~= nil)then
		-- Set up the gateways --
		sleep(40); -- Wait for things to stabilize
			
		require("rdGateway")
		local a = rdGateway()
		a:setMode('ap')
		a:restartServices()   
    end

    config_success = true      
--]]--
end

--=====================
--END AP Specifics ----
--=====================

function prep_leds()
    local hw        = uci_cursor.get('meshdesk','settings','hardware');
    local sled      = uci_cursor.get('meshdesk',hw,'single_led');
    local mled      = uci_cursor.get('meshdesk',hw,'meshed_led');
    local sysled    = uci_cursor.get('meshdesk',hw,'system_led');
    
    if((sled ~= nil)and(mled ~= nil)and(sysled ~= nil))then
        os.execute("echo '0' > '/sys/class/leds/"..sled.."/brightness'");   --Single off
        os.execute("echo '0' > '/sys/class/leds/"..mled.."/brightness'");   --Multiple off
        os.execute("echo '1' > '/sys/class/leds/"..sysled.."/brightness'"); --System on
        uci_cursor.set('system','wifi_led','sysfs',sled);
        uci_cursor.commit('system');
        os.execute("/etc/init.d/led stop")
        os.execute("/etc/init.d/led start")
    end
end

function configure_mode()
    local hw        = uci_cursor.get('meshdesk','settings','hardware');
    local sled      = uci_cursor.get('meshdesk',hw,'single_led');
    local sysled    = uci_cursor.get('meshdesk',hw,'system_led');
    if(sysled ~= sled)then -- Only when the single mode is not the same LED (else we switch it off)
        os.execute("echo '0' > '/sys/class/leds/"..sysled.."/brightness'"); --System on    
    end
end

function try_controller_modes()
    if(mode == 'ap')then
        print("Device in AP Mode");
        ap_wait_for_lan()
        --Make sure alfred started
        os.execute("/etc/init.d/alfred start")
    elseif(mode == 'mesh')then
        print("Device in Mesh node");
        wait_for_lan()
        --Make sure alfred started
        os.execute("/etc/init.d/alfred start")
    else
        print("Device in unknown mode of "..mode)
        os.exit();    
    end
end

--START--
os.execute("lua /etc/MESHdesk/watchdog.lua &"); --Kick off a watchdog in case the script does not complete

-- See if we have to set the device in config mode
config_mode = fetch_config_value('meshdesk.settings.config_mode');
if(config_mode == '1')then
	require("rdConfigModeMesh");
	local lmm  = rdConfigModeMesh();
	lmm:doTask();
	os.exit();
end


--Get the mode
mode = fetch_config_value('meshdesk.settings.mode')

if(mode == 'local')then
    --If it is the local gw set yourself up as the gw
    local_mode = fetch_config_value('meshdesk.settings.local_mode');
    if(local_mode == 'gateway')then
        require("rdLocalMesh");
        local lm = rdLocalMesh();
        lm:doGateway();
        --The above will manipulate the /etc/MESHdesk/configs/local_config_gateway.json
        --And write it to /etc/MESHdesk/configs/local_config.json
        configure_device('/etc/MESHdesk/configs/local_config.json')
        os.exit();
    end
    
    if(local_mode == 'standard')then
        --Do a clean start with the wireless--
        os.execute("cp /etc/MESHdesk/configs/local_network /etc/config/network");
        os.execute("/etc/init.d/network reload");
	    require("rdWireless")
	
	    local wireless = rdWireless()
	    wireless:newWireless()
	    --After this we can fetch a count of the radios
	    radio_count = wireless:getRadioCount()
        try_wifi();
        os.exit();
    end   
end

if(mode == 'off')then
    os.exit()
end

--=====================
--Pre-setup: ----------
--Configure Firmware is there is a server running on the correct IP and port
--=====================
do_fw_config()

--Prep the LEDs if needs to
prep_leds()

--=======================================
-- Check if we are and AP or a MESH node=
--=======================================
while (config_success == false and config_repeat_counter > 0) do
	log("Try to determine mode and get config.");
	try_controller_modes();
	config_repeat_counter = config_repeat_counter - 1;
end

if (config_success == false) then
	log("No config found. Reboot in ten minutes.");
	sleep(600);
	os.execute("reboot");
end

log("a.lua Configuration successful.");
log("Removing wireless config in order to ensure good start-up")
--os.execute("rm /etc/config/wireless"); -- Disable again since its needed to scan for rogues
--Let the watchdog also know we completed ok
os.execute("touch /tmp/startup_ok");

