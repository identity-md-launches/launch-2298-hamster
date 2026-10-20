// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterToken} from "src/HamsterToken.sol";

/// @dev Test-only signing. Derive the EIP-712 domain independently of the token's getter,
/// so a bad domain implementation cannot make both the signature and its check agree.
abstract contract HamsterPermitSigning is Test {
    struct Permit {
        address owner;
        address spender;
        uint256 value;
        uint256 nonce;
        uint256 deadline;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function _domain(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("HAMSTER"),
                keccak256("1"),
                chainId,
                verifyingContract
            )
        );
    }

    function _signPermit(uint256 key, HamsterToken token, Permit memory permit)
        internal
        view
        returns (Signature memory sig)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                permit.owner,
                permit.spender,
                permit.value,
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(address(token), vm.getChainId()), structHash));
        (sig.v, sig.r, sig.s) = vm.sign(key, digest);
    }

    function _submitPermit(HamsterToken token, Permit memory permit, Signature memory sig) internal {
        token.permit(permit.owner, permit.spender, permit.value, permit.deadline, sig.v, sig.r, sig.s);
    }
}
