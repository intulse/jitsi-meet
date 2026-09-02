-- Loaded on the main MUC component.
--
-- Grants owner affiliation to any participant whose JWT marks them privileged
-- (context.user.affiliation of owner/moderator/teacher), bypassing both the room password and
-- the lobby regardless of how the room is configured. Also applies the meeting's standing
-- configuration -- lobby on/off, and the room password -- from that participant's token.
--
-- Implements: "an owner is admitted immediately, bypassing password and lobby regardless of
-- room settings."
--
-- How the bypass works. The lobby gate in mod_muc_lobby_rooms rejects a joiner only when their
-- affiliation is nil or 'none' (mod_muc_lobby_rooms.lua:642), and prosody's own members_only
-- check admits anything >= member. So granting 'owner' here at priority -2 is sufficient on its
-- own -- no password required. mod_muc_lobby_rooms additionally auto-injects the room password
-- for an already-approved affiliation (:620-625), which covers the lobby+password case.
--
-- The explicit password injection below is still needed for the password-but-no-lobby case:
-- there mod_muc_lobby_rooms returns early at :586 and never injects anything, so prosody's
-- password check would reject the join.
--
-- Hook order this module sits in:
--   0     mod_muc_intulse_mem_join  -- applies the meeting's configured security
--   -2    this module               -- grant owner, inject password
--   -3.5  mod_token_affiliation     -- upstream; also raises occupant.role to 'moderator'
--   -4    mod_muc_lobby_rooms       -- the gate
--   -5    prosody members_only
--
-- Derived from jitsi-contrib mod_token_security_ondemand, which reads a plaintext
-- context.room.password and keys off a context.user.security_bypass flag. Intulse sends an
-- encoded context.room.intulse_cfg instead; decoding it is the intulse/util helper's job.
--
-- Depends on: mod_persistent_lobby, mod_muc_lobby_rooms, mod_token_affiliation, and the
-- intulse/util helper, which is NOT tracked in this repository -- see .gitignore and the
-- deploy runbook for how it reaches the server.
local MUC_NS = 'http://jabber.org/protocol/muc';

local util = module:require 'util';
local is_admin = util.is_admin;
local is_healthcheck_room = util.is_healthcheck_room;
local internal_room_jid_match_rewrite = util.internal_room_jid_match_rewrite;

local intulse_util = module:require 'intulse/util';
local is_privileged_user = intulse_util.is_privileged_user;
local get_room_password = intulse_util.get_room_password;

-- True when this session should be treated as a meeting owner.
local function is_privileged_session(session)
    return session and session.auth_token and is_privileged_user(session.jitsi_meet_context_user);
end

module:hook('muc-occupant-pre-join', function (event)
    local room, occupant, session, stanza = event.room, event.occupant, event.origin, event.stanza;

    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        return;
    end

    if not is_privileged_session(session) then
        return;
    end

    -- This single line is the whole of requirement 2: an 'owner' affiliation satisfies the
    -- lobby gate at -4 and members_only at -5, whether or not the room has a password or a
    -- lobby. Deliberately NOT conditional on intulse_cfg -- a moderator whose token carries no
    -- password must still get straight in.
    room:set_affiliation(true, occupant.bare_jid, 'owner');
    module:log('debug', 'INTULSE granted owner to %s in %s', occupant.bare_jid, room.jid);

    -- Password-but-no-lobby: mod_muc_lobby_rooms returns early when the room is not
    -- members_only, so nothing else will supply the password on our behalf.
    local context_room = session.jitsi_meet_context_room;
    local password, err = get_room_password(module, context_room and context_room.intulse_cfg);

    if err then
        -- Log and carry on: the affiliation grant above already admits them, and failing the
        -- join over an unreadable claim would be worse than ignoring it.
        module:log('error', 'INTULSE %s: %s', room.jid, err);

        return;
    end

    if not password then
        return;
    end

    local join = stanza:get_child('x', MUC_NS);

    if not join then
        stanza:tag('x', { xmlns = MUC_NS }):up();
        join = stanza:get_child('x', MUC_NS);
    end

    if join and not join:get_child_text('password', MUC_NS) then
        join:tag('password', { xmlns = MUC_NS }):text(password):up();
    end
end, -2);

-- Applies the meeting's standing configuration once an owner is actually in the room.
--
-- This is the counterpart to mod_muc_intulse_mem_join. That module only ever switches security
-- on, because releasing people already waiting in a lobby is a decision that needs an owner
-- present. This hook is where that decision is taken: an owner's token can turn the lobby off
-- again, subject to the room keeping at least a password.
module:hook('muc-occupant-joined', function (event)
    local room, occupant, session = event.room, event.occupant, event.origin;

    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        return;
    end

    if not is_privileged_session(session) then
        return;
    end

    local context_room = session.jitsi_meet_context_room;

    if not context_room then
        return;
    end

    -- Password FIRST, before any lobby decision. The guard on disabling the lobby below asks
    -- whether the room still has a password, so the token's password has to be in place by
    -- then -- otherwise a legitimate "lobby off, password on" meeting would look like "no
    -- security at all" and the lobby would be kept by mistake.
    local password, err = get_room_password(module, context_room.intulse_cfg);
    local intulse_lobby = context_room.lobby;
    if err then
        module:log('error', 'INTULSE %s: %s', room.jid, err);
    elseif password and room:get_password() ~= password then
        module:log('info', 'INTULSE setting password from token for %s', room.jid);
        room:set_password(password);
    end

    local lobby_enabled =  intulse_lobby or room._data.lobbyroom ~= nil;

    -- Both events are registered with module:hook_global (mod_persistent_lobby.lua:181,
    -- mod_muc_lobby_rooms.lua:754), so they must be fired on prosody.events rather than on a
    -- host module context.
    if context_room.lobby == true and not lobby_enabled then
        module:log('info', 'INTULSE enabling lobby for %s', room.jid);
        prosody.events.fire_event('create-persistent-lobby-room', {
            room = room;
            reason = 'meeting-configuration',
            skip_display_name_check = true;
        });
    elseif context_room.lobby == false and lobby_enabled then
        -- Disabling the lobby is the owner's call, but an Intulse meeting is never allowed to
        -- end up with neither a lobby nor a password. Removing the lobby from a room that has
        -- no password would leave it open to anyone with the room name, so refuse and keep the
        -- lobby -- failing closed is the right direction here.
        local existing_password = room:get_password();

        if existing_password == nil or existing_password == '' then
            module:log('warn',
                'INTULSE refusing to disable the lobby for %s: the room has no password, and a '
                    .. 'meeting must keep at least one of the two', room.jid);
        else
            module:log('info', 'INTULSE disabling lobby for %s', room.jid);
            room:set_members_only(false);
            prosody.events.fire_event('destroy-lobby-room', {
                room = room,
                newjid = internal_room_jid_match_rewrite(room.jid),
            });
        end
    end

end);
