#!/usr/bin/lua

function update_file_contents(data)
	local name = "/tmp/lverstatus.txt";
        os.execute("rm " .. name);
        os.execute("touch " .. name);
        local f = io.open(name, "w");
        io.output(f);
        io.write(data);
        io.close(f);

	os.execute("lua /etc/MESHdesk/alfred_scripts/alfred_report_to_server.lua");
        sleep(5);
end

function check_upgrade()

	while true do
		if pcall(exists) then
			os.execute("sleep 60");
			update_file_contents("Update starts.");
			os.execute("/sbin/sysupgrade -n /tmp/newfirmware.bin");
			os.execute("sleep 60");
		else
			os.execute("sleep 60");
		end
	end
end

function exists()
	local f=io.open("/tmp/selfupgrade.txt")
	io.close(f)
	return f==nil
end

check_upgrade()
