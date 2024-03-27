--- Plugin to dynamically enable security features when required by token.
---
--- This module should be added to the main muc component.
---
local LOGLEVEL = "debug";

local is_healthcheck_room = module:require "util".is_healthcheck_room;
local intulse = require "intulse/util.lib".new(module);


module:hook("muc-occupant-joined", function (event)
    local room = event.room;
	local affiliation = event.origin.jitsi_meet_context_user["affiliation"];

    if is_healthcheck_room(room.jid) then
        return;
    end

    if not event.origin.auth_token then
        module:log(LOGLEVEL,
            "skip security on demand, no token");
        return;
    end

    local context_room = event.origin.jitsi_meet_context_room;
    if not context_room then
        return;
    end

    local lobby_enabled = (room._data.lobbyroom ~= nil);

	if affiliation == "moderator" then 
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
	    if type(context_room["password"]) == "string" then
	        room:set_password(context_room["password"]);
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

    local context_user = event.origin.jitsi_meet_context_user;
    local context_room = event.origin.jitsi_meet_context_room;

    if not context_user and not context_room then
        return;
    end

    -- bypass security if allowed
    if context_user["affiliation"] == "moderator" then
        module:log(LOGLEVEL, "Bypassing security for room %s occupant %s",
            room.jid, occupant.bare_jid);

        -- bypass password if exists
		local room_password, error = intulse:get_intulse_cfg(context_room["intulse_cfg"])
		
		if error then 
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

        -- bypass lobby if exists
        room:set_affiliation(true, occupant.bare_jid, 'owner');
    end
end, -3);
--- Run just before lobby_bypass (priority -3), lobby(-4) and members_only (-5).
--- Must run after token_verification (99), max_occupants (10), allowners (2).
