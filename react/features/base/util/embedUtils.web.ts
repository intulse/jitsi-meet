import { IConfig } from '../config/configType';

/**
 * Checks whether we are loaded in iframe.
 *
 * @returns {boolean} Whether the current page is loaded in an iframe.
 */
export function isEmbedded(): boolean {
    try {
        return window.self !== window.top;
    } catch (e) {
        return true;
    }
}


/**
 * Checks whether we are loaded in iframe with same parent domain.
 *
 * @returns {boolean} Whether the current page is loaded in an iframe with same parent domain.
 */
export function isEmbeddedFromSameDomain(): boolean {
    try {
        return window.self.location.host === window.parent.location.host;
    } catch (e) {
        return false;
    }
}

/**
 * Extracts the hostname of the parent (embedding) page. Same-origin frames can read it directly
 * off window.parent.location; cross-origin frames can't (the access throws), so we fall back to
 * document.referrer, which is unset if the embedder sends `Referrer-Policy: no-referrer` or the
 * page isn't embedded at all.
 *
 * @returns {string|undefined} The parent frame's hostname, or undefined if it could not be determined.
 */
function _getParentHostname(): string | undefined {
    try {
        return window.parent.location.host;
    } catch (e) {
        // Cross-origin access to window.parent.location throws -- fall through to document.referrer.
    }

    if (document.referrer) {
        try {
            return new URL(document.referrer).host;
        } catch (e) {
            // Malformed referrer.
        }
    }

    return undefined;
}

/**
 * Checks whether the current page is embedded in an iframe whose parent hostname is present in
 * config.intulse.embedWhitelist. Fails closed: a null, undefined, or empty whitelist -- or a
 * parent hostname that could not be determined -- is always treated as not allowed.
 *
 * @param {IConfig} config - The app config.
 * @returns {boolean} Whether the embedding parent's hostname is whitelisted.
 */
export function isEmbedWhitelisted(config: IConfig): boolean {
    const whitelist = config.intulse?.embedWhitelist;

    if (!whitelist || whitelist.length === 0) {
        return false;
    }

    const parentHostname = _getParentHostname();

    if (!parentHostname) {
        return false;
    }

    return whitelist.includes(parentHostname);
}
