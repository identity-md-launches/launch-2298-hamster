// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "src/HamsterToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract HamsterTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    HamsterToken internal token;
    address internal alice = makeAddr("edge holder");
    address internal bob = makeAddr("edge recipient");
    address internal spender = makeAddr("edge spender");

    function setUp() public {
        token = new HamsterToken();
    }

    function test_initialAccountsHaveNoBalanceAllowanceOrNonce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.nonces(address(this)), 0);
        assertEq(token.nonces(alice), 0);
    }

    function test_oneWeiRoundTripHasNoFeeOrDust() public {
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferAndTransferFromEmitTransferWithoutApproval() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroValueCannotBypassInvalidRecipientOrSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(alice, address(this)), 0);
    }

    function test_approvalReplacementAndRevocationAreIsolatedPerSpender() public {
        token.transfer(alice, 20);
        vm.startPrank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertTrue(token.approve(bob, 7));
        assertTrue(token.approve(spender, 3));
        assertEq(token.allowance(alice, spender), 3);
        assertTrue(token.approve(spender, 3)); // Repeated approval is idempotent.
        assertEq(token.allowance(alice, spender), 3);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(alice, spender, 0);
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(alice, bob), 7);
        assertEq(token.balanceOf(alice), 20);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.nonces(alice), 0);
    }

    function test_delegatedSelfTransferConsumesAllowanceButNotBalance() public {
        token.transfer(alice, 11);
        vm.prank(alice);
        token.approve(spender, 11);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, alice, 11);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, 11));
        assertEq(token.balanceOf(alice), 11);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferStillRequiresSufficientBalance() public {
        token.transfer(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        vm.prank(alice);
        token.transfer(alice, 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_finiteAllowanceCanBeExhaustedExactlyOnce() public {
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);

        // Restore the owner's balance to isolate the exhausted allowance failure.
        vm.prank(alice);
        token.transfer(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(address(this)), 1);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_maximumTransferCannotOverflowOrMint() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);

        token.approve(spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, type(uint256).max);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumMinusOneAllowanceIsFinite() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_failedTransferFromPreservesAllowanceForRetry() public {
        vm.prank(alice);
        token.approve(spender, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), 1);
        token.transfer(alice, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 1));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function testFuzz_insufficientBalanceRollsBackFiniteAllowance(uint256 held, uint256 extra) public {
        held = bound(held, 0, SUPPLY);
        extra = bound(extra, 1, type(uint256).max - held - 1);
        uint256 requested = held + extra; // Strictly finite and strictly above balance.
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, requested);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, requested));
        vm.prank(spender);
        token.transferFrom(alice, bob, requested);
        assertEq(token.allowance(alice, spender), requested);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_invalidRecipientRollsBackAllowance(uint256 amount, uint256 allowance) public {
        amount = bound(amount, 0, SUPPLY);
        allowance = bound(allowance, amount, type(uint256).max);
        token.approve(spender, allowance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), spender), allowance);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_allowanceFailurePreservesAllBalances(uint256 allowance, uint256 extra) public {
        allowance = bound(allowance, 0, SUPPLY - 1);
        uint256 requested = allowance + bound(extra, 1, SUPPLY - allowance);
        token.approve(spender, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, requested)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, requested);
        assertEq(token.allowance(address(this), spender), allowance);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferRoundTripPreservesPreexistingBalances(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY - held);
        token.transfer(alice, held);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitDelegatedTransfersEqualSingleTransfer(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        uint256 total = first + second;
        token.approve(spender, total);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, first));
        assertTrue(token.transferFrom(address(this), alice, second));
        vm.stopPrank();

        HamsterToken single = new HamsterToken();
        single.approve(spender, total);
        vm.prank(spender);
        assertTrue(single.transferFrom(address(this), alice, total));
        assertEq(token.balanceOf(address(this)), single.balanceOf(address(this)));
        assertEq(token.balanceOf(alice), single.balanceOf(alice));
        assertEq(token.allowance(address(this), spender), single.allowance(address(this), spender));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
