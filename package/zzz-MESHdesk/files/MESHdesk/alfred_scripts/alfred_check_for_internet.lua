#!/usr/bin/lua

-- Include libraries
package.path = "../libs/?.lua;" .. package.path

require("uci");

local nfs   = require "nixio.fs";

function check()
    local x             = uci.cursor();
    --local ts            = x.get('mesh_status', 'status', 'report_timestamp');   
    local ts            = nfs.readfile('/tmp/report_timestamp');
    local dead_after    = x.get('meshdesk', 'settings', 'heartbeat_dead_after');
    local hardware      = x.get('meshdesk', 'settings', 'hardware');
    local led           = x.get('meshdesk', hardware, 'internet_led');
    
    if(ts == nil)then
        os.execute('echo 0 > ' .. led )
        return;
    end
      
    if(os.time() > (ts + dead_after))then
        os.execute('echo 0 > ' .. led )
    else
        os.execute('echo 1 > ' .. led )
    end
end

check()

