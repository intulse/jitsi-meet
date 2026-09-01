import { showNotification } from '../../notifications/actions';
import { NOTIFICATION_TIMEOUT_TYPE } from '../../notifications/constants';
import { IStateful } from '../app/types';
import { isLocalParticipantModerator } from '../participants/functions';
import StateListenerRegistry from '../redux/StateListenerRegistry';
import { toState } from '../redux/functions';

/**
 * Returns the current password for the conference.
 *
 * @param {IStateful} stateful - The (whole) redux state, or redux's {@code getState} function to
 * be used to retrieve the state.
 * @returns {string|undefined}
 */
export function getPasswordForConference(stateful: IStateful): string | undefined {
    return toState(stateful)['features/base/conference'].password;
}

/**
 * Notifies the embedding application, and the local moderator, whenever the conference password
 * changes.
 *
 * The {@code password-changed} external API event raised here is consumed by the Intulse
 * Meetings frontend, which persists the new value against the meeting record. Without this
 * listener that handler never fires and the stored passcode silently drifts from the live one.
 *
 * Only moderators are notified: a non-moderator cannot relay a passcode they were not given, and
 * the local participant is the only one able to act on it.
 */
StateListenerRegistry.register(
    state => getPasswordForConference(state),
    (password, { dispatch, getState }, prevPassword) => {
        if (!password || password === prevPassword || !isLocalParticipantModerator(getState())) {
            return;
        }

        if (typeof APP === 'object') {
            APP.API.notifyOnPasswordChanged(password);
        }

        // Sticky: the moderator has to read the new passcode and pass it on, so this must not
        // time out from under them.
        dispatch(showNotification({
            descriptionArguments: { password },
            descriptionKey: 'notify.intulsePasscodeUpdatedDescription',
            titleKey: 'notify.intulsePasscodeUpdated',
            uid: 'intulse.passcode.updated'
        }, NOTIFICATION_TIMEOUT_TYPE.STICKY));
    });
