import { CONFERENCE_WILL_LEAVE } from '../base/conference/actionTypes';
import ReducerRegistry from '../base/redux/ReducerRegistry';

import {
    CLEAR_VISITOR_PROMOTION_REQUEST,
    I_AM_VISITOR_MODE,
    SET_VISITORS_SUPPORTED,
    SET_VISITOR_DEMOTE_ACTOR,
    UPDATE_VISITORS_COUNT,
    VISITOR_PROMOTION_REQUEST
} from './actionTypes';
import { IPromotionRequest } from './types';

const DEFAULT_STATE = {
    count: -1,
    iAmVisitor: false,
    showNotification: false,
    supported: false,
    promotionRequests: []
};

export interface IVisitorsState {
    count?: number;
    demoteActorDisplayName?: string;
    iAmVisitor: boolean;
    promotionRequests: IPromotionRequest[];
    supported: boolean;
}
ReducerRegistry.register<IVisitorsState>('features/visitors', (state = DEFAULT_STATE, action): IVisitorsState => {
    switch (action.type) {
    case CONFERENCE_WILL_LEAVE: {
        return {
            ...state,
            ...DEFAULT_STATE
        };
    }
    case UPDATE_VISITORS_COUNT: {
        if (state.count === action.count) {
            return state;
        }

        return {
            ...state,
            count: action.count
        };
    }
    case I_AM_VISITOR_MODE: {
        return {
            ...state,
            iAmVisitor: action.enabled
        };
    }
    case SET_VISITOR_DEMOTE_ACTOR: {
        return {
            ...state,
            demoteActorDisplayName: action.displayName
        };
    }
    case SET_VISITORS_SUPPORTED: {
        return {
            ...state,
            supported: action.value
        };
    }
    case VISITOR_PROMOTION_REQUEST: {
        const currentRequests = state.promotionRequests || [];

        return {
            ...state,
            promotionRequests: [ ...currentRequests, action.request ]
        };
    }

    return state;
});
