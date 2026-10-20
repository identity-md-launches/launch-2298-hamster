// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {HamsterToken} from "src/HamsterToken.sol";
import {HamsterPermitSigning} from "./helpers/HamsterPermitSigning.sol";

/// forge-config: default.fuzz.runs = 1000
contract HamsterPermitTest is HamsterPermitSigning {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    HamsterToken internal token;
    address internal owner;
    uint256 internal ownerKey;
    address internal other;
    uint256 internal otherKey;
    address internal spender = makeAddr("permit spender");
    address internal recipient = makeAddr("permit recipient");

    function setUp() public {
        // These signers exist only in the local test; no external account or key is used.
        (owner, ownerKey) = makeAddrAndKey("permit owner");
        (other, otherKey) = makeAddrAndKey("other permit owner");
        token = new HamsterToken();
        token.transfer(owner, 100 ether);
        vm.prank(owner);
        token.approve(spender, 9 ether);
    }

    function _permit(uint256 value) internal view returns (Permit memory) {
        return Permit(owner, spender, value, token.nonces(owner), vm.getBlockTimestamp() + 1 days);
    }

    function _state() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.totalSupply(),
                token.balanceOf(address(this)),
                token.balanceOf(owner),
                token.balanceOf(other),
                token.balanceOf(recipient),
                token.allowance(owner, spender),
                token.allowance(owner, recipient),
                token.allowance(owner, address(0)),
                token.allowance(other, spender),
                token.nonces(owner),
                token.nonces(other),
                token.nonces(address(0))
            )
        );
    }

    function test_domainIncludesNameVersionChainAndTokenAddress() public {
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), vm.getChainId()));
        HamsterToken second = new HamsterToken();
        assertEq(second.DOMAIN_SEPARATOR(), _domain(address(second), vm.getChainId()));
        assertNotEq(token.DOMAIN_SEPARATOR(), second.DOMAIN_SEPARATOR());
        vm.chainId(vm.getChainId() + 1);
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), vm.getChainId()));
    }

    function test_permitIsValidExactlyAtDeadline() public {
        Permit memory permit = _permit(1);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        vm.warp(permit.deadline);
        vm.prank(recipient); // The relayer does not need to be the owner or spender.
        _submitPermit(token, permit, sig);
        assertEq(token.allowance(owner, spender), 1);
        assertEq(token.nonces(owner), 1);
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_expiredPermitDoesNotConsumeNonceOrReplaceExistingApproval() public {
        Permit memory permit = _permit(1);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        bytes32 beforeState = _state();
        vm.warp(permit.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, permit.deadline));
        _submitPermit(token, permit, sig);
        assertEq(_state(), beforeState);
    }

    function test_wrongSignerDoesNotConsumeNonceAndValidSignatureStillWorks() public {
        Permit memory permit = _permit(1);
        Signature memory bad = _signPermit(otherKey, token, permit);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, other, owner));
        _submitPermit(token, permit, bad);
        assertEq(_state(), beforeState);

        Signature memory good = _signPermit(ownerKey, token, permit);
        _submitPermit(token, permit, good);
        assertEq(token.allowance(owner, spender), 1);
        assertEq(token.nonces(owner), 1);
    }

    function test_zeroSpenderRevertsAndRollsBackNonce() public {
        Permit memory permit = _permit(1);
        permit.spender = address(0);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        _submitPermit(token, permit, sig);
        assertEq(_state(), beforeState);

        permit.spender = spender;
        sig = _signPermit(ownerKey, token, permit);
        _submitPermit(token, permit, sig);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 1);
    }

    function test_zeroOwnerAndEmptySignatureCannotAuthorizeSpending() public {
        Permit memory permit = _permit(1);
        permit.owner = address(0);
        Signature memory empty = Signature(27, bytes32(0), bytes32(0));
        bytes32 beforeState = _state();
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _submitPermit(token, permit, empty);
        assertEq(_state(), beforeState);
        assertEq(token.allowance(address(0), spender), 0);
    }

    function test_invalidVDoesNotConsumeNonce() public {
        Permit memory permit = _permit(1);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        sig.v = 29;
        bytes32 beforeState = _state();
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        _submitPermit(token, permit, sig);
        assertEq(_state(), beforeState);
    }

    function test_malleableHighSSignatureIsRejected() public {
        Permit memory permit = _permit(1);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        sig.s = bytes32(SECP256K1_ORDER - uint256(sig.s));
        sig.v = sig.v == 27 ? 28 : 27;
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sig.s));
        _submitPermit(token, permit, sig);
        assertEq(_state(), beforeState);
    }

    function test_replayCannotRestoreSpentAllowance() public {
        Permit memory permit = _permit(5 ether);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        _submitPermit(token, permit, sig);
        vm.prank(spender);
        token.transferFrom(owner, recipient, 5 ether);
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.balanceOf(recipient), 5 ether);
        bytes32 beforeState = _state();
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submitPermit(token, permit, sig);
        assertEq(_state(), beforeState);
    }

    function test_signatureForDifferentTokenCannotBeReused() public {
        Permit memory permit = _permit(1);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        HamsterToken second = new HamsterToken();
        bytes32 beforeState = _state();
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submitPermit(second, permit, sig);
        assertEq(second.allowance(owner, spender), 0);
        assertEq(second.nonces(owner), 0);
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(_state(), beforeState);
        _submitPermit(token, permit, sig);
        assertEq(token.nonces(owner), 1);
    }

    function test_wrongChainSignatureFailsButFreshDomainSignatureWorks() public {
        Permit memory permit = _permit(1);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        bytes32 beforeState = _state();
        vm.chainId(vm.getChainId() + 1);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submitPermit(token, permit, sig);
        assertEq(_state(), beforeState);
        Signature memory onNewChain = _signPermit(ownerKey, token, permit);
        _submitPermit(token, permit, onNewChain);
        assertEq(token.allowance(owner, spender), 1);
        assertEq(token.nonces(owner), 1);
    }

    function test_futureNonceMustWaitForPrecedingPermit() public {
        Permit memory future = _permit(2);
        future.nonce = 1;
        Signature memory futureSig = _signPermit(ownerKey, token, future);
        bytes32 beforeState = _state();
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submitPermit(token, future, futureSig);
        assertEq(_state(), beforeState);

        Permit memory current = _permit(1);
        _submitPermit(token, current, _signPermit(ownerKey, token, current));
        _submitPermit(token, future, futureSig);
        assertEq(token.nonces(owner), 2);
        assertEq(token.allowance(owner, spender), 2);
    }

    function test_permitCanGrantInfiniteApprovalThenRevokeIt() public {
        Permit memory permit = _permit(type(uint256).max);
        permit.deadline = type(uint256).max;
        _submitPermit(token, permit, _signPermit(ownerKey, token, permit));
        vm.prank(spender);
        token.transferFrom(owner, recipient, 1);
        assertEq(token.allowance(owner, spender), type(uint256).max);

        permit = _permit(0);
        _submitPermit(token, permit, _signPermit(ownerKey, token, permit));
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.nonces(owner), 2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, recipient, 1);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.balanceOf(owner), 100 ether - 1);
    }

    function test_permitNoncesAreIndependentAcrossOwners() public {
        Permit memory first = _permit(7);
        _submitPermit(token, first, _signPermit(ownerKey, token, first));
        Permit memory second = Permit(other, spender, 8, 0, first.deadline);
        _submitPermit(token, second, _signPermit(otherKey, token, second));
        first = _permit(9);
        _submitPermit(token, first, _signPermit(ownerKey, token, first));
        assertEq(token.nonces(owner), 2);
        assertEq(token.nonces(other), 1);
        assertEq(token.allowance(owner, spender), 9);
        assertEq(token.allowance(other, spender), 8);
    }

    function testFuzz_signatureBindsEveryPermitField(uint256 value, uint8 field) public {
        Permit memory permit = _permit(value);
        Signature memory sig = _signPermit(ownerKey, token, permit);
        // A guaranteed distinct, still well-formed field keeps this a signature check.
        field = uint8(bound(field, 0, 3));
        if (field == 0) permit.owner = other;
        else if (field == 1) permit.spender = recipient;
        else if (field == 2) permit.value ^= 1;
        else permit.deadline += 1;
        bytes32 beforeState = _state();
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submitPermit(token, permit, sig);
        assertEq(_state(), beforeState);
    }

    function testFuzz_permitAndApproveOverwriteEachOtherWithoutMovingFunds(uint256 first, uint256 replacement) public {
        Permit memory permit = _permit(first);
        _submitPermit(token, permit, _signPermit(ownerKey, token, permit));
        assertEq(token.allowance(owner, spender), first);
        vm.prank(owner);
        token.approve(spender, replacement);
        assertEq(token.allowance(owner, spender), replacement);
        assertEq(token.nonces(owner), 1);

        permit = _permit(first);
        _submitPermit(token, permit, _signPermit(ownerKey, token, permit));
        assertEq(token.allowance(owner, spender), first);
        assertEq(token.nonces(owner), 2);
        assertEq(token.balanceOf(owner), 100 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
