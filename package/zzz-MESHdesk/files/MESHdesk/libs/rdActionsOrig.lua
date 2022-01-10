require( "class" )

-------------------------------------------------------------------------------
-- Class used to check and execute actions for this node-----------------------

-------------------------------------------------------------------------------
class "rdActions"

--Init function for object
function rdActions:rdActions()
	require('rdLogger')
	require('rdNetwork')
	
	local uci	    = require('uci')
	self.version    = "1.0.1"
	self.tag	    = "MESHdesk"
	--self.debug	    = true
	self.debug	    = false
	self.json	    = require("json")
	self.logger	    = rdLogger()
	self.network	= rdNetwork()
	self.x		    = uci.cursor()
	self.waiting	= 115
	self.completed	= 116
	
	local id_if     = self.x.get('meshdesk','settings','id_if');
	
	self.id_if		= self.network:getMac(id_if)
	self.results	= '/tmp/actions_result.json'
	self.d_waiting  = '/etc/MESHdesk/mesh_status/waiting';
	self.d_completed= '/etc/MESHdesk/mesh_status/completed';
	self.nfs        = require "nixio.fs";   
end
        
function rdActions:getVersion()
	return self.version
end

function rdActions:check()
	self:log("== Do the check for any awaiting actions ==")
	self:_check()
end

function rdActions:wip()
    self:log("==Do WIP for Actions ==")
    self:_wip()
end

function rdActions:setWaitingList(list)
    self:_setWaitingList(list)
end

function rdActions:log(m,p)
	if(self.debug)then
		self.logger:log(m,p)
	end
end

--[[--
========================================================
=== Private functions start here =======================
========================================================
--]]--


function rdActions._check(self)
	local waiting 	= self:_getWaitingList()
	local completed	= self:_getCompletedList()

	--Is there some commands waiting?
	if(waiting)then
		--Is there some already some completed
		if(completed)then
			self:log("Found completed list - Check if there are new ones in the waiting list")
			--Is there unfinished commands (in the waiting list but not in completed list)
			if(self:_checkForNewActions(waiting,completed))then
				self:_fetchActions()
			end
		else
			self:log("No completed list - Fetch commands")
			self:_fetchActions()
		end
	end  	
end


function rdActions._wip(self)
    self:setWaitingList({5,6,7,8});
    local waiting 	= self:_getWaitingList();
	local completed	= self:_getCompletedList();
end

function rdActions._setWaitingList(self,list)
    --Write the awaiting actions no matter if you overwrite them they will remain waiting untill fetched
    for a, k in ipairs(list) do
        os.execute("touch "..self.d_waiting..'/'..k);
    end   
end

function rdActions._getWaitingList(self)
	if(self.nfs.dir(self.d_waiting) ~= nil) then
	    local t_waiting  = {}
        for entry in self.nfs.dir(self.d_waiting) do
                table.insert(t_waiting,entry);
        end 
        return t_waiting;                              
    end    
	return false;	
end

function rdActions._getCompletedList(self)

    if(self.nfs.dir(self.d_completed) ~= nil) then
	    local t_completed  = {}
        for entry in self.nfs.dir(self.d_completed) do
                table.insert(t_completed,entry);
        end 
        return t_completed;                              
    end    
	return false;
end

function rdActions._checkForNewActions(self,waiting,completed)

	local new_actions = false
	--If there are new actions it will be in the waiting list and NOT in the completed
	for a, k in ipairs(waiting) do
		local found = false
		for b, l in ipairs(completed) do
			if(k == l)then
				found = true
			end
		end
		if(found ~= true)then --break on the first waiting one NOT found in completed
			new_actions = true
			break
		end
	end
	return new_actions
end

function rdActions._fetchActions(self)
	local curl_data = '{"mac":"'..self.id_if..'"}'
    local proto 	= self.x.get('meshdesk','internet1','protocol')
    local mode      = self.x.get('meshdesk','settings','mode')
    
    local url       = self.x.get('meshdesk','internet1','actions_url')
    
    if(mode == 'ap')then
        url       = self.x.get('meshdesk','internet1','ap_actions_url')
    end
    
     --13-6-18 Add a cache buster--
    url             = url.."?_dc="..os.time();
    
    local server    = self.x.get('meshdesk','internet1','ip')
    
	local local_ip_v6   = self.network:getIpV6ForInterface('br-lan');
	if(local_ip_v6)then
	    server      = self.x.get("meshdesk", "internet1", "ip_6");
	    server      = '['..server..']';
	end
	
    local query     = proto .. "://" .. server .. "/" .. url

    --Remove old results                                                                                              
    os.remove(self.results)
    os.execute('curl -k -o '..self.results..' -X POST -H "Content-Type: application/json" -d \''..curl_data..'\' '..query)
    
    --Read the results
    local f=io.open(self.results,"r")
    if(f)then
        result_string = f:read("*all")
        r =self.json.decode(result_string)
        if(r.success)then
			if(r.items)then
				self:_executeActions(r.items)
			end
        end
    end
end

function rdActions._executeActions(self,actions)
	--Actions is a list in the format [{'id':"98","command": "reboot"}]--
	for i, row in ipairs(actions)do
		print("Doing action NR "..row.id)
		self:_addToCompleted(row.id)
		print("Doing "..row.command)
		os.execute(row.command)
	end
end

function rdActions._addToCompleted(self,id)
	--Get the current list of completed
	os.execute("touch "..self.d_completed..'/'..id);
end

