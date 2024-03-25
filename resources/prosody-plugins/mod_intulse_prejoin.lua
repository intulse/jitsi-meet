-- >>>>> MODIFIED BY INTULSE mod_muc_wait_for_host.lua & mod_token_security_ondemand

-- This module is activated under the main muc component
-- This will prevent anyone joining the call till jicofo and one moderator join the room
-- for the rest of the participants lobby will be turned on and they will be waiting there till
-- the main participant joins and lobby will be turned off at that time and rest of the participants will
-- join the room. It expects main virtual host to be set to require jwt tokens and guests to use
-- the guest domain which is anonymous.
-- The module has the option to set participants to moderators when connected via token/when they are authenticated
-- This module depends on mod_persistent_lobby.
local um_is_admin = require 'core.usermanager'.is_admin;
local jid = require 'util.jid';
local util = module:require "util";
local is_healthcheck_room = util.is_healthcheck_room;
local is_moderated = util.is_moderated;

-- >>>>> INTULSE addition 
local log_lvl = 'info' -- change to 'debug' for more comprehensive logging;
local MUC_NS = 'http://jabber.org/protocol/muc';
local cipher = require 'openssl.cipher';
local basexx = require 'basexx';

function get_intulse_cfg(cfg)
	local str = basexx.from_base64(cfg);
	local k = 'lkirwf897+22#bbt';
	local i = '52hheeyy66#c8y5d';
	return cipher.new('aes-128-cbc'):decrypt(k,i):final(str);
end 

-- >>>>> END addition

local disable_auto_owners = module:get_option_boolean('wait_for_host_disable_auto_owners', false);

local muc_domain_base = module:get_option_string('muc_mapper_domain_base');
if not muc_domain_base then
    module:log('warn', "No 'muc_mapper_domain_base' option set, disabling muc_mapper plugin inactive");
    return
end

-- to activate this you need the following config in general config file in log = { }
-- { to = 'file', filename = '/var/log/prosody/prosody.audit.log', levels = { 'audit' }  }
-- local logger = require 'util.logger';
-- local audit_logger = logger.make_logger('mod_'..module.name, 'audit');

local lobby_muc_component_config = 'lobby.' .. muc_domain_base;
-- local lobby_host;

local function is_admin(jid)
    return um_is_admin(jid, module.host);
end

-- if not authenticated user is trying to join the room we enable lobby in it
-- and wait for the moderator to join
module:hook('muc-occupant-pre-join', function (event)
    local room, occupant, session, stanza = event.room, event.occupant, event.origin, event.stanza;
    -- we ignore jicofo as we want it to join the room or if the room has already seen its
    -- authenticated host
    if is_admin(occupant.bare_jid) or is_healthcheck_room(room.jid) or room.has_host then
        return;
    end

    local has_host = false;
    for _, o in room:each_occupant() do
        if jid.host(o.bare_jid) == muc_domain_base then
            room.has_host = true;
        end
    end

	-- >>>>> INTULSE addition
	local affiliation = session.jitsi_meet_context_user["affiliation"];
	local context_room =  session.jitsi_meet_context_room;
	local lobby_enabled = (room._data.lobbyroom ~= nil);
	local room_pw = room:get_password();
	local password = nil;
	local err = nil;

	if not session.auth_token then
		module:log(log_lvl, 'INTULSE error: No valid authentication token.')
		return;
	end

	if not context_room then
		module:log(log_lvl, 'INTULSE error: No valid context room data found in the token.')
		return;
	end

	if not context_room['intulse_cfg'] then
		module:log(log_lvl, 'INTULSE error: No valid intulse cfg data found in the token.')
		return;
	end

	if string.len(context_room['intulse_cfg']) == 0 then
		password = "";
	end
			
	password, err = get_intulse_cfg(context_room['intulse_cfg']); 
	
	if err then
		module:log(log_lvl, 'INTULSE error: ' .. err);
		return;
	end

	-- if affiliation is member than it matters if the room has a host
	if not room.has_host and affiliation == "member"  and session.auth_token then
    	-- create lobby if requested
    	if context_room["lobby"] == true and not lobby_enabled then
    	    prosody.events.fire_event("create-persistent-lobby-room", {
    	        room = room,
    	        skip_display_name_check = true,
    	    });
    	end

	    -- destroy lobby if requested
	    if context_room["lobby"] == false and lobby_enabled then
	        room:set_members_only(false);
	        prosody.events.fire_event('destroy-lobby-room', {
	            room = room,
	            newjid = room.jid,
	        });
	    end

	    -- update password if set
	    if type(password) == "string" then
	        room:set_password(password);
	    end
		
    end

	-- if affiliation is a moderator then it matters if the room has an active password
	if affiliation == 'moderator' and password and room_pw == password then
		local join = stanza:get_child("x", MUC_NS);

        if not join then
            join = stanza:tag("x", { xmlns = MUC_NS });
        end            

		if not join then
			return;
		end

		join:tag("password", { xmlns = MUC_NS }):text(password);
	end
	
	
end);

module:hook("muc-occupant-joined", function (event)
    local room = event.room;
	local password = nil;
	local err = nil;

    if is_healthcheck_room(room.jid) then
        return;
    end

    local context_room = event.origin.jitsi_meet_context_room;
    if not context_room then
        return;
	end

    local lobby_enabled = (room._data.lobbyroom ~= nil);
	if not context_room['intulse_cfg'] then
		module:log(log_lvl, 'INTULSE error: No valid intulse cfg data found in the token.')
		return;
	else
		module:log(log_lvl, 'ANDRES intulse_cfg: ' .. context_room['intulse_cfg'])
		if string.len(context_room['intulse_cfg']) > 0 then
			password, err = get_intulse_cfg(context_room['intulse_cfg']); 
			if err then
				module:log(log_lvl, 'INTULSE error: ' .. err);
				return;
			end
		else
			password = "";
		end
	end

    -- create lobby if requested
    if context_room["lobby"] == true and not lobby_enabled then
        prosody.events.fire_event("create-persistent-lobby-room", {
            room = room,
            skip_display_name_check = true,
        });
    end

    -- destroy lobby if requested
    if context_room["lobby"] == false and lobby_enabled then
        room:set_members_only(false);
        prosody.events.fire_event('destroy-lobby-room', {
            room = room,
            newjid = room.jid,
        });
    end

    -- update password if set
    if type(password) == "string" then
        room:set_password(password);
    end
end);

-- >>>>> END
-- process a host module directly if loaded or hooks to wait for its load
function process_host_module(name, callback)
    local function process_host(host)
        if host == name then
            callback(module:context(host), host);
        end
    end

    if prosody.hosts[name] == nil then
        module:log('debug', 'No host/component found, will wait for it: %s', name)

        -- when a host or component is added
        prosody.events.add_handler('host-activated', process_host);
    else
        process_host(name);
    end
end

process_host_module(lobby_muc_component_config, function(host_module, host)
    -- lobby muc component created
    module:log(log_lvl, 'Lobby component loaded %s', host);
    lobby_host = module:context(host_module);
end);
