--- Plugin to dynamically enable security features when required by token.
---
--- This module should be added to the main muc component.
---
local LOGLEVEL = "debug";
local cipher = require 'openssl.cipher';
local basexx = require 'basexx';

local is_healthcheck_room = module:require "util".is_healthcheck_room;

local muc_domain_base = module:get_option_string("muc_mapper_domain_base");
if not muc_domain_base then
    module:log("warn", "No 'muc_mapper_domain_base' option set, disabling muc_mapper plugin inactive");
    return
end

function get_intulse_cfg(cfg)
	local intulse_key = module:get_option_string("intulse_key")
	local intulse_iv = module:get_option_string("intulse_iv")

	if intulse_key == nil or intulse_iv == nil then
		return nil, "Intulse cfg settings must be set";	
	end

	if not cfg then
		return nil, 'INTULSE error: No valid intulse cfg data found in the token.';
	end
	
	local password, error = "", nil;
	local str = basexx.from_base64(cfg);

	if string.len(cfg) > 0 then
		password, error = cipher.new("aes-128-cbc"):decrypt(intulse_key, intulse_iv):final(str);
	end 

	return password, error;
end

module:hook("muc-occupant-joined", function (event)
    local room = event.room;
    local context_user = event.origin.jitsi_meet_context_user;
    local context_room = event.origin.jitsi_meet_context_room;

	module:log("info","ANDRES ROOM-INFO" .. tostring(room.jid));
    if is_healthcheck_room(room.jid) then
        return;
    end

    if not event.origin.auth_token then
        module:log(LOGLEVEL, "skip security on demand, no token");
        return;
    end

    if not context_room and not context_user then
        module:log("error", "INTULSE error: No context data from token");
        return;
    end

    local lobby_enabled = (room._data.lobbyroom ~= nil);

	if context_user["affiliation"] == "moderator" then 
    	-- create lobby if requested
    	if context_room["lobby"] == true and not lobby_enabled then
			prosody.events.fire_event("create-persistent-lobby-room", { room = room });
    	end

	    -- destroy lobby if requested
	    if context_room["lobby"] == false and lobby_enabled then
	        room:set_members_only(false);
	        prosody.events.fire_event('destroy-lobby-room', {
	            room = room,
	            newjid = room.jid,
	        });
	    end

		local room_password, error = get_intulse_cfg(context_room["intulse_cfg"])
		if error then
			module:log("error", error);
			return; 
		end 

	    -- update password if set
	    if type(room_password) == "string" and room:get_password() ~= room_password then
	        room:set_password(room_password);
	    end
    end
end);


module:hook("muc-occupant-pre-join", function (event)
    local room, occupant, stanza, session = event.room, event.occupant, event.stanza, event.origin;
    local MUC_NS = "http://jabber.org/protocol/muc";

    if is_healthcheck_room(room.jid) then
        return;
    end

	if not session.auth_token then
		module:log(LOGLEVEL, 'INTULSE error: No valid authentication token.')
		return;
	end

    local context_user = session.jitsi_meet_context_user;
    local context_room = session.jitsi_meet_context_room;

    if not context_user and not context_room then
        return;
    end

    -- bypass security if allowed
    if context_user["affiliation"] == "moderator"  and string.len(context_room["intulse_cfg"]) > 0 then
        module:log(LOGLEVEL, "Bypassing security for room %s occupant %s",
            room.jid, occupant.bare_jid);

        -- bypass password if exists
		local room_password, error = get_intulse_cfg(context_room["intulse_cfg"])
		
		if error and not room_password then 
			module:log("error", error);
			return;
		end

        if room_password then
            local join = stanza:get_child("x", MUC_NS);

            if not join then
                join = stanza:tag("x", { xmlns = MUC_NS });
            end

            join:tag("password", { xmlns = MUC_NS }):text(room_password);
        end
    end
end, -2);
-- - Run just before lobby_bypass (priority -3), lobby(-4) and members_only (-5).
-- - Must run after token_verification (99), max_occupants (10), allowners (2).