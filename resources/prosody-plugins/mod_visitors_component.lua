module:log('info', 'Starting visitors_component at %s', module.host);

local jid = require 'util.jid';
local st = require 'util.stanza';
local util = module:require 'util';
local room_jid_match_rewrite = util.room_jid_match_rewrite;
local get_room_from_jid = util.get_room_from_jid;
local get_focus_occupant = util.get_focus_occupant;
local get_room_by_name_and_subdomain = util.get_room_by_name_and_subdomain;
local internal_room_jid_match_rewrite = util.internal_room_jid_match_rewrite;
local is_vpaas = util.is_vpaas;
local is_sip_jibri_join = util.is_sip_jibri_join;
local process_host_module = util.process_host_module;
local new_id = require 'util.id'.medium;
local um_is_admin = require 'core.usermanager'.is_admin;
local json = require 'cjson.safe';
local inspect = require 'inspect';

local MUC_NS = 'http://jabber.org/protocol/muc';

local muc_domain_prefix = module:get_option_string('muc_mapper_domain_prefix', 'conference');
local muc_domain_base = module:get_option_string('muc_mapper_domain_base');
if not muc_domain_base then
    module:log('warn', 'No muc_domain_base option set.');
    return;
end

-- A list of domains which to be ignored for visitors. The config is set under the main virtual host
local ignore_list = module:context(muc_domain_base):get_option_set('visitors_ignore_list', {});

local auto_allow_promotion = module:get_option_boolean('auto_allow_visitor_promotion', false);

-- whether to always advertise that visitors feature is enabled for rooms
-- can be set to off and being controlled by another module, turning it on and off for rooms
local always_visitors_enabled = module:get_option_boolean('always_visitors_enabled', true);

local function is_admin(jid)
    return um_is_admin(jid, module.host);
end

-- This is a map to keep data for room and the jids that were allowed to join after visitor mode is enabled
-- automatically allowed or allowed by a moderator
local visitors_promotion_map = {};

local sent_iq_cache = require 'util.cache'.new(200);

-- send iq result that the iq was received and will be processed
local function respond_iq_result(origin, stanza)
    -- respond with successful receiving the iq
    origin.send(st.iq({
        type = 'result';
        from = stanza.attr.to;
        to = stanza.attr.from;
        id = stanza.attr.id
    }));
end

local function request_promotion_received(room, from_jid, from_vnode)
    if not visitors_promotion_map[room.jid] and auto_allow_promotion then
        -- visitors is enabled
        visitors_promotion_map[room.jid] = {};
    end

    -- if visitors is enabled for the room
    if visitors_promotion_map[room.jid] then
        if auto_allow_promotion then
            --  we are in auto-allow mode, let's reply with accept
            -- we store where the request is coming from so we can send back the response
            local username = new_id():lower();
            visitors_promotion_map[room.jid][username] = {
                from = from_vnode;
                jid = from_jid;
            };

            local req_from = visitors_promotion_map[room.jid][username].from;
            local req_jid = visitors_promotion_map[room.jid][username].jid;
            local focus_occupant = get_focus_occupant(room);
            local focus_jid = focus_occupant and focus_occupant.bare_jid or nil;

            local iq_id = new_id();
            sent_iq_cache:set(iq_id, socket.gettime());

            local node = jid.node(room.jid);

            module:send(st.iq({
                    type='set', to = req_from, from = module.host, id = iq_id })
                :tag('visitors', {
                    xmlns='jitsi:visitors',
                    room = jid.join(node, muc_domain_prefix..'.'..req_from),
                    focusjid = focus_jid })
                 :tag('promotion-response', {
                    xmlns='jitsi:visitors',
                    jid = req_jid,
                    username = username ,
                    allow = 'true' }):up());
            return true;
        else
            -- send promotion request to all moderators
            local body_json = {};
            body_json.type = 'visitors';
            body_json.room = internal_room_jid_match_rewrite(room.jid);
            body_json.action = 'promotion-request';
            body_json.nick = nick;
            body_json.from = from_jid;

            if time and time > 0 then
                -- raise hand
                body_json.on = true;
            else
                -- lower hand, we want to inform interested parties that
                -- the visitor is no longer interested in joining the main call
                body_json.on = false;
            end

            local msg_to_send, error = json.encode(body_json);

            if not msg_to_send then
                module:log('error', 'Error encoding msg room:%s error:%s', room.jid, error)
                return true;
            end

            if visitors_promotion_requests[room.jid] then
                visitors_promotion_requests[room.jid][from_jid] = {
                    msg = msg_to_send;
                    from = from_vnode;
                };
            else
                module:log('warn', 'Received promotion request for room %s with visitors not enabled. %s',
                    room.jid, msg_to_send);
            end

            -- let's send a notification to every moderator
            for _, occupant in room:each_occupant() do
                if occupant.role == 'moderator' and not is_admin(occupant.bare_jid) then
                    send_json_message(occupant.jid, msg_to_send);
                end
            end

            return true;
        end

        -- TODO send promotion request to all moderators
        module:log('warn', 'Received promotion request from %s for room %s without active visitors', from, room.jid);
        return;
    end
end

local function connect_vnode_received(room, vnode)
    module:context(muc_domain_base):fire_event('jitsi-connect-vnode', { room = room; vnode = vnode; });
end

local function disconnect_vnode_received(room, vnode)
    module:context(muc_domain_base):fire_event('jitsi-disconnect-vnode', { room = room; vnode = vnode; });
end

-- listens for iq request for promotion and forward it to moderators in the meeting for approval
-- or auto-allow it if such the config is set enabling it
local function stanza_handler(event)
    local origin, stanza = event.origin, event.stanza;

    if stanza.name ~= 'iq' then
        return;
    end

    if stanza.attr.type == 'result' and sent_iq_cache:get(stanza.attr.id) then
        sent_iq_cache:set(stanza.attr.id, nil);
        return true;
    end

    if stanza.attr.type ~= 'set' and stanza.attr.type ~= 'get' then
        return; -- We do not want to reply to these, so leave.
    end

    local visitors_iq = event.stanza:get_child('visitors', 'jitsi:visitors');
    if not visitors_iq then
        return;
    end

    -- set stanzas are coming from s2s connection
    if stanza.attr.type == 'set' and origin.type ~= 's2sin' then
        module:log('warn', 'not from s2s session, ignore! %s', stanza);
        return true;
    end

    local room_jid = visitors_iq.attr.room;
    local room = get_room_from_jid(room_jid_match_rewrite(room_jid));

    if not room then
        -- this maybe as we receive the iq from jicofo after the room is already destroyed
        module:log('debug', 'No room found %s', room_jid);
        return;
    end

    local processed;
    -- promotion request is coming from visitors and is a set and is over the s2s connection
    local request_promotion = visitors_iq:get_child('promotion-request');
    if request_promotion then
        processed = request_promotion_received(room, request_promotion.attr.jid, stanza.attr.from);
    end

    -- connect and disconnect are only received from jicofo
    if is_admin(jid.bare(stanza.attr.from)) then
        for item in visitors_iq:childtags('connect-vnode') do
            connect_vnode_received(room, item.attr.vnode);
            processed = true;
        end

        for item in visitors_iq:childtags('disconnect-vnode') do
            disconnect_vnode_received(room, item.attr.vnode);
            processed = true;
        end
    end

    if not processed then
        module:log('warn', 'Unknown iq received for %s: %s', module.host, stanza);
    end

    respond_iq_result(origin, stanza);
    return processed;
end

local function process_promotion_response(room, id, approved)
    -- lets reply to participant that requested promotion
    local username = new_id():lower();
    visitors_promotion_map[room.jid][username] = {
        from = visitors_promotion_requests[room.jid][id].from;
        jid = id;
    };

    local req_from = visitors_promotion_map[room.jid][username].from;
    local req_jid = visitors_promotion_map[room.jid][username].jid;
    local focus_occupant = get_focus_occupant(room);
    local focus_jid = focus_occupant and focus_occupant.bare_jid or nil;

    local iq_id = new_id();
    sent_iq_cache:set(iq_id, socket.gettime());

    local node = jid.node(room.jid);

    module:send(st.iq({
            type='set', to = req_from, from = module.host, id = iq_id })
        :tag('visitors', {
            xmlns='jitsi:visitors',
            room = jid.join(node, muc_domain_prefix..'.'..req_from),
            focusjid = focus_jid })
         :tag('promotion-response', {
            xmlns='jitsi:visitors',
            jid = req_jid,
            username = username,
            allow = approved }):up());
end

module:hook('iq/host', stanza_handler, 10);

process_host_module(muc_domain_prefix..'.'..muc_domain_base, function(host_module, host)
    -- if visitor mode is started, then you are not allowed to join without request/response exchange of iqs -> deny access
    -- check list of allowed jids for the room
    host_module:hook('muc-occupant-pre-join', function (event)
        local room, stanza, origin = event.room, event.stanza, event.origin;

        -- visitors were already in the room one way or another they have access
        -- skip password challenge
        local join = stanza:get_child('x', MUC_NS);
        if join and room:get_password() and
            visitors_promotion_map[room.jid] and visitors_promotion_map[room.jid][jid.node(stanza.attr.from)] then
            join:tag('password', { xmlns = MUC_NS }):text(room:get_password());
        end

        -- we skip any checks when auto-allow is enabled
        if auto_allow_promotion then
            return;
        end

        if visitors_promotion_map[room.jid] then
            -- now let's check for jid
            if visitors_promotion_map[room.jid][jid.node(stanza.attr.from)] -- promotion was approved
                or ignore_list:contains(jid.host(stanza.attr.from)) then -- jibri or other domains to ignore
                -- allow join
                return;
            end
            module:log('error', 'Visitor needs to be allowed by a moderator %s', stanza.attr.from);
            origin.send(st.error_reply(stanza, 'cancel', 'not-allowed', 'Visitor needs to be allowed by a moderator'));
            return true;
        end

    end, 7); -- after muc_meeting_id, the logic for not joining before jicofo
    host_module:hook('muc-room-destroyed', function (event)
        visitors_promotion_map[event.room.jid] = nil;
    end);
end);

-- enable only in case of auto-allow is enabled
if auto_allow_promotion then
    prosody.events.add_handler('pre-jitsi-authentication', function(session)
        if not session.customusername or not session.jitsi_web_query_room then
            return nil;
        end

        local room = get_room_by_name_and_subdomain(session.jitsi_web_query_room, session.jitsi_web_query_prefix);
        if not room then
            return nil;
        end

        if visitors_promotion_map[room.jid] and visitors_promotion_map[room.jid][session.customusername] then
            -- user was previously allowed to join, let him use the requested jid
            return session.customusername;
        end
    end);
end

        if stanza.attr.type ~= "groupchat" then
            return;
        end
        local json_data = stanza:get_child_text("json-message", "http://jitsi.org/jitmeet");
        if json_data == nil then
            return;
        end
        local data, error = json.decode(json_data);
        if not data or data.type ~= 'visitors'
            or (data.action ~= "promotion-response" and data.action ~= "demote-request") then
            if error then
                module:log('error', 'Error decoding error:%s', error);
            end
            return;
        end

        local room = get_room_from_jid(event.stanza.attr.to);

        local occupant_jid = event.stanza.attr.from;
        local occupant = room:get_occupant_by_real_jid(occupant_jid);
        if not occupant then
            module:log("error", "Occupant %s was not found in room %s", occupant_jid, room.jid)
            return
        end
        if occupant.role ~= 'moderator' then
            module:log('error', 'Occupant %s sending response message but not moderator in room %s',
                occupant_jid, room.jid);
            return false;
        end

        if data.action == "demote-request" then
            if occupant.nick ~= room.jid..'/'..data.actor then
                module:log('error', 'Bad actor in demote request %s', stanza);
                event.origin.send(st.error_reply(stanza, "cancel", "bad-request"));
                return true;
            end

            -- when demoting we want to send message to the demoted participant and to moderators
            local target_jid = room.jid..'/'..data.id;
            stanza.attr.type = 'chat'; -- it is safe as we are not using this stanza instance anymore
            stanza.attr.from = module.host;

            for _, room_occupant in room:each_occupant() do
                -- do not send it to jicofo or back to the sender
                if room_occupant.jid ~= occupant.jid and not is_admin(room_occupant.bare_jid) then
                    if room_occupant.role == 'moderator'
                        or room_occupant.nick == target_jid then
                        stanza.attr.to = room_occupant.jid;
                        room:route_stanza(stanza);
                    end
                end
            end

        else
            if data.id then
                process_promotion_response(room, data.id, data.approved and 'true' or 'false');
            else
                -- we are in the case with admit all, we need to read data.ids
                for _,value in pairs(data.ids) do
                    process_promotion_response(room, value, data.approved and 'true' or 'false');
                end
            end
        end

        return true; -- halt processing, but return true that we handled it
    end);

    if always_visitors_enabled then
        local visitorsEnabledField = {
            name = "muc#roominfo_visitorsEnabled";
            type = "boolean";
            label = "Whether visitors are enabled.";
            value = 1;
        };
        -- Append "visitors enabled" to the MUC config form.
        host_module:context(host):hook("muc-disco#info", function(event)
            table.insert(event.form, visitorsEnabledField);
        end);
        host_module:context(host):hook("muc-config-form", function(event)
            table.insert(event.form, visitorsEnabledField);
        end);
    end
end);

prosody.events.add_handler('pre-jitsi-authentication', function(session)
    if not session.customusername or not session.jitsi_web_query_room then
        return nil;
    end

    local room = get_room_by_name_and_subdomain(session.jitsi_web_query_room, session.jitsi_web_query_prefix);
    if not room then
        return nil;
    end

    if visitors_promotion_map[room.jid] and visitors_promotion_map[room.jid][session.customusername] then
        -- user was previously allowed to join, let him use the requested jid
        return session.customusername;
    end
end);
