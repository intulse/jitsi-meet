local new_throttle = require "util.throttle".create;
local st = require "util.stanza";

local token_util = module:require "token/util".new(module);
local util = module:require 'util';
local room_jid_match_rewrite = util.room_jid_match_rewrite;
local is_feature_allowed = util.is_feature_allowed;
local get_room_from_jid = util.get_room_from_jid;
local is_healthcheck_room = util.is_healthcheck_room;
local process_host_module = util.process_host_module;
local jid_bare = require "util.jid".bare;

local sessions = prosody.full_sessions;

local measure_drop = module:measure('drop', 'counter');

local main_muc_component_host = module:get_option_string('main_muc');
if main_muc_component_host == nil then
    module:log('error', 'main_muc not configured. Cannot proceed.');
    return;
end
local main_muc_service;

-- no token configuration but required
if token_util == nil then
    module:log("error", "no token configuration but it is required");
    return;
end

-- The maximum number of simultaneous calls,
-- and also the maximum number of new calls per minute that a session is allowed to create.
local limit_outgoing_calls;
local function load_config()
    limit_outgoing_calls = module:get_option_number("max_number_outgoing_calls", -1);
end
load_config();

-- Header names to use to push extra data extracted from token, if any
local OUT_INITIATOR_USER_ATTR_NAME = "X-outbound-call-initiator-user";
local OUT_INITIATOR_GROUP_ATTR_NAME = "X-outbound-call-initiator-group";
local OUTGOING_CALLS_THROTTLE_INTERVAL = 60; -- if max_number_outgoing_calls is enabled it will be
                                             -- the max number of outgoing calls a user can try for a minute

-- filters rayo iq in case of requested from not jwt authenticated sessions
-- or if the session has features in user context and it doesn't mention
-- feature "outbound-call" to be enabled
module:hook("pre-iq/full", function(event)
    local stanza = event.stanza;
    if stanza.name == "iq" then
        local dial = stanza:get_child('dial', 'urn:xmpp:rayo:1');
        if dial then
            local session = event.origin;
            local token = session.auth_token;

            -- find header with attr name 'JvbRoomName' and extract its value
            local headerName = 'JvbRoomName';
            local roomName;
            for _, child in ipairs(dial.tags) do
                if (child.name == 'header'
                        and child.attr.name == headerName) then
                    roomName = child.attr.value;
                    break;
                end
            end

            if token == nil
                or roomName == nil
                or not token_util:verify_room(session, room_jid_match_rewrite(roomName))
                or not is_feature_allowed(session,
                            (dial.attr.to == 'jitsi_meet_transcribe' and 'transcription'
                                or 'outbound-call'))
            then
                module:log("warn",
                    "Filtering stanza dial, stanza:%s", tostring(stanza));
                session.send(st.error_reply(stanza, "auth", "forbidden"));
                return true;
            end

            -- now lets check any limits if configured
            if limit_outgoing_calls > 0 then
                if not session.dial_out_throttle then
                    module:log("debug", "Enabling dial-out throttle session=%s.", session);
                    session.dial_out_throttle = new_throttle(limit_outgoing_calls, OUTGOING_CALLS_THROTTLE_INTERVAL);
                end

                if not session.dial_out_throttle:poll(1) -- we first check the throttle so we can mark one incoming dial for the balance
                    or get_concurrent_outgoing_count(session.jitsi_meet_context_user["id"], session.jitsi_meet_context_group)
                            >= limit_outgoing_calls
                then
                    module:log("warn",
                        "Filtering stanza dial, stanza:%s, outgoing calls limit reached", tostring(stanza));
                    measure_drop(1);
                    session.send(st.error_reply(stanza, "cancel", "resource-constraint"));
                    return true;
                end
            end

            -- now lets insert token information if any
            if session and session.jitsi_meet_context_user then
                -- First remove any 'header' element if it already
                -- exists, so it cannot be spoofed by a client
                stanza:maptags(
                    function(tag)
                        if tag.name == "header"
                                and (tag.attr.name == OUT_INITIATOR_USER_ATTR_NAME
                                        or tag.attr.name == OUT_INITIATOR_GROUP_ATTR_NAME) then
                            return nil
                        end
                        return tag
                    end
                )

                local dial = stanza:get_child('dial', 'urn:xmpp:rayo:1');
                -- adds initiator user id from token
                dial:tag("header", {
                    xmlns = "urn:xmpp:rayo:1",
                    name = OUT_INITIATOR_USER_ATTR_NAME,
                    value = session.jitsi_meet_context_user["id"] });
                dial:up();

                -- Add the initiator group information if it is present
                if session.jitsi_meet_context_group then
                    dial:tag("header", {
                        xmlns = "urn:xmpp:rayo:1",
                        name = OUT_INITIATOR_GROUP_ATTR_NAME,
                        value = session.jitsi_meet_context_group });
                    dial:up();
                end
            end
        end
    end
end);

--- Finds and returns the number of concurrent outgoing calls for a user
-- @param context_user the user id extracted from the token
-- @param context_group the group id extracted from the token
-- @return returns the count of concurrent calls
function get_concurrent_outgoing_count(context_user, context_group)
    local count = 0;
    for _, host in pairs(hosts) do
        local component = host;
        if component then
            local muc = component.modules.muc
            local rooms = nil;
            if muc and rawget(muc,"rooms") then
                -- We're running 0.9.x or 0.10 (old MUC API)
                return muc.rooms;
            elseif muc and rawget(muc,"live_rooms") then
                -- We're running >=0.11 (new MUC API)
                rooms = muc.live_rooms();
            elseif muc and rawget(muc,"each_room") then
                -- We're running trunk<0.11 (each_room is later [DEPRECATED])
                rooms = muc.each_room(true);
            end

            -- now lets iterate over rooms and occupants and search for
            -- call initiated by the user
            if rooms then
                for room in rooms do
                    for _, occupant in room:each_occupant() do
                        for _, presence in occupant:each_session() do

                            local initiator = presence:get_child('initiator', 'http://jitsi.org/protocol/jigasi');

                            local found_user = false;
                            local found_group = false;

                            if initiator then
                                initiator:maptags(function (tag)
                                    if tag.name == "header"
                                        and tag.attr.name == OUT_INITIATOR_USER_ATTR_NAME then
                                        found_user = tag.attr.value == context_user;
                                    elseif tag.name == "header"
                                        and tag.attr.name == OUT_INITIATOR_GROUP_ATTR_NAME then
                                        found_group = tag.attr.value == context_group;
                                    end

                                    return tag;
                                end );
                                -- if found a jigasi participant initiated by the concurrent
                                -- participant, count it
                                if found_user
                                    and (context_group == nil or found_group) then
                                    count = count + 1;
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return count;
end

module:hook_global('config-reloaded', load_config);

function process_set_affiliation(event)
    local actor, affiliation, jid, previous_affiliation, room
        = event.actor, event.affiliation, event.jid, event.previous_affiliation, event.room;
    local actor_session = sessions[actor];

    if is_admin(jid) or is_healthcheck_room(room.jid) or not actor or not previous_affiliation
        or not actor_session or not actor_session.jitsi_meet_context_features then
        return;
    end

    local occupant;
    for _, o in room:each_occupant() do
        if o.bare_jid == jid then
            occupant = o;
        end
    end

    if not occupant then
        return;
    end

    local occupant_session = sessions[occupant.jid];
    if not occupant_session then
        return;
    end

    if previous_affiliation == 'none' and affiliation == 'owner' then
        occupant_session.granted_jitsi_meet_context_features = actor_session.jitsi_meet_context_features;
        occupant_session.granted_jitsi_meet_context_user_id = actor_session.jitsi_meet_context_user["id"];
        occupant_session.granted_jitsi_meet_context_group_id = actor_session.jitsi_meet_context_group;
    elseif previous_affiliation == 'owner' and ( affiliation == 'member' or affiliation == 'none' ) then
        occupant_session.granted_jitsi_meet_context_features = nil;
        occupant_session.granted_jitsi_meet_context_user_id = nil;
        occupant_session.granted_jitsi_meet_context_group_id = nil;
    end
end

function process_main_muc_loaded(main_muc, host_module)
    module:log('debug', 'Main muc loaded');

    main_muc_service = main_muc;
    module:log("info", "Hook to muc events on %s", main_muc_component_host);
    host_module:hook("muc-pre-set-affiliation", process_set_affiliation);
end

process_host_module(main_muc_component_host, function(host_module, host)
    local muc_module = prosody.hosts[host].modules.muc;

    if muc_module then
        process_main_muc_loaded(muc_module, host_module);
    else
        module:log('debug', 'Will wait for muc to be available');
        prosody.hosts[host].events.add_handler('module-loaded', function(event)
            if (event.module == 'muc') then
                process_main_muc_loaded(prosody.hosts[host].modules.muc, host_module);
            end
        end);
    end
end);
