-- This module is activated under the main muc component
-- This will prevent anyone joining the call one moderator join the room
-- the token configuration will be set before creating the meeting 
-- This module depends on mod_persistent_lobby.
local um_is_admin = require "core.usermanager".is_admin;
local jid = require "util.jid";
local cipher = require 'openssl.cipher';
local basexx = require 'basexx';

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

local muc_domain_base = module:get_option_string("muc_mapper_domain_base");
if not muc_domain_base then
    module:log("warn", "No 'muc_mapper_domain_base' option set, disabling muc_mapper plugin inactive");
    return
end

-- to activate this you need the following config in general config file in log = { }
-- { to = "file", filename = "/var/log/prosody/prosody.audit.log", levels = { "audit" }  }
-- local logger = require "util.logger";
-- local audit_logger = logger.make_logger("mod_"..module.name, "audit");

local lobby_muc_component_config = "lobby." .. muc_domain_base;
local lobby_host;

local function is_admin(jid)
    return um_is_admin(jid, module.host);
end

-- if not authenticated user is trying to join the room we enable lobby in it
-- and wait for the moderator to join
module:hook("muc-occupant-pre-join", function (event)
    local room, occupant, session = event.room, event.occupant, event.origin;
	local context_user = session.jitsi_meet_context_user;
	local context_room = session.jitsi_meet_context_room;
	local lobby_enabled = (room._data.lobbyroom ~= nil);
    -- we ignore jicofo as we want it to join the room or if the room has already seen its
    -- authenticated host
    if is_admin(occupant.bare_jid) or room.has_host then
        return;
    end
	
	if not context_user and not context_room then
		return;
	end

    local has_host = false;
    for _, o in room:each_occupant() do
        if jid.host(o.bare_jid) == muc_domain_base then
            room.has_host = true;
        end
    end

    if not room.has_host and context_user["affiliation"] == "member" and session.auth_token then
		local password, error = get_intulse_cfg(context_room["intulse_cfg"])

		if context_room["lobby"] == true and not lobby_enabled then
			prosody.events.fire_event("create-persistent-lobby-room", { room = room });
		end

		-- destroy lobby if requested
		if context_room["lobby"] == false and lobby_enabled then
			room:set_members_only(false);
			lobby_host.events.fire_event("destroy-lobby-room", {
				room = room,
				newjid = room.jid,
			});
		end

		if error then 
			module:log("error", error);
			return;
		end
		-- update password if set
		if type(password) == "string" then
			room:set_password(password);
		end
    end
end);

-- process a host module directly if loaded or hooks to wait for its load
function process_host_module(name, callback)
    local function process_host(host)
        if host == name then
            callback(module:context(host), host);
        end
    end

    if prosody.hosts[name] == nil then
        module:log("debug", "No host/component found, will wait for it: %s", name)

        -- when a host or component is added
        prosody.events.add_handler("host-activated", process_host);
    else
        process_host(name);
    end
end

process_host_module(lobby_muc_component_config, function(host_module, host)
    -- lobby muc component created
    module:log("info", "Lobby component loaded %s", host);
    lobby_host = module:context(host_module);
end);

