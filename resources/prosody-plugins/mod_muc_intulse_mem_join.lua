-- Loaded on the main MUC component.
--
-- Applies a meeting's configured security -- lobby and/or password -- from the JWT, so that a
-- non-privileged participant cannot slip into a room before it has been secured.
--
-- Why this is needed at all: jicofo creates the MUC empty and unsecured, while the meeting's
-- lobby flag and password live in the token. mod_intulse_owner_join applies them when an owner
-- joins, but if a plain member is the first to arrive there is no owner yet and the room would
-- otherwise be wide open. This module closes that window.
--
-- Behaviour contract:
--   * Every Intulse meeting is configured with a lobby, a password, or both -- the application
--     does not permit a meeting with neither.
--   * owner / moderator / teacher bypass both. That is mod_intulse_owner_join's job (pre-join,
--     priority -2), not this module's, so privileged sessions are skipped here entirely.
--   * Everyone else joins as member/participant and must supply the password or wait in the
--     lobby. Both routes are offered by mod_muc_lobby_rooms' gate; the client shows a password
--     field inside the lobby when securityUi.disableLobbyPassword is false.
--
-- This module never removes security. It does not tear a lobby down, and it does not overwrite
-- an existing password -- see apply_room_security below for why both matter.
--
-- Hook order:
--   0     this module               -- ensure the room is secured
--   -2    mod_intulse_owner_join    -- grant owner, inject password (privileged only)
--   -3.5  mod_token_affiliation     -- upstream; owner/member from JWT claims
--   -4    mod_muc_lobby_rooms       -- the gate: 407 unless affiliation >= member
--   -5    prosody members_only + password check
--
-- Depends on: mod_persistent_lobby (main VirtualHost), mod_muc_lobby_rooms (MUC component).
local util = module:require 'util';
local is_admin = util.is_admin;
local is_healthcheck_room = util.is_healthcheck_room;
local process_host_module = util.process_host_module;

local intulse_util = module:require 'intulse/util';
local is_privileged_user = intulse_util.is_privileged_user;
local get_room_password = intulse_util.get_room_password;

local muc_domain_base = module:get_option_string('muc_mapper_domain_base');
if not muc_domain_base then
    module:log('warn', "No 'muc_mapper_domain_base' option set, disabling module");
    return
end

local lobby_muc_component_config = 'lobby.' .. muc_domain_base;
local lobby_component_loaded = false;

-- Applies the meeting's configured security from this participant's token.
local function apply_room_security(room, session)
    local context_room = session.jitsi_meet_context_room;

    if not context_room then
        return;
    end

    local lobby_enabled = room._data.lobbyroom ~= nil;
    local existing_password = room:get_password();
    local has_password = existing_password ~= nil and existing_password ~= '';

    -- Lobby. Only ever switched on. context.room.lobby == false is not treated as "remove the
    -- lobby": tearing one down from a member's join would release everyone waiting in it
    -- without a moderator admitting them. Disabling a lobby is mod_intulse_owner_join's
    -- decision, taken when an owner is actually present.
    if context_room.lobby == true and not lobby_enabled then
        if lobby_component_loaded then
            module:log('info', 'INTULSE enabling lobby for %s', room.jid);
            prosody.events.fire_event('create-persistent-lobby-room', {
                room = room;
                reason = 'meeting-configuration',
                skip_display_name_check = true;
            });
            lobby_enabled = true;
        else
            -- Fail loudly: without the lobby component the create event is a no-op and this
            -- participant would walk straight into an unsecured room.
            module:log('error',
                'INTULSE lobby requested for %s but the lobby component is not loaded', room.jid);
        end
    end

    -- Password. Written only when the room does not already have one. Re-applying on every
    -- join would let a participant holding an older token roll back a password the moderator
    -- had since changed by hand -- the change Phase 5's password-changed event exists to
    -- broadcast.
    if not has_password then
        local password, err = get_room_password(module, context_room.intulse_cfg);

        if err then
            module:log('error', 'INTULSE %s: %s', room.jid, err);
        elseif password then
            module:log('info', 'INTULSE setting password from token for %s', room.jid);
            room:set_password(password);
            has_password = true;
        end
    end

    -- Every meeting is supposed to carry a lobby or a password. If one arrives with neither,
    -- this participant is about to enter an open room -- worth knowing about.
    if not lobby_enabled and not has_password then
        module:log('warn',
            'INTULSE %s has neither lobby nor password; %s will join unchallenged',
            room.jid, session.jitsi_meet_context_user and 'a member' or 'an anonymous user');
    end
end

module:hook('muc-occupant-pre-join', function (event)
    local room, occupant, session = event.room, event.occupant, event.origin;

    -- Ignore jicofo and the healthcheck room.
    if is_admin(occupant.bare_jid) or is_healthcheck_room(room.jid) then
        return;
    end

    -- Privileged sessions are mod_intulse_owner_join's business. Skipping them here also means
    -- an owner's token never reconfigures the room from this hook -- that happens on their
    -- muc-occupant-joined, once they are actually in.
    if session.auth_token and is_privileged_user(session.jitsi_meet_context_user) then
        return;
    end

    apply_room_security(room, session);
end);

process_host_module(lobby_muc_component_config, function(host_module, host)
    module:log('info', 'Lobby component loaded %s', host);
    lobby_component_loaded = true;
end);
