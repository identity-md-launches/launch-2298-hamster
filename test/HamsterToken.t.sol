// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {DeployHamsterToken} from "../script/DeployHamsterToken.s.sol";

contract HamsterTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    HamsterToken internal token;

    /// @dev The deployer stands in for the launch factory: whoever runs the constructor holds everything.
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    function setUp() public {
        signer = vm.addr(signerKey);
        vm.prank(deployer);
        token = new HamsterToken();
    }

    // ------------------------------------------------------------------
    // Metadata and supply
    // ------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "HAMSTER");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.NAME(), "HAMSTER");
        assertEq(token.SYMBOL(), "HAMSTER");
        assertEq(token.DECIMALS(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(EXPECTED_SUPPLY, 1_000_000_000 * 10 ** 18);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        HamsterToken fresh = new HamsterToken();
        assertEq(fresh.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_deployScriptMintsToItsCaller() public {
        DeployHamsterToken script = new DeployHamsterToken();
        HamsterToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY);
        assertEq(deployed.name(), "HAMSTER");
    }

    // ------------------------------------------------------------------
    // Transfers: success
    // ------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234_567 ether;
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferWholeBalanceAndSelfTransfer() public {
        vm.prank(deployer);
        token.transfer(alice, EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);

        vm.prank(alice);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
    }

    function test_transferChainArrivesWholeAtEveryHop() public {
        // Factory -> distributor -> claimant, the launch's own flow, with no leakage anywhere.
        uint256 swarm = EXPECTED_SUPPLY / 10;
        vm.prank(deployer);
        token.transfer(alice, swarm);
        assertEq(token.balanceOf(alice), swarm);
        vm.prank(alice);
        token.transfer(bob, swarm);
        assertEq(token.balanceOf(bob), swarm);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ------------------------------------------------------------------
    // Transfers: failure
    // ------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        vm.prank(alice);
        token.transfer(bob, 6 ether);
    }

    function test_transferRevertsWhenSenderHoldsNothing() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1 ether);
    }

    // ------------------------------------------------------------------
    // Allowances
    // ------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(alice, spender, 40 ether);
        vm.prank(alice);
        assertTrue(token.approve(spender, 40 ether));
        assertEq(token.allowance(alice, spender), 40 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 30 ether));
        assertEq(token.balanceOf(bob), 30 ether);
        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(spender, 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10 ether, 11 ether)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, 11 ether);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromRevertsWhenOwnerLacksBalance() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(alice, bob, 60 ether);
        assertEq(token.allowance(alice, spender), type(uint256).max);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 1);
    }

    // ------------------------------------------------------------------
    // Permit (EIP-2612)
    // ------------------------------------------------------------------

    function _signPermit(uint256 key, address owner, address to, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, to, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(key, digest);
    }

    function test_permitSetsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, spender, 77 ether, 0, deadline);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(signer, spender, 77 ether);
        vm.prank(bob); // anyone may relay a permit
        token.permit(signer, spender, 77 ether, deadline, v, r, s);

        assertEq(token.allowance(signer, spender), 77 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitThenTransferFromMovesTokens() public {
        vm.prank(deployer);
        token.transfer(signer, 10 ether);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, spender, 10 ether, 0, deadline);
        token.permit(signer, spender, 10 ether, deadline, v, r, s);
        vm.prank(spender);
        token.transferFrom(signer, bob, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.balanceOf(signer), 0);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, spender, 1 ether, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, spender, 1 ether, deadline, v, r, s);
    }

    function test_permitRevertsOnWrongSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 otherKey = 0xB0B;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(otherKey, signer, spender, 1 ether, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(otherKey), signer));
        token.permit(signer, spender, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, spender), 0);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, spender, 1 ether, 0, deadline);
        token.permit(signer, spender, 1 ether, deadline, v, r, s);
        // The nonce moved on, so the same signature now recovers to a different address.
        vm.expectRevert();
        token.permit(signer, spender, 1 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitRevertsOnOtherChain() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, spender, 1 ether, 0, deadline);
        vm.chainId(block.chainid + 1);
        // The domain separator is rebuilt for the new chain id, so the signature no longer matches.
        vm.expectRevert();
        token.permit(signer, spender, 1 ether, deadline, v, r, s);
    }

    function test_eip712DomainMatchesToken() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(name, "HAMSTER");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
    }

    // ------------------------------------------------------------------
    // No privileged powers: nothing mints, pauses, freezes or seizes
    // ------------------------------------------------------------------

    function test_noFunctionIncreasesSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(deployer);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_noFunctionMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1000 ether);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        (bool pulled,) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, alice, deployer, 1));
        assertFalse(pulled, "deployer pulled from a holder without allowance");
        assertEq(token.balanceOf(alice), 1000 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500 ether));
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_hasNoOwnerAndNoBurnEntryPoint() public {
        (bool hasOwner,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner, "token exposes owner()");
        vm.prank(deployer);
        (bool burned,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(burned, "token exposes burn(uint256)");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    // ------------------------------------------------------------------
    // Bytecode properties the launch checks
    // ------------------------------------------------------------------

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_creationCodeDeploysFromRawBytes() public {
        // The launch deploys the token from its creation code through CREATE2 with no arguments appended.
        bytes memory code = type(HamsterToken).creationCode;
        address factory = makeAddr("factory");
        vm.prank(factory);
        address created;
        assembly ("memory-safe") {
            created := create(0, add(code, 32), mload(code))
        }
        assertTrue(created != address(0));
        assertEq(HamsterToken(created).balanceOf(factory), EXPECTED_SUPPLY);
        assertEq(HamsterToken(created).totalSupply(), EXPECTED_SUPPLY);
    }

    // ------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ------------------------------------------------------------------

    function testFuzz_transferConservesSupplyAndIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 extra) public {
        held = bound(held, 0, EXPECTED_SUPPLY - 1);
        extra = bound(extra, 1, EXPECTED_SUPPLY - held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + extra)
        );
        vm.prank(alice);
        token.transfer(bob, held + extra);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 pulled) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        pulled = bound(pulled, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        if (pulled > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, pulled)
            );
            token.transferFrom(deployer, bob, pulled);
        } else {
            assertTrue(token.transferFrom(deployer, bob, pulled));
            assertEq(token.balanceOf(bob), pulled);
            assertEq(token.allowance(deployer, spender), allowed - pulled);
        }
    }

    function testFuzz_permitForAnyValueAndDeadline(uint256 value, uint64 deadlineDelta) public {
        uint256 deadline = block.timestamp + uint256(deadlineDelta);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, spender, value, 0, deadline);
        token.permit(signer, spender, value, deadline, v, r, s);
        assertEq(token.allowance(signer, spender), value);
        assertEq(token.nonces(signer), 1);
    }
}
