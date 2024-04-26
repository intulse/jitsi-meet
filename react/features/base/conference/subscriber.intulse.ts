import { showNotification } from '../../notifications/actions';
import { NOTIFICATION_TIMEOUT_TYPE } from '../../notifications/constants';
import { IStateful } from '../app/types';
import { isLocalParticipantModerator } from '../participants/functions';
import StateListenerRegistry from '../redux/StateListenerRegistry';
import { toState } from '../redux/functions';

/** Instruction to make this work as of stable/jitsi-9364.........
 * Add "import './subscriber.intulse';" in react/features/base/conference/middleware.any.ts
 * ---------------------------------------------------------------------------------------
 * Add notifyOnPasswordChanged to class API in API.js (fix comment styling)
	// >>>>> INTULSE
    // Notify the external application the password has changed
    //
    // @param {string} password - The new password word.
    // @returns {void}
	//
    notifyOnPasswordChanged(password) {
        this._sendEvent({ name: 'password-changed', password });
    }
 * ---------------------------------------------------------------------------------------
 * Add "'password-changed': 'passwordChanged'," to the event object in external_api.js  
 */


/**
 * >>>>> INTULSE
 * Set up listener to notify moderators when the password has changed.
 */
StateListenerRegistry.register(
	state => getPasswordForConference(state),
	(password, { dispatch, getState }, prevPassword) => {
	    if (password && password !== prevPassword && isLocalParticipantModerator(getState())) {
	        if (typeof APP === 'object') {
	            APP.API.notifyOnPasswordChanged(password);
	        }

	        dispatch(showNotification({
	            titleKey: 'INTULSE_PASSCODE_UPDATED',
	            sticky: true,
	            uid: 'INTULSE Password Updated',
	            description: `Password was updated to ==${password}==. Please notify your members of this change.`
	        }, NOTIFICATION_TIMEOUT_TYPE.MEDIUM));
	    }
	});

/**
 * >>>>> INTULSE
 * Returns the current password for the conference.
 *
 * @param {(Function|Object)} stateful - The (whole) redux state, or redux's {@code getState} function to be used to
 * retrieve the state.
 * @returns {string}
 */
export function getPasswordForConference(stateful: IStateful): string | undefined {
    return toState(stateful)['features/base/conference'].password;
}
