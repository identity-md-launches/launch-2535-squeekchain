// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Squeekchain} from "../src/Squeekchain.sol";

/// @dev Deploys and distributes in one call, as a launch factory does in one transaction.
contract OneCallLauncher {
    function launch(address[] calldata recipients, uint256[] calldata amounts) external returns (Squeekchain token) {
        token = new Squeekchain();
        for (uint256 i; i < recipients.length; ++i) {
            require(token.transfer(recipients[i], amounts[i]), "transfer returned false");
        }
    }
}

contract SqueekchainEdgesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    Squeekchain private token;
    address private alice;
    address private bob;
    address private spender;

    function setUp() public {
        token = new Squeekchain();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    function test_supplyIsExactlyOneBillionWholeTokens() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** token.decimals(), 0);
    }

    function test_rejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool sent,) = address(token).call{value: 1 ether}("");
        assertFalse(sent, "the token accepted ether it can never release");
        assertEq(address(token).balance, 0);
    }

    function test_rejectsEtherWithTransfer() public {
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(token).call{value: 1 ether}(abi.encodeCall(token.transfer, (alice, 1)));
        assertFalse(sent, "transfer is not payable");
        assertEq(token.balanceOf(alice), 0);
        assertEq(address(token).balance, 0);
    }

    function testFuzz_unknownSelectorsRevert(bytes4 selector, bytes calldata args) public {
        // The ERC-20 surface plus the public constant; everything else has no fallback to land in.
        vm.assume(
            selector != token.name.selector && selector != token.symbol.selector && selector != token.decimals.selector
                && selector != token.totalSupply.selector && selector != token.balanceOf.selector
                && selector != token.allowance.selector && selector != token.transfer.selector
                && selector != token.approve.selector && selector != token.transferFrom.selector
                && selector != token.INITIAL_SUPPLY.selector
        );
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_emptyCalldataReverts() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok);
    }

    /// @dev Same reachability rule the launch floor applies to the token's runtime.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function test_oneCallLaunchMintsToTheLauncherAndDistributesExactly() public {
        OneCallLauncher launcher = new OneCallLauncher();
        address[] memory recipients = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        (recipients[0], amounts[0]) = (makeAddr("distributor"), SUPPLY / 10);
        (recipients[1], amounts[1]) = (makeAddr("pool"), SUPPLY / 2);
        (recipients[2], amounts[2]) = (makeAddr("requester"), SUPPLY - SUPPLY / 10 - SUPPLY / 2);
        Squeekchain launched = launcher.launch(recipients, amounts);

        assertEq(launched.balanceOf(address(launcher)), 0);
        assertEq(launched.balanceOf(address(this)), 0);
        for (uint256 i; i < recipients.length; ++i) {
            assertEq(launched.balanceOf(recipients[i]), amounts[i]);
        }
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_launchOverdistributionRevertsWholeDeployment() public {
        OneCallLauncher launcher = new OneCallLauncher();
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (recipients[0], amounts[0]) = (alice, SUPPLY);
        (recipients[1], amounts[1]) = (bob, 1);
        vm.expectRevert();
        launcher.launch(recipients, amounts);
    }

    function test_transferOneWeiOverFullSupplyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_emptyAccountCannotSendOneWei() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_balanceAfterSpendingDownIsReusable() public {
        assertTrue(token.transfer(alice, 1));
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        vm.prank(bob);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Only exactly type(uint256).max is infinite; one below it is spent like any finite allowance.
    function test_allowanceOneBelowMaxIsDecremented() public {
        assertTrue(token.approve(spender, type(uint256).max - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 5));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 6);
    }

    function test_allowanceExactlySupplySpentInFullReachesZero() public {
        assertTrue(token.approve(spender, SUPPLY));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_allowanceOutlivesBalanceAndCannotOverdraw() public {
        assertTrue(token.transfer(alice, 10 ether));
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 10 ether));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_allowancesArePerOwnerAndPerSpender() public {
        assertTrue(token.transfer(alice, 10 ether));
        assertTrue(token.approve(spender, 5 ether));

        // An allowance from this contract does not let the spender draw on alice.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, spender, 1);

        // Nor does alice's allowance to bob reach the spender.
        vm.prank(alice);
        assertTrue(token.approve(bob, 5 ether));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(address(this), bob), 0);
    }

    function test_approveDoesNotRequireABalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, SUPPLY));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), SUPPLY);
    }

    function testFuzz_strangerCannotPullWithoutAllowance(address stranger, uint256 rawAmount) public {
        vm.assume(stranger != address(this));
        uint256 amount = bound(rawAmount, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(address(this), bob, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_twoHopTransferConserves(address mid, address end, uint256 rawFirst, uint256 rawSecond) public {
        mid = address(uint160(bound(uint160(mid), 1, type(uint160).max)));
        end = address(uint160(bound(uint160(end), 1, type(uint160).max)));
        uint256 first = bound(rawFirst, 0, SUPPLY);
        uint256 second = bound(rawSecond, 0, first);

        assertTrue(token.transfer(mid, first));
        vm.prank(mid);
        assertTrue(token.transfer(end, second));

        uint256 tracked = token.balanceOf(address(this));
        if (mid != address(this)) tracked += token.balanceOf(mid);
        if (end != address(this) && end != mid) tracked += token.balanceOf(end);
        assertEq(tracked, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approveThenSpendAnyAmountWithinBounds(uint256 rawAllowance, uint256 rawSpend) public {
        uint256 allowed = bound(rawAllowance, 0, type(uint256).max - 1);
        uint256 spend = bound(rawSpend, 0, allowed < SUPPLY ? allowed : SUPPLY);
        assertTrue(token.approve(spender, allowed));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, spend));
        assertEq(token.allowance(address(this), spender), allowed - spend);
        assertEq(token.balanceOf(alice), spend);
    }
}
