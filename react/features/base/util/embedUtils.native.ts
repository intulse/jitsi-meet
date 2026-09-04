import { getBundleId } from 'react-native-device-info';

import { IConfig } from '../config/configType';

/**
 * BUndle ids for the Jitsi Meet apps.
 */
const JITSI_MEET_APPS = [

    // iOS app.
    'com.atlassian.JitsiMeet.ios',

    // Android + iOS (testing) app.
    'org.jitsi.meet',

    // Android debug app.
    'org.jitsi.meet.debug'
];

/**
 * Checks whether we are loaded in iframe. In the mobile case we treat SDK
 * consumers as the web treats iframes.
 *
 * @returns {boolean} Whether the current app is a Jitsi Meet app.
 */
export function isEmbedded(): boolean {
    return !JITSI_MEET_APPS.includes(getBundleId());
}

/**
 * React Native has no concept of same-domain embedding. SDK consumers are
 * always treated as cross-domain embeddings.
 *
 * @returns {boolean} Always false in React Native.
 */
export function isEmbeddedFromSameDomain(): boolean {
    return false;
}

/**
 * React Native has no concept of a parent frame hostname to check against
 * config.intulse.embedWhitelist, so this always fails closed.
 *
 * @param {IConfig} _config - Unused; kept for API parity with the web implementation.
 * @returns {boolean} Always false in React Native.
 */
export function isEmbedWhitelisted(_config: IConfig): boolean {
    return false;
}
