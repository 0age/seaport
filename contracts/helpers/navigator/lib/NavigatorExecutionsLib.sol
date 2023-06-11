// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    ConsiderationInterface
} from "seaport-types/src/interfaces/ConsiderationInterface.sol";

import {
    AdvancedOrder,
    Execution,
    SpentItem,
    ReceivedItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import { ItemType } from "seaport-types/src/lib/ConsiderationEnums.sol";

import {
    FulfillmentDetails
} from "seaport-sol/src/fulfillments/lib/Structs.sol";

import {
    ExecutionHelper
} from "seaport-sol/src/executions/ExecutionHelper.sol";

import { UnavailableReason } from "seaport-sol/src/SpaceEnums.sol";

import { OrderDetails } from "seaport-sol/src/fulfillments/lib/Structs.sol";

import { Family, Structure, OrderStructureLib } from "./OrderStructureLib.sol";

import { NavigatorContext } from "./SeaportNavigatorTypes.sol";

library NavigatorExecutionsLib {
    using ExecutionHelper for FulfillmentDetails;
    using OrderStructureLib for AdvancedOrder[];

    /**
     * @dev Bad request error: provided orders cannot be fulfilled.
     */
    error CannotFulfillProvidedCombinedOrder();

    /**
     * @dev Bad request error: provided orders include an invalid combination of
     *      native tokens and unavailable orders.
     */
    error InvalidNativeTokenUnavailableCombination();

    /**
     * @dev Internal error: Could not select a fulfillment method for the provided
     *      orders.
     */
    error UnknownAction();

    /**
     * @dev Internal error: Could not find selector for the suggested action.
     */
    error UnknownSelector();

    /**
     * @dev Calculate executions for the provided orders and add them to the
     *      NavigatorResponse.
     */
    function withExecutions(
        NavigatorContext memory context
    ) internal pure returns (NavigatorContext memory) {
        bytes4 _suggestedAction = context.response.suggestedAction;
        FulfillmentDetails memory fulfillmentDetails = FulfillmentDetails({
            orders: context.response.orderDetails,
            recipient: payable(context.request.recipient),
            fulfiller: payable(context.request.caller),
            nativeTokensSupplied: context.request.nativeTokensSupplied,
            fulfillerConduitKey: context.request.fulfillerConduitKey,
            seaport: address(context.request.seaport)
        });

        Execution[] memory explicitExecutions;
        Execution[] memory implicitExecutions;
        Execution[] memory implicitExecutionsPre;
        Execution[] memory implicitExecutionsPost;
        uint256 nativeTokensReturned;

        if (
            _suggestedAction ==
            ConsiderationInterface.fulfillAvailableOrders.selector ||
            _suggestedAction ==
            ConsiderationInterface.fulfillAvailableAdvancedOrders.selector
        ) {
            (
                explicitExecutions,
                implicitExecutionsPre,
                implicitExecutionsPost,
                nativeTokensReturned
            ) = fulfillmentDetails.getFulfillAvailableExecutions(
                context.response.offerFulfillments,
                context.response.considerationFulfillments,
                context.response.orderDetails
            );
        } else if (
            _suggestedAction == ConsiderationInterface.matchOrders.selector ||
            _suggestedAction ==
            ConsiderationInterface.matchAdvancedOrders.selector
        ) {
            (
                explicitExecutions,
                implicitExecutionsPre,
                implicitExecutionsPost,
                nativeTokensReturned
            ) = fulfillmentDetails.getMatchExecutions(
                context.response.fulfillments
            );
        } else if (
            _suggestedAction == ConsiderationInterface.fulfillOrder.selector ||
            _suggestedAction ==
            ConsiderationInterface.fulfillAdvancedOrder.selector
        ) {
            (implicitExecutions, nativeTokensReturned) = fulfillmentDetails
                .getStandardExecutions();
        } else if (
            _suggestedAction ==
            ConsiderationInterface.fulfillBasicOrder.selector ||
            _suggestedAction ==
            ConsiderationInterface.fulfillBasicOrder_efficient_6GL6yc.selector
        ) {
            (implicitExecutions, nativeTokensReturned) = fulfillmentDetails
                .getBasicExecutions();
        } else {
            revert UnknownAction();
        }
        context.response.explicitExecutions = explicitExecutions;
        context.response.implicitExecutions = implicitExecutions;
        context.response.implicitExecutionsPre = implicitExecutionsPre;
        context.response.implicitExecutionsPost = implicitExecutionsPost;
        context.response.nativeTokensReturned = nativeTokensReturned;
        return context;
    }

    /**
     * @dev Choose a suggested fulfillment method based on the structure of the
     *      orders and add it to the NavigatorResponse.
     */
    function withSuggestedAction(
        NavigatorContext memory context
    ) internal view returns (NavigatorContext memory) {
        context.response.suggestedAction = action(context);
        context.response.suggestedActionName = actionName(context);
        return context;
    }

    /**
     * @dev Add the human-readable name of the selected fulfillment method to
     *      the NavigatorResponse.
     */
    function actionName(
        NavigatorContext memory context
    ) internal view returns (string memory) {
        bytes4 selector = action(context);
        if (selector == 0xe7acab24) return "fulfillAdvancedOrder";
        if (selector == 0x87201b41) return "fulfillAvailableAdvancedOrders";
        if (selector == 0xed98a574) return "fulfillAvailableOrders";
        if (selector == 0xfb0f3ee1) return "fulfillBasicOrder";
        if (selector == 0x00000000) return "fulfillBasicOrder_efficient_6GL6yc";
        if (selector == 0xb3a34c4c) return "fulfillOrder";
        if (selector == 0xf2d12b12) return "matchAdvancedOrders";
        if (selector == 0xa8174404) return "matchOrders";

        revert UnknownSelector();
    }

    /**
     * @dev Choose a suggested fulfillment method based on the structure of the
     *      orders.
     */
    function action(
        NavigatorContext memory context
    ) internal view returns (bytes4) {
        Family family = context.response.orders.getFamily();

        bool invalidOfferItemsLocated = mustUseMatch(context);

        Structure structure = context.response.orders.getStructure(
            address(context.request.seaport)
        );

        bool hasUnavailable = context.request.maximumFulfilled <
            context.response.orders.length;
        for (uint256 i = 0; i < context.response.orderDetails.length; ++i) {
            if (
                context.response.orderDetails[i].unavailableReason !=
                UnavailableReason.AVAILABLE
            ) {
                hasUnavailable = true;
                break;
            }
        }

        if (hasUnavailable) {
            if (invalidOfferItemsLocated) {
                revert InvalidNativeTokenUnavailableCombination();
            }

            if (structure == Structure.ADVANCED) {
                return
                    ConsiderationInterface
                        .fulfillAvailableAdvancedOrders
                        .selector;
            } else {
                return ConsiderationInterface.fulfillAvailableOrders.selector;
            }
        }

        if (family == Family.SINGLE && !invalidOfferItemsLocated) {
            if (structure == Structure.BASIC) {
                return
                    ConsiderationInterface
                        .fulfillBasicOrder_efficient_6GL6yc
                        .selector;
            }

            if (structure == Structure.STANDARD) {
                return ConsiderationInterface.fulfillOrder.selector;
            }

            if (structure == Structure.ADVANCED) {
                return ConsiderationInterface.fulfillAdvancedOrder.selector;
            }
        }

        bool cannotMatch = (context
            .response
            .unmetConsiderationComponents
            .length !=
            0 ||
            hasUnavailable);

        if (cannotMatch && invalidOfferItemsLocated) {
            revert CannotFulfillProvidedCombinedOrder();
        }

        if (cannotMatch) {
            if (structure == Structure.ADVANCED) {
                return
                    ConsiderationInterface
                        .fulfillAvailableAdvancedOrders
                        .selector;
            } else {
                return ConsiderationInterface.fulfillAvailableOrders.selector;
            }
        } else if (invalidOfferItemsLocated) {
            if (structure == Structure.ADVANCED) {
                return ConsiderationInterface.matchAdvancedOrders.selector;
            } else {
                return ConsiderationInterface.matchOrders.selector;
            }
        } else {
            if (structure == Structure.ADVANCED) {
                return
                    context.request.preferMatch
                        ? ConsiderationInterface.matchAdvancedOrders.selector
                        : ConsiderationInterface
                            .fulfillAvailableAdvancedOrders
                            .selector;
            } else {
                return
                    context.request.preferMatch
                        ? ConsiderationInterface.matchOrders.selector
                        : ConsiderationInterface
                            .fulfillAvailableOrders
                            .selector;
            }
        }
    }

    /**
     * @dev Return whether the provided orders must be matched using matchOrders
     *      or matchAdvancedOrders.
     */
    function mustUseMatch(
        NavigatorContext memory context
    ) internal pure returns (bool) {
        OrderDetails[] memory orders = context.response.orderDetails;

        for (uint256 i = 0; i < orders.length; ++i) {
            OrderDetails memory order = orders[i];

            if (order.isContract) {
                continue;
            }

            for (uint256 j = 0; j < order.offer.length; ++j) {
                if (order.offer[j].itemType == ItemType.NATIVE) {
                    return true;
                }
            }
        }

        if (context.request.caller == context.request.recipient) {
            return false;
        }

        for (uint256 i = 0; i < orders.length; ++i) {
            OrderDetails memory order = orders[i];

            for (uint256 j = 0; j < order.offer.length; ++j) {
                SpentItem memory item = order.offer[j];

                if (item.itemType != ItemType.ERC721) {
                    continue;
                }

                for (uint256 k = 0; k < orders.length; ++k) {
                    OrderDetails memory comparisonOrder = orders[k];
                    for (
                        uint256 l = 0;
                        l < comparisonOrder.consideration.length;
                        ++l
                    ) {
                        ReceivedItem memory considerationItem = comparisonOrder
                            .consideration[l];

                        if (
                            considerationItem.itemType == ItemType.ERC721 &&
                            considerationItem.identifier == item.identifier &&
                            considerationItem.token == item.token
                        ) {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }
}