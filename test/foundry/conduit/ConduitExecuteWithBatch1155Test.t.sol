// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

import { Conduit } from "../../../contracts/conduit/Conduit.sol";
import { ConduitController } from "../../../contracts/conduit/ConduitController.sol";
import { BaseConduitTest } from "./BaseConduitTest.sol";
import { ConduitTransfer, ConduitBatch1155Transfer, ConduitItemType } from "../../../contracts/conduit/lib/ConduitStructs.sol";
import { TestERC1155 } from "../../../contracts/test/TestERC1155.sol";
import { TestERC20 } from "../../../contracts/test/TestERC20.sol";
import { TestERC721 } from "../../../contracts/test/TestERC721.sol";
import { ERC721Recipient } from "../utils/ERC721Recipient.sol";
import { ERC1155Recipient } from "../utils/ERC1155Recipient.sol";

contract ConduitExecuteWithBatch1155Test is BaseConduitTest {
    struct FuzzInputs {
        ConduitTransferIntermediate[10] transferIntermediates;
        BatchIntermediate[10] batchIntermediates;
    }

    struct Context {
        Conduit conduit;
        ConduitTransfer[] transfers;
        ConduitBatch1155Transfer[] batchTransfers;
    }

    function testExecuteWithBatch1155(FuzzInputs memory inputs) public {
        for (uint8 i = 0; i < inputs.batchIntermediates.length; i++) {
            vm.assume(inputs.batchIntermediates[i].idAmounts.length > 0);
        }

        ConduitTransfer[] memory transfers = new ConduitTransfer[](0);
        for (uint8 i = 0; i < inputs.transferIntermediates.length; i++) {
            transfers = extendConduitTransferArray(
                transfers,
                deployTokenAndCreateConduitTransfers(
                    inputs.transferIntermediates[i]
                )
            );
        }

        ConduitBatch1155Transfer[]
            memory batchTransfers = new ConduitBatch1155Transfer[](0);
        for (uint8 j = 0; j < inputs.batchIntermediates.length; j++) {
            batchTransfers = extendConduitTransferArray(
                batchTransfers,
                deployTokenAndCreateConduitBatch1155Transfer(
                    inputs.batchIntermediates[j]
                )
            );
        }
        mintTokensAndSetTokenApprovalsForConduit(
            transfers,
            address(referenceConduit)
        );
        updateExpectedTokenBalances(transfers);
        mintTokensAndSetTokenApprovalsForConduit(
            batchTransfers,
            address(referenceConduit)
        );
        updateExpectedTokenBalances(batchTransfers);
        _testExecuteWithBatch1155(
            Context(referenceConduit, transfers, batchTransfers)
        );
        mintTokensAndSetTokenApprovalsForConduit(transfers, address(conduit));
        mintTokensAndSetTokenApprovalsForConduit(
            batchTransfers,
            address(conduit)
        );
        _testExecuteWithBatch1155(Context(conduit, transfers, batchTransfers));
    }

    function _testExecuteWithBatch1155(Context memory context)
        internal
        resetBatchTokenBalancesBetweenRuns(
            context.transfers,
            context.batchTransfers
        )
    {
        bytes4 magicValue = context.conduit.executeWithBatch1155(
            context.transfers,
            context.batchTransfers
        );
        assertEq(magicValue, Conduit.execute.selector);

        for (uint256 i = 0; i < context.transfers.length; i++) {
            ConduitTransfer memory transfer = context.transfers[i];
            ConduitItemType itemType = transfer.itemType;
            emit log_uint(uint256(transfer.itemType));

            if (itemType == ConduitItemType.ERC20) {
                assertEq(
                    TestERC20(transfer.token).balanceOf(transfer.to),
                    getExpectedTokenBalance(transfer)
                );
            } else if (itemType == ConduitItemType.ERC1155) {
                assertEq(
                    TestERC1155(transfer.token).balanceOf(
                        transfer.to,
                        transfer.identifier
                    ),
                    getExpectedTokenBalance(transfer)
                );
            } else if (itemType == ConduitItemType.ERC721) {
                assertEq(
                    TestERC721(transfer.token).ownerOf(transfer.identifier),
                    transfer.to
                );
            }
        }

        for (uint256 i = 0; i < context.batchTransfers.length; i++) {
            ConduitBatch1155Transfer memory batchTransfer = context
                .batchTransfers[i];

            address[] memory toAddresses = new address[](
                batchTransfer.ids.length
            );
            for (uint256 j = 0; j < batchTransfer.ids.length; j++) {
                toAddresses[j] = batchTransfer.to;
            }
            uint256[] memory actualBatchBalances = TestERC1155(
                batchTransfer.token
            ).balanceOfBatch(toAddresses, batchTransfer.ids);
            uint256[]
                memory expectedBatchBalances = getExpectedBatchTokenBalances(
                    batchTransfer
                );
            assertTrue(
                actualBatchBalances.length == expectedBatchBalances.length
            );

            for (uint256 j = 0; j < actualBatchBalances.length; j++) {
                assertEq(actualBatchBalances[j], expectedBatchBalances[j]);
            }
        }
    }
}