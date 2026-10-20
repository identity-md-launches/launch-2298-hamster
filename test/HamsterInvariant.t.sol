// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterToken} from "src/HamsterToken.sol";
import {HamsterHandler} from "./handlers/HamsterHandler.sol";

/// @notice Conservation and authorization over successful and rejected ERC-20/permit operations.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant ACTORS = 4;
    HamsterHandler internal handler;
    HamsterToken internal token;

    function setUp() public {
        vm.warp(1 days);
        handler = new HamsterHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferEntireBalance.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.approveAndSpend.selector;
        selectors[5] = handler.permit.selector;
        selectors[6] = handler.rejectTransferAboveBalance.selector;
        selectors[7] = handler.rejectTransferFromAboveAllowance.selector;
        selectors[8] = handler.rejectTransferFromAboveBalance.selector;
        selectors[9] = handler.rejectZeroRecipient.selector;
        selectors[10] = handler.rejectPermit.selector;
        selectors[11] = handler.rejectPermitReplay.selector;
        selectors[12] = handler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The specified supply cannot grow or shrink, and every token remains accounted for.
    function invariant_fixedSupplyEqualsSumOfAllBalances() public view {
        uint256 sum;
        for (uint256 i; i < ACTORS; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @dev Conservation alone misses theft between actors. Check each independently tracked balance.
    function invariant_eachBalanceMatchesAuthorizedTransfers() public view {
        for (uint256 i; i < ACTORS; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor));
        }
    }

    /// @dev Finite spending decreases approval, infinite spending preserves it, and failures roll back.
    function invariant_allowancesMatchApprovalsPermitsAndSpending() public view {
        for (uint256 i; i < ACTORS; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < ACTORS; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    /// @dev Each successful signature consumes exactly one nonce; all other actions consume none.
    function invariant_noncesCountOnlySuccessfulPermits() public view {
        uint256 sum;
        for (uint256 i; i < ACTORS; ++i) {
            address actor = handler.actors(i);
            uint256 nonce = token.nonces(actor);
            assertEq(nonce, handler.expectedNonce(actor));
            sum += nonce;
        }
        assertEq(sum, handler.successfulPermits());
        assertEq(token.nonces(address(0)), 0);
    }

    /// @dev Deterministically prove every handler path is reachable. This avoids a suite
    /// that appears green because every generated action reverts or does nothing.
    function test_handlerExercisesSuccessAndFailureTransitions() public {
        uint256 initialPositive = handler.positiveTransfers();
        handler.transfer(0, 1, 1);
        handler.transfer(1, 1, 1); // Alias the sender and recipient.
        handler.transferEntireBalance(1, 2);
        handler.approve(2, 3, 20, 2);
        handler.transferFrom(2, 3, 0, 10);
        handler.approveAndSpend(2, 3, 0, 10, false);
        handler.approveAndSpend(2, 3, 0, 10, true);
        handler.permit(2, 3, 15, 2);
        handler.rejectTransferAboveBalance(2, 0, type(uint256).max);
        handler.rejectTransferFromAboveAllowance(2, 3, 0, 3);
        handler.rejectTransferFromAboveBalance(2, 3, 0);
        handler.rejectZeroRecipient(2, 3, 5, false);
        handler.rejectZeroRecipient(2, 3, 5, true);
        for (uint8 mode; mode < 4; ++mode) {
            handler.rejectPermit(2, 3, 1, mode);
        }
        handler.rejectPermitReplay(2, 3, 1);
        handler.advanceTime(1 days);

        assertGt(handler.positiveTransfers(), initialPositive);
        assertGt(handler.successfulApprovals(), 0);
        assertEq(handler.successfulPermits(), 2);
        assertEq(handler.rejectedCalls(), 10);
        invariant_fixedSupplyEqualsSumOfAllBalances();
        invariant_eachBalanceMatchesAuthorizedTransfers();
        invariant_allowancesMatchApprovalsPermitsAndSpending();
        invariant_noncesCountOnlySuccessfulPermits();
    }
}
