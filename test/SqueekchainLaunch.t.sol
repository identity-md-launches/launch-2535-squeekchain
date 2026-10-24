// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Squeekchain} from "../src/Squeekchain.sol";

/// @dev Local deployment and distribution fixture, never a launch application contract.
contract TokenFactoryFixture {
    address private immutable controller = msg.sender;

    function deploy(bytes32 salt) external returns (Squeekchain) {
        require(msg.sender == controller, "fixture controller only");
        return new Squeekchain{salt: salt}();
    }

    function distribute(Squeekchain token, address recipient, uint256 amount) external {
        require(msg.sender == controller, "fixture controller only");
        require(token.transfer(recipient, amount), "fixture transfer failed");
    }
}

contract SqueekchainLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;

    function test_create2MintsEverythingToImmediateDeployer() public {
        address launcher = makeAddr("launcher");
        vm.startPrank(launcher, launcher);
        TokenFactoryFixture factory = new TokenFactoryFixture();
        Squeekchain token = factory.deploy(keccak256("SQK deployment test"));
        vm.stopPrank();

        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(launcher), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertLe(address(token).code.length, 24_576);
    }

    function test_distributionClaimsAndPoolTransfersArriveWhole() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        Squeekchain token = factory.deploy(keccak256("SQK distribution test"));
        address distributor = makeAddr("distributor fixture");
        address pool = makeAddr("pool accounting fixture");
        address requester = makeAddr("requester fixture");
        address claimant = makeAddr("claimant");
        address trader = makeAddr("trader");

        uint256 swarmShare = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 4 / 10;
        uint256 remainder = SUPPLY - swarmShare - poolShare;
        factory.distribute(token, distributor, swarmShare);
        factory.distribute(token, pool, poolShare);
        factory.distribute(token, requester, remainder);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(distributor), swarmShare);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.balanceOf(requester), remainder);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarmShare));
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(claimant), swarmShare);

        // Checks the token leg of pool interactions; this fixture is not a DEX or a swap simulation.
        uint256 traded = 1_000 ether;
        vm.prank(pool);
        assertTrue(token.transfer(trader, traded));
        assertEq(token.balanceOf(trader), traded);
        assertEq(token.balanceOf(pool), poolShare - traded);
        vm.prank(trader);
        assertTrue(token.transfer(pool, traded));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(claimant) + token.balanceOf(pool) + token.balanceOf(requester), SUPPLY);
    }
}
