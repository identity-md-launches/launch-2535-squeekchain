// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Squeekchain} from "../src/Squeekchain.sol";

/// @dev Drives successful and failing calls in one random sequence. Every failing call must revert with
/// the exact error and leave no trace, which the model checks after every step. One actor starts empty
/// and one is an outsider with no balance or allowance, so overdrafts from zero are reachable.
contract SqueekchainAdversarialHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    Squeekchain private immutable token;
    address[5] private actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    /// @dev Counts of failing paths actually exercised, so the suite can show it is not vacuous.
    uint256 public overdrafts;
    uint256 public overspends;
    uint256 public zeroAddressRejections;
    uint256 public strangerRejections;

    constructor(Squeekchain token_, address[5] memory actors_, uint256[5] memory balances) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = balances[i];
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function transferMoreThanHeld(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[from];
        uint256 amount = bound(rawAmount, held + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ++overdrafts;
    }

    function transferToZero(uint256 fromSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ++zeroAddressRejections;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        ++zeroAddressRejections;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = bound(rawAmount, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
    }

    /// @dev Spending past a finite allowance fails on the allowance, whatever the owner holds.
    function transferFromMoreThanAllowed(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed == type(uint256).max) return;
        uint256 amount = bound(rawAmount, allowed + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++overspends;
    }

    /// @dev With enough allowance but too little balance, the call fails on the balance and the
    /// allowance it would have spent is restored by the revert.
    function transferFromMoreThanHeld(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed <= held) return;
        uint256 amount = bound(rawAmount, held + 1, allowed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++overdrafts;
    }

    /// @dev An address that is none of the actors, and so has no allowance from any of them, moves nothing.
    function strangerTransferFrom(address stranger, uint256 ownerSeed, uint256 rawAmount) external {
        for (uint256 i; i < actors.length; ++i) {
            if (stranger == actors[i]) return;
        }
        address owner = _actor(ownerSeed);
        uint256 amount = bound(rawAmount, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(owner, stranger, amount);
        ++strangerRejections;
    }
}

contract SqueekchainAdversarialInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    Squeekchain private token;
    SqueekchainAdversarialHandler private handler;
    address[5] private actors;

    function setUp() public {
        token = new Squeekchain();
        actors = [
            makeAddr("whale"),
            makeAddr("small holder"),
            makeAddr("one wei holder"),
            makeAddr("empty holder"),
            makeAddr("outsider")
        ];
        // Uneven, edge-heavy split: most of the supply, a little, one wei, nothing, nothing.
        uint256[5] memory balances = [SUPPLY - 1_000 ether - 1, 1_000 ether, 1, 0, 0];
        for (uint256 i; i < actors.length; ++i) {
            if (balances[i] > 0) assertTrue(token.transfer(actors[i], balances[i]));
        }
        assertEq(token.balanceOf(address(this)), 0);
        handler = new SqueekchainAdversarialHandler(token, actors, balances);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferMoreThanHeld.selector;
        selectors[2] = handler.transferToZero.selector;
        selectors[3] = handler.approve.selector;
        selectors[4] = handler.approveZeroSpender.selector;
        selectors[5] = handler.transferFrom.selector;
        selectors[6] = handler.transferFromMoreThanAllowed.selector;
        selectors[7] = handler.transferFromMoreThanHeld.selector;
        selectors[8] = handler.strangerTransferFrom.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesAndAllowancesMatchTheModelAfterFailures() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            address holder = actors[i];
            uint256 balance = token.balanceOf(holder);
            assertEq(balance, handler.expectedBalance(holder), "balance diverged from the model");
            sum += balance;
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(holder, actors[j]),
                    handler.expectedAllowance(holder, actors[j]),
                    "allowance diverged from the model"
                );
            }
            assertEq(token.allowance(holder, address(0)), 0, "an allowance to the zero address exists");
        }
        assertEq(sum, SUPPLY, "the actors no longer hold the whole supply");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsFixedAndNothingLeaksOutsideTheActors() public view {
        assertEq(token.totalSupply(), SUPPLY, "the supply changed");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// @dev Fails a run whose sequence never reached a failing path, so the suite cannot pass vacuously.
    function afterInvariant() public view {
        uint256 failures = handler.overdrafts() + handler.overspends() + handler.zeroAddressRejections()
            + handler.strangerRejections();
        assertGt(failures, 0, "no failing path was exercised");
    }
}
