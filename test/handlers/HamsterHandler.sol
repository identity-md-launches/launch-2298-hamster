// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {HamsterToken} from "src/HamsterToken.sol";
import {HamsterPermitSigning} from "../helpers/HamsterPermitSigning.sol";

/// @dev All token recipients are in this closed set of four local actors. Balances are
/// initialized from the specified supply, then updated from successful operation inputs,
/// never from balanceOf/allowance/nonces. Unexpected reverts fail the invariant campaign.
contract HamsterHandler is HamsterPermitSigning {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTOR_COUNT = 4;

    HamsterToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) internal keys;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => uint256) public expectedNonce;

    uint256 public successfulTransfers;
    uint256 public positiveTransfers;
    uint256 public successfulApprovals;
    uint256 public successfulPermits;
    uint256 public rejectedCalls;

    constructor() {
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            (address actor, uint256 key) = makeAddrAndKey(string.concat("invariant actor ", vm.toString(i)));
            actors[i] = actor;
            keys[actor] = key;
        }
        vm.prank(actors[0]);
        token = new HamsterToken();
        expectedBalance[actors[0]] = SUPPLY;
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            vm.prank(actors[0]);
            assertTrue(token.transfer(actors[i], SUPPLY / ACTOR_COUNT));
            _move(actors[0], actors[i], SUPPLY / ACTOR_COUNT);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function transferEntireBalance(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = expectedBalance[from];
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint8 mode) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), _approvalValue(value, mode));
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 limit = _min(expectedBalance[owner], expectedAllowance[owner][spender]);
        amount = bound(amount, 0, limit);
        _spend(owner, spender, _actor(toSeed), amount);
    }

    /// @dev Also exercise positive delegated spending before a random sequence has built
    /// useful allowances. The separate transferFrom action uses whatever approval exists.
    function approveAndSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount, bool infinite)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = bound(amount, 0, expectedBalance[owner]);
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        _spend(owner, spender, _actor(toSeed), amount);
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint8 mode) external {
        _validPermit(_actor(ownerSeed), _actor(spenderSeed), _approvalValue(value, mode));
    }

    function rejectTransferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance[from];
        amount = bound(amount, balance + 1, type(uint256).max);
        address to = _actor(toSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ++rejectedCalls;
    }

    function rejectTransferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 value)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowance = bound(value, 0, SUPPLY);
        address to = _actor(toSeed);
        _approve(owner, spender, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, allowance + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, allowance + 1);
        // The invariants compare every balance and allowance with the unchanged model.
        ++rejectedCalls;
    }

    function rejectTransferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = expectedBalance[owner];
        _approve(owner, spender, balance + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, balance + 1);
        ++rejectedCalls;
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = bound(amount, 0, expectedBalance[owner]);
        if (delegated) {
            _approve(owner, spender, amount);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(owner, address(0), amount);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(owner);
            token.transfer(address(0), amount);
        }
        ++rejectedCalls;
    }

    function rejectPermit(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint8 mode) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        Permit memory request = Permit(owner, spender, value, expectedNonce[owner], vm.getBlockTimestamp() + 1 days);
        mode = uint8(bound(mode, 0, 3));
        address signer = owner;
        if (mode == 0) signer = owner == actors[0] ? actors[1] : actors[0];
        else if (mode == 1) request.deadline = vm.getBlockTimestamp() - 1;
        else if (mode == 2) request.nonce += 1;
        else request.spender = address(0);
        Signature memory sig = _signPermit(keys[signer], token, request);

        if (mode == 0) {
            vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, signer, owner));
        } else if (mode == 1) {
            vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, request.deadline));
        } else if (mode == 2) {
            vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
        _submitPermit(token, request, sig);
        ++rejectedCalls;
    }

    function rejectPermitReplay(uint256 ownerSeed, uint256 spenderSeed, uint256 value) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        (Permit memory request, Signature memory sig) = _validPermit(owner, spender, value);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submitPermit(token, request, sig);
        ++rejectedCalls;
    }

    function advanceTime(uint256 secondsElapsed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsElapsed, 0, 30 days));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }

    function _approvalValue(uint256 value, uint8 mode) internal pure returns (uint256) {
        mode = uint8(bound(mode, 0, 3));
        if (mode == 0) return 0;
        if (mode == 1) return type(uint256).max;
        if (mode == 2) return bound(value, 0, SUPPLY);
        return value;
    }

    function _approve(address owner, address spender, uint256 value) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, value));
        expectedAllowance[owner][spender] = value;
        ++successfulApprovals;
    }

    function _spend(address owner, address spender, address to, uint256 amount) internal {
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (expectedAllowance[owner][spender] != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _move(owner, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        // Sequential updates deliberately handle aliasing (from == to) as a net zero movement.
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        ++successfulTransfers;
        if (amount > 0 && from != to) ++positiveTransfers;
    }

    function _validPermit(address owner, address spender, uint256 value)
        internal
        returns (Permit memory request, Signature memory sig)
    {
        request = Permit(owner, spender, value, expectedNonce[owner], vm.getBlockTimestamp() + 1 days);
        sig = _signPermit(keys[owner], token, request);
        _submitPermit(token, request, sig);
        expectedAllowance[owner][spender] = value;
        ++expectedNonce[owner];
        ++successfulPermits;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
