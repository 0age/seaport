// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { LibPRNG } from "solady/src/utils/LibPRNG.sol";

import {
    AdvancedOrdersSpace,
    OrderComponentsSpace,
    OfferItemSpace,
    ConsiderationItemSpace
} from "seaport-sol/StructSpace.sol";
import {
    BroadOrderType,
    TokenIndex,
    Amount,
    Recipient,
    Criteria,
    Offerer,
    Time,
    Zone,
    ZoneHash,
    SignatureMethod
} from "seaport-sol/SpaceEnums.sol";
import { ItemType, OrderType } from "seaport-sol/SeaportEnums.sol";

import "seaport-sol/SeaportSol.sol";

import { TestERC1155 } from "../../../../contracts/test/TestERC1155.sol";
import { TestERC20 } from "../../../../contracts/test/TestERC20.sol";
import { TestERC721 } from "../../../../contracts/test/TestERC721.sol";

import { Vm } from "forge-std/Vm.sol";

import "forge-std/console.sol";

uint256 constant UINT256_MAX = type(uint256).max;

// @dev Implementation cribbed from forge-std bound
function bound(
    uint256 x,
    uint256 min,
    uint256 max
) pure returns (uint256 result) {
    require(min <= max, "Max is less than min.");
    // If x is between min and max, return x directly. This is to ensure that dictionary values
    // do not get shifted if the min is nonzero.
    if (x >= min && x <= max) return x;

    uint256 size = max - min + 1;

    // If the value is 0, 1, 2, 3, warp that to min, min+1, min+2, min+3. Similarly for the UINT256_MAX side.
    // This helps ensure coverage of the min/max values.
    if (x <= 3 && size > x) return min + x;
    if (x >= UINT256_MAX - 3 && size > UINT256_MAX - x)
        return max - (UINT256_MAX - x);

    // Otherwise, wrap x into the range [min, max], i.e. the range is inclusive.
    if (x > max) {
        uint256 diff = x - max;
        uint256 rem = diff % size;
        if (rem == 0) return max;
        result = min + rem - 1;
    } else if (x < min) {
        uint256 diff = min - x;
        uint256 rem = diff % size;
        if (rem == 0) return min;
        result = max - rem + 1;
    }
}

struct GeneratorContext {
    Vm vm;
    LibPRNG.PRNG prng;
    uint256 timestamp;
    SeaportInterface seaport;
    TestERC20[] erc20s;
    TestERC721[] erc721s;
    TestERC1155[] erc1155s;
    address self;
    address offerer;
    address recipient;
    address alice;
    address bob;
    address dillon;
    address eve;
    address frank;
    uint256 offererPk;
    uint256 alicePk;
    uint256 bobPk;
    uint256 dillonPk;
    uint256 frankPk;
    uint256 evePk;
    uint256 starting721offerIndex;
    uint256 starting721considerationIndex;
    uint256[] potential1155TokenIds;
    bytes32[] orderHashes;
}

library TestStateGenerator {
    using PRNGHelpers for GeneratorContext;

    function generate(
        uint256 totalOrders,
        uint256 maxOfferItemsPerOrder,
        uint256 maxConsiderationItemsPerOrder,
        GeneratorContext memory context
    ) internal pure returns (AdvancedOrdersSpace memory) {
        OrderComponentsSpace[] memory components = new OrderComponentsSpace[](
            totalOrders
        );
        for (uint256 i; i < totalOrders; ++i) {
            components[i] = OrderComponentsSpace({
                // TODO: Restricted range to 1 and 2 to avoid test contract.
                //       Range should be 0-2.
                offerer: Offerer(context.randEnum(1, 2)),
                zone: Zone(context.randEnum(0, 2)),
                offer: generateOffer(maxOfferItemsPerOrder, context),
                consideration: generateConsideration(
                    maxConsiderationItemsPerOrder,
                    context
                ),
                orderType: BroadOrderType(context.randEnum(0, 2)),
                // TODO: Restricted range to 1 and 2 to avoid unavailable.
                //       Range should be 0-4.
                time: Time(context.randEnum(1, 2)),
                zoneHash: ZoneHash(context.randEnum(0, 2)),
                // TODO: Add more signature methods (restricted to EOA for now)
                signatureMethod: SignatureMethod(0)
            });
        }
        return AdvancedOrdersSpace({ orders: components });
    }

    function generateOffer(
        uint256 maxOfferItemsPerOrder,
        GeneratorContext memory context
    ) internal pure returns (OfferItemSpace[] memory) {
        uint256 len = context.randRange(0, maxOfferItemsPerOrder);
        OfferItemSpace[] memory offer = new OfferItemSpace[](len);
        for (uint256 i; i < len; ++i) {
            offer[i] = OfferItemSpace({
                // TODO: Native items + criteria - should be 0-5
                itemType: ItemType(context.randEnum(1, 3)),
                tokenIndex: TokenIndex(context.randEnum(0, 2)),
                criteria: Criteria(context.randEnum(0, 2)),
                amount: Amount(context.randEnum(0, 2))
            });
        }
        return offer;
    }

    function generateConsideration(
        uint256 maxConsiderationItemsPerOrder,
        GeneratorContext memory context
    ) internal pure returns (ConsiderationItemSpace[] memory) {
        // TODO: Can we handle zero?
        uint256 len = context.randRange(1, maxConsiderationItemsPerOrder);
        ConsiderationItemSpace[]
            memory consideration = new ConsiderationItemSpace[](len);
        for (uint256 i; i < len; ++i) {
            consideration[i] = ConsiderationItemSpace({
                // TODO: Native items + criteria - should be 0-5
                itemType: ItemType(context.randEnum(1, 3)),
                tokenIndex: TokenIndex(context.randEnum(0, 2)),
                criteria: Criteria(context.randEnum(0, 2)),
                amount: Amount(context.randEnum(0, 2)),
                recipient: Recipient(context.randEnum(0, 4))
            });
        }
        return consideration;
    }
}

library AdvancedOrdersSpaceGenerator {
    using OrderLib for Order;
    using SignatureGenerator for Order;
    using OrderParametersLib for OrderParameters;
    using AdvancedOrderLib for AdvancedOrder;

    using OrderComponentsSpaceGenerator for OrderComponentsSpace;

    function generate(
        AdvancedOrdersSpace memory space,
        GeneratorContext memory context
    ) internal view returns (AdvancedOrder[] memory) {
        uint256 len = bound(space.orders.length, 0, 10);
        AdvancedOrder[] memory orders = new AdvancedOrder[](len);
        context.orderHashes = new bytes32[](len);

        for (uint256 i; i < len; ++i) {
            OrderParameters memory orderParameters = space.orders[i].generate(
                context
            );
            Order memory order = OrderLib.empty().withParameters(
                orderParameters
            );
            bytes32 orderHash;
            {
                uint256 counter = context.seaport.getCounter(
                    order.parameters.offerer
                );
                orderHash = context.seaport.getOrderHash(
                    orderParameters.toOrderComponents(counter)
                );

                context.orderHashes[i] = orderHash;
            }

            orders[i] = order
                .withGeneratedSignature(
                    space.orders[i].signatureMethod,
                    space.orders[i].offerer,
                    orderHash,
                    context
                )
                .toAdvancedOrder({
                    numerator: 0,
                    denominator: 0,
                    extraData: bytes("")
                });
        }
        return orders;
    }
}

library OrderComponentsSpaceGenerator {
    using OrderParametersLib for OrderParameters;
    using TimeGenerator for OrderParameters;
    using OffererGenerator for Offerer;

    using OfferItemSpaceGenerator for OfferItemSpace[];
    using ConsiderationItemSpaceGenerator for ConsiderationItemSpace[];

    function generate(
        OrderComponentsSpace memory space,
        GeneratorContext memory context
    ) internal pure returns (OrderParameters memory) {
        return
            OrderParametersLib
                .empty()
                .withOfferer(space.offerer.generate(context))
                .withOffer(space.offer.generate(context))
                .withConsideration(space.consideration.generate(context))
                .withGeneratedTime(space.time, context);
        // TODO: Zone generator
    }
}

library OfferItemSpaceGenerator {
    using TokenIndexGenerator for TokenIndex;
    using AmountGenerator for OfferItem;
    using CriteriaGenerator for OfferItem;

    using OfferItemLib for OfferItem;

    function generate(
        OfferItemSpace[] memory space,
        GeneratorContext memory context
    ) internal pure returns (OfferItem[] memory) {
        uint256 len = bound(space.length, 0, 10);

        OfferItem[] memory offerItems = new OfferItem[](len);

        for (uint256 i; i < len; ++i) {
            offerItems[i] = generate(space[i], context);
        }
        return offerItems;
    }

    function generate(
        OfferItemSpace memory space,
        GeneratorContext memory context
    ) internal pure returns (OfferItem memory) {
        return
            OfferItemLib
                .empty()
                .withItemType(space.itemType)
                .withToken(space.tokenIndex.generate(space.itemType, context))
                .withGeneratedAmount(space.amount, context)
                .withGeneratedIdentifierOrCriteria(
                    space.itemType,
                    space.criteria,
                    context
                );
    }
}

library ConsiderationItemSpaceGenerator {
    using TokenIndexGenerator for TokenIndex;
    using RecipientGenerator for Recipient;
    using AmountGenerator for ConsiderationItem;
    using CriteriaGenerator for ConsiderationItem;

    using ConsiderationItemLib for ConsiderationItem;

    function generate(
        ConsiderationItemSpace[] memory space,
        GeneratorContext memory context
    ) internal pure returns (ConsiderationItem[] memory) {
        uint256 len = bound(space.length, 0, 10);

        ConsiderationItem[] memory considerationItems = new ConsiderationItem[](
            len
        );

        for (uint256 i; i < len; ++i) {
            considerationItems[i] = generate(space[i], context);
        }
        return considerationItems;
    }

    function generate(
        ConsiderationItemSpace memory space,
        GeneratorContext memory context
    ) internal pure returns (ConsiderationItem memory) {
        return
            ConsiderationItemLib
                .empty()
                .withItemType(space.itemType)
                .withToken(space.tokenIndex.generate(space.itemType, context))
                .withGeneratedAmount(space.amount, context)
                .withRecipient(space.recipient.generate(context))
                .withGeneratedIdentifierOrCriteria(
                    space.itemType,
                    space.criteria,
                    context
                );
    }
}

library SignatureGenerator {
    using OffererGenerator for Offerer;
    using OrderLib for Order;

    function withGeneratedSignature(
        Order memory order,
        SignatureMethod method,
        Offerer offerer,
        bytes32 orderHash,
        GeneratorContext memory context
    ) internal view returns (Order memory) {
        if (method == SignatureMethod.EOA) {
            (, bytes32 domainSeparator, ) = context.seaport.information();
            (uint8 v, bytes32 r, bytes32 s) = context.vm.sign(
                offerer.getKey(context),
                keccak256(
                    abi.encodePacked(bytes2(0x1901), domainSeparator, orderHash)
                )
            );
            bytes memory signature = abi.encodePacked(r, s, v);
            return order.withSignature(signature);
        }
        revert("SignatureGenerator: Invalid signature method");
    }
}

library TokenIndexGenerator {
    function generate(
        TokenIndex tokenIndex,
        ItemType itemType,
        GeneratorContext memory context
    ) internal pure returns (address) {
        uint256 i = uint8(tokenIndex);

        // TODO: missing native tokens
        if (itemType == ItemType.ERC20) {
            return address(context.erc20s[i]);
        } else if (itemType == ItemType.ERC721) {
            return address(context.erc721s[i]);
        } else if (itemType == ItemType.ERC1155) {
            return address(context.erc1155s[i]);
        } else {
            revert("TokenIndexGenerator: Invalid itemType");
        }
    }
}

library TimeGenerator {
    using LibPRNG for LibPRNG.PRNG;
    using OrderParametersLib for OrderParameters;

    function withGeneratedTime(
        OrderParameters memory order,
        Time time,
        GeneratorContext memory context
    ) internal pure returns (OrderParameters memory) {
        uint256 low;
        uint256 high;

        if (time == Time.STARTS_IN_FUTURE) {
            uint256 a = bound(
                context.prng.next(),
                context.timestamp + 1,
                type(uint256).max
            );
            uint256 b = bound(
                context.prng.next(),
                context.timestamp + 1,
                type(uint256).max
            );
            low = a < b ? a : b;
            high = a > b ? a : b;
        }
        if (time == Time.EXACT_START) {
            low = context.timestamp;
            high = bound(
                context.prng.next(),
                context.timestamp + 1,
                type(uint256).max
            );
        }
        if (time == Time.ONGOING) {
            low = bound(context.prng.next(), 0, context.timestamp - 1);
            high = bound(
                context.prng.next(),
                context.timestamp + 1,
                type(uint256).max
            );
        }
        if (time == Time.EXACT_END) {
            low = bound(context.prng.next(), 0, context.timestamp - 1);
            high = context.timestamp;
        }
        if (time == Time.EXPIRED) {
            uint256 a = bound(context.prng.next(), 0, context.timestamp - 1);
            uint256 b = bound(context.prng.next(), 0, context.timestamp - 1);
            low = a < b ? a : b;
            high = a > b ? a : b;
        }
        return order.withStartTime(low).withEndTime(high);
    }
}

library AmountGenerator {
    using LibPRNG for LibPRNG.PRNG;
    using OfferItemLib for OfferItem;
    using ConsiderationItemLib for ConsiderationItem;

    function withGeneratedAmount(
        OfferItem memory item,
        Amount amount,
        GeneratorContext memory context
    ) internal pure returns (OfferItem memory) {
        uint256 a = context.prng.next();
        uint256 b = context.prng.next();

        uint256 high = a > b ? a : b;
        uint256 low = a < b ? a : b;

        if (amount == Amount.FIXED) {
            return item.withStartAmount(high).withEndAmount(high);
        }
        if (amount == Amount.ASCENDING) {
            return item.withStartAmount(low).withEndAmount(high);
        }
        if (amount == Amount.DESCENDING) {
            return item.withStartAmount(high).withEndAmount(low);
        }
        return item;
    }

    function withGeneratedAmount(
        ConsiderationItem memory item,
        Amount amount,
        GeneratorContext memory context
    ) internal pure returns (ConsiderationItem memory) {
        uint256 a = context.prng.next();
        uint256 b = context.prng.next();

        uint256 high = a > b ? a : b;
        uint256 low = a < b ? a : b;

        if (amount == Amount.FIXED) {
            return item.withStartAmount(high).withEndAmount(high);
        }
        if (amount == Amount.ASCENDING) {
            return item.withStartAmount(low).withEndAmount(high);
        }
        if (amount == Amount.DESCENDING) {
            return item.withStartAmount(high).withEndAmount(low);
        }
        return item;
    }
}

library RecipientGenerator {
    using LibPRNG for LibPRNG.PRNG;

    function generate(
        Recipient recipient,
        GeneratorContext memory context
    ) internal pure returns (address) {
        if (recipient == Recipient.OFFERER) {
            return context.offerer;
        } else if (recipient == Recipient.RECIPIENT) {
            return context.recipient;
        } else if (recipient == Recipient.DILLON) {
            return context.dillon;
        } else if (recipient == Recipient.EVE) {
            return context.eve;
        } else if (recipient == Recipient.FRANK) {
            return context.frank;
        } else {
            revert("Invalid recipient");
        }
    }
}

library CriteriaGenerator {
    using LibPRNG for LibPRNG.PRNG;
    using OfferItemLib for OfferItem;
    using ConsiderationItemLib for ConsiderationItem;

    function withGeneratedIdentifierOrCriteria(
        ConsiderationItem memory item,
        ItemType itemType,
        Criteria /** criteria */,
        GeneratorContext memory context
    ) internal pure returns (ConsiderationItem memory) {
        if (itemType == ItemType.NATIVE || itemType == ItemType.ERC20) {
            return item.withIdentifierOrCriteria(0);
        } else if (itemType == ItemType.ERC721) {
            item = item.withIdentifierOrCriteria(context.starting721offerIndex);
            ++context.starting721offerIndex;
            return item;
        } else if (itemType == ItemType.ERC1155) {
            return
                item.withIdentifierOrCriteria(
                    context.potential1155TokenIds[
                        context.prng.next() %
                            context.potential1155TokenIds.length
                    ]
                );
        }
        revert("CriteriaGenerator: invalid ItemType");
    }

    function withGeneratedIdentifierOrCriteria(
        OfferItem memory item,
        ItemType itemType,
        Criteria /** criteria */,
        GeneratorContext memory context
    ) internal pure returns (OfferItem memory) {
        if (itemType == ItemType.NATIVE || itemType == ItemType.ERC20) {
            return item.withIdentifierOrCriteria(0);
        } else if (itemType == ItemType.ERC721) {
            item = item.withIdentifierOrCriteria(context.starting721offerIndex);
            ++context.starting721offerIndex;
            return item;
        } else if (itemType == ItemType.ERC1155) {
            return
                item.withIdentifierOrCriteria(
                    context.potential1155TokenIds[
                        context.prng.next() %
                            context.potential1155TokenIds.length
                    ]
                );
        }
        revert("CriteriaGenerator: invalid ItemType");
    }
}

library OffererGenerator {
    function generate(
        Offerer offerer,
        GeneratorContext memory context
    ) internal pure returns (address) {
        if (offerer == Offerer.TEST_CONTRACT) {
            return context.self;
        } else if (offerer == Offerer.ALICE) {
            return context.alice;
        } else if (offerer == Offerer.BOB) {
            return context.bob;
        } else {
            revert("Invalid offerer");
        }
    }

    function getKey(
        Offerer offerer,
        GeneratorContext memory context
    ) internal pure returns (uint256) {
        if (offerer == Offerer.TEST_CONTRACT) {
            return 0;
        } else if (offerer == Offerer.ALICE) {
            return context.alicePk;
        } else if (offerer == Offerer.BOB) {
            return context.bobPk;
        } else {
            revert("Invalid offerer");
        }
    }
}

library PRNGHelpers {
    using LibPRNG for LibPRNG.PRNG;

    function randEnum(
        GeneratorContext memory context,
        uint8 min,
        uint8 max
    ) internal pure returns (uint8) {
        return uint8(bound(context.prng.next(), min, max));
    }

    function randRange(
        GeneratorContext memory context,
        uint256 min,
        uint256 max
    ) internal pure returns (uint256) {
        return bound(context.prng.next(), min, max);
    }
}
