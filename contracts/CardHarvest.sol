// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Minimal ERC-20 surface this contract needs.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title CardHarvest
/// @notice Ownerless tool that turns the MOVN interest of registered cards into
///         WBMB through Uniswap v4. There is no owner, admin, pause or upgrade
///         path: every constructor argument is an immutable.
/// @dev The card's WBMB principal never moves. Only MOVN ever leaves a card, and
///      this contract never pulls WBMB from anyone. Any wallet may register and be
///      converted, whatever WBMB it holds; the contract never reads a card's WBMB.
///      Every write function acts on `msg.sender`, which is the card itself (or, for
///      `setSuccessor`, the harvester itself); nobody can register or change another
///      card's entry.
///      Each card pins the MOVN/WBMB pool it is swapped through, so whoever harvests it
///      chooses only when and the least WBMB to accept, never the pool.
///      Every round sends a fixed operating fee of `FEE_BPS` (0.05 %) of the WBMB the swap
///      pays to `FEE_WALLET`; both are fixed at deployment and nothing can change them.
contract CardHarvest is IUnlockCallback {
    /// @dev Three storage slots: (recipient, registered, refundPending, registerRefundWei),
    ///      (harvester, fee, tickSpacing) and (maxMovnPerRound).
    ///      `registerRefundWei` is the register refund fixed at registration and keeps its
    ///      value after it is paid, as a record; `refundPending` alone says it is still owed.
    ///      `maxMovnPerRound` is the most MOVN one round takes from the card, set by the card
    ///      itself; never 0 in storage (0 asked for is stored as `DEFAULT_MAX_MOVN_PER_ROUND`).
    struct Card {
        address recipient;
        bool registered;
        bool refundPending;
        uint80 registerRefundWei;
        address harvester;
        uint24 fee;
        int24 tickSpacing;
        uint96 maxMovnPerRound;
    }

    /// @dev One card in a round: what it put in and what it gets back. `registerWei` is the
    ///      register refund this round pays the caller for the card (0 if none).
    struct Pick {
        address card;
        address recipient;
        uint256 movnIn;
        uint256 gasMovn;
        uint256 registerWei;
    }

    /// @dev Everything the unlock callback needs for one round.
    struct Job {
        address caller;
        address refundTo;
        uint256 outerUsed;
        PoolKey key;
        uint256 minWbmbOut;
        bool registering;
        Pick[] picks;
    }

    /// @notice Smallest MOVN balance a card must hold to register without paying its own gas.
    uint256 public constant MIN_REGISTER_MOVN = 1e18;
    /// @notice Most MOVN one round takes from a card whose owner asked for 0 (the default
    ///         per-card limit, 100 MOVN). The limit applies to every press; for no practical
    ///         limit a card passes a large value such as `type(uint96).max`.
    uint256 public constant DEFAULT_MAX_MOVN_PER_ROUND = 100e18;
    /// @notice Highest gas price the gas refund is ever computed at.
    uint256 public constant MAX_GAS_PRICE = 3 gwei;
    /// @notice Highest gas price the register refund is fixed at. Kept low so a card
    ///         registered at a high gas price cannot owe a refund that trips the 10 % guard
    ///         in every later round.
    uint256 public constant MAX_REGISTER_GAS_PRICE = 0.25 gwei;
    /// @notice Most of a card's interest, in basis points, that may be taken as gas refund.
    uint256 public constant MAX_GAS_SHARE_BPS = 1000;
    /// @notice Most successor hops followed from a card's harvester (see `setSuccessor`).
    uint256 public constant MAX_SUCCESSOR_HOPS = 4;
    /// @notice Operating fee, in basis points of the WBMB a round's swap pays: 5 = 0.05 %
    ///         (5 WBMB per 10 000 WBMB), rounded down. Sent to `FEE_WALLET`; the recipients
    ///         share the rest.
    uint256 public constant FEE_BPS = 5;
    /// @dev Seed of the transient slots that mark the cards already picked in a `harvest` call.
    bytes32 private constant PICKED_SEED = keccak256("CardHarvest.picked");
    /// @dev Fee tier and tick spacing of the MOVN/USDT and BNB/USDT pools the refund goes through.
    uint24 private constant GAS_POOL_FEE = 500;
    int24 private constant GAS_POOL_TICK_SPACING = 10;

    address public immutable POOL_MANAGER;
    address public immutable MOVN;
    address public immutable WBMB;
    address public immutable USDT;
    /// @notice Where the operating fee goes, fixed at deployment.
    address public immutable FEE_WALLET;

    uint256 private immutable GAS_BASE;
    uint256 private immutable GAS_PER_CARD;
    uint256 private immutable GAS_TAIL_BASE;
    uint256 private immutable GAS_TAIL_PER_CARD;
    uint256 private immutable GAS_REGISTER_REFUND;

    mapping(address => Card) public cards;
    /// @notice The address a harvester hands its cards on to (zero: none). See `setSuccessor`.
    mapping(address => address) public successor;

    bool private transient locked;

    event Registered(
        address indexed card,
        address indexed harvester,
        address recipient,
        bool selfFunded,
        uint24 fee,
        int24 tickSpacing,
        uint256 maxMovnPerRound
    );
    event RecipientChanged(address indexed card, address recipient);
    event HarvesterChanged(address indexed card, address indexed harvester);
    event PoolChanged(address indexed card, uint24 fee, int24 tickSpacing);
    event LimitChanged(address indexed card, uint256 maxMovnPerRound);
    event SuccessorSet(address indexed harvester, address indexed next);
    event Unregistered(address indexed card);
    event Harvested(address indexed card, address indexed recipient, uint256 movnIn, uint256 gasMovn, uint256 wbmbOut);
    event Round(
        address indexed caller,
        uint256 cards,
        uint256 movnIn,
        uint256 gasMovn,
        uint256 wbmbOut,
        uint256 refundBnb,
        uint256 gasCounted,
        uint256 feeWbmb
    );

    error NotRegistered();
    error AlreadyRegistered();
    error NeedMovn(uint256 have, uint256 need);
    error ZeroAddress();
    error BadRecipient(address recipient);
    error NothingToHarvest();
    error TooLittleOut(uint256 got, uint256 min);
    error NotPoolManager();
    error Reentered();
    error GasShareTooHigh(address card, uint256 share, uint256 limit);
    error BadPool();
    error GasAllowanceTooHigh();
    error BadLimit(uint256 limit);

    /// @dev One harvest or register at a time; the PoolManager callback runs inside it.
    modifier nonReentrant() {
        if (locked) revert Reentered();
        locked = true;
        _;
        locked = false;
    }

    /// @param feeWallet where the operating fee goes; not zero, not a token, the PoolManager
    ///        or this contract.
    /// @param gas [base, perCard, tailBase, tailPerCard, registerRefund] gas allowances.
    constructor(address pm, address movn, address wbmb, address usdt, address feeWallet, uint256[5] memory gas) {
        if (feeWallet == address(0)) revert ZeroAddress();
        if (feeWallet == pm || feeWallet == movn || feeWallet == wbmb || feeWallet == usdt || feeWallet == address(this))
        {
            revert BadRecipient(feeWallet);
        }
        POOL_MANAGER = pm;
        MOVN = movn;
        WBMB = wbmb;
        USDT = usdt;
        FEE_WALLET = feeWallet;
        GAS_BASE = gas[0];
        GAS_PER_CARD = gas[1];
        GAS_TAIL_BASE = gas[2];
        GAS_TAIL_PER_CARD = gas[3];
        GAS_REGISTER_REFUND = gas[4];
        // The register refund is stored per card in wei as a uint80.
        if (gas[4] * MAX_REGISTER_GAS_PRICE > type(uint80).max) revert GasAllowanceTooHigh();
    }

    /// @notice The five gas allowances fixed at deployment.
    function gasAllowance()
        external
        view
        returns (uint256 base, uint256 perCard, uint256 tailBase, uint256 tailPerCard, uint256 registerRefund)
    {
        return (GAS_BASE, GAS_PER_CARD, GAS_TAIL_BASE, GAS_TAIL_PER_CARD, GAS_REGISTER_REFUND);
    }

    /// @notice Register the calling card, whatever WBMB it holds, and pin the MOVN/WBMB pool
    ///         it is swapped through.
    ///         If the card already holds MOVN and has allowed this contract to take what one
    ///         round takes (all of it, or `maxMovnPerRound` if that is less), the same
    ///         transaction also swaps that, and reverts as a whole if it pays less than
    ///         `minWbmbOut` (retry with a fresh quote, or register before approving).
    ///         A card signed up by its harvester (`selfFunded` false, harvester not the card)
    ///         owes the harvester a register refund, fixed now in wei at this transaction's
    ///         gas price (capped at `MAX_REGISTER_GAS_PRICE`) and paid in BNB out of the card's own
    ///         MOVN in its first swap that the harvester (or its successor) runs.
    /// @param recipient where the swapped WBMB goes; zero means the card itself.
    /// @param harvester the address allowed to harvest this card (with its successors).
    /// @param selfFunded true if the card pays its own gas: no balance check, no registration refund.
    /// @param fee fee tier of the MOVN/WBMB pool this card is swapped through; not zero.
    /// @param tickSpacing tick spacing of that pool; not zero.
    /// @param minWbmbOut least WBMB the first swap must pay (only if it runs), before the fee.
    /// @param maxMovnPerRound most MOVN one round takes from the card: 0 for the default
    ///        `DEFAULT_MAX_MOVN_PER_ROUND`, otherwise at least `MIN_REGISTER_MOVN` (see
    ///        `setLimit`; pass a large value such as `type(uint96).max` for no practical limit).
    function register(
        address recipient,
        address harvester,
        bool selfFunded,
        uint24 fee,
        int24 tickSpacing,
        uint256 minWbmbOut,
        uint256 maxMovnPerRound
    ) external nonReentrant {
        if (cards[msg.sender].registered) revert AlreadyRegistered();
        if (harvester == address(0)) revert ZeroAddress();
        if (fee == 0 || tickSpacing == 0) revert BadPool();
        uint96 limit = _checkedLimit(maxMovnPerRound);
        recipient = _checkedRecipient(recipient);
        if (!selfFunded) {
            uint256 have = IERC20(MOVN).balanceOf(msg.sender);
            if (have < MIN_REGISTER_MOVN) revert NeedMovn(have, MIN_REGISTER_MOVN);
        }
        // A card that names itself harvester has nobody to pay back.
        uint256 registerWei;
        if (!selfFunded && harvester != msg.sender) {
            registerWei = GAS_REGISTER_REFUND
                * (tx.gasprice < MAX_REGISTER_GAS_PRICE ? tx.gasprice : MAX_REGISTER_GAS_PRICE);
        }
        cards[msg.sender] = Card({
            recipient: recipient,
            registered: true,
            refundPending: registerWei > 0,
            registerRefundWei: uint80(registerWei),
            harvester: harvester,
            fee: fee,
            tickSpacing: tickSpacing,
            maxMovnPerRound: limit
        });
        emit Registered(msg.sender, harvester, recipient, selfFunded, fee, tickSpacing, limit);

        uint256 take = _take(IERC20(MOVN).balanceOf(msg.sender), limit);
        if (take > 0 && IERC20(MOVN).allowance(msg.sender, address(this)) >= take) {
            Pick[] memory picks = new Pick[](1);
            picks[0] =
                Pick({card: msg.sender, recipient: recipient, movnIn: take, gasMovn: 0, registerWei: registerWei});
            _harvest(picks, fee, tickSpacing, minWbmbOut, harvester, 0, true);
        }
    }

    /// @notice Swap the MOVN of the listed cards to WBMB in one go and pay each card's
    ///         recipient its share. Anyone may call; a card is skipped unless it is
    ///         registered, the caller is the card itself or its harvester (or a successor of
    ///         that harvester, see `setSuccessor`), the card is pinned to this `fee` and
    ///         `tickSpacing`, and what this round
    ///         takes from it is at least `MIN_REGISTER_MOVN` of MOVN and within what it allowed
    ///         this contract to take. A round takes a card's whole MOVN balance, or its
    ///         `maxMovnPerRound` if that is less. A card listed again is skipped after its
    ///         first entry. A card whose MOVN the token refuses to move is skipped too.
    ///         A card harvesting only itself pays no gas refund.
    ///         Of the WBMB the swap pays, `FEE_BPS` (0.05 %, rounded down) goes to `FEE_WALLET`
    ///         and the recipients share the rest.
    /// @param cardList cards to harvest.
    /// @param fee fee tier of the MOVN/WBMB pool; cards pinned to another pool are skipped.
    /// @param tickSpacing tick spacing of that pool.
    /// @param minWbmbOut the whole round reverts if the swap pays less WBMB than this. It is
    ///        compared with the swap output before the fee: the recipients get 99.95 % of it.
    /// @return movnIn MOVN taken from the cards.
    /// @return wbmbOut WBMB the swap paid, before the fee (the recipients share 99.95 % of it).
    /// @return refundBnb BNB paid to the caller for gas.
    function harvest(address[] calldata cardList, uint24 fee, int24 tickSpacing, uint256 minWbmbOut)
        external
        nonReentrant
        returns (uint256 movnIn, uint256 wbmbOut, uint256 refundBnb)
    {
        uint256 gasStart = gasleft();
        Pick[] memory picks = new Pick[](cardList.length);
        uint256 n;
        for (uint256 i; i < cardList.length; ++i) {
            address card = cardList[i];
            Card storage c = cards[card];
            if (!c.registered || c.fee != fee || c.tickSpacing != tickSpacing) continue;
            bool asCard = msg.sender == card;
            if (!asCard && !_isHarvester(msg.sender, c.harvester)) continue;
            if (_picked(card)) continue;
            uint256 take = _take(IERC20(MOVN).balanceOf(card), c.maxMovnPerRound);
            if (take < MIN_REGISTER_MOVN || IERC20(MOVN).allowance(card, address(this)) < take) continue;
            _setPicked(card, true);
            picks[n++] = Pick({
                card: card,
                recipient: c.recipient,
                movnIn: take,
                gasMovn: 0,
                // The register refund goes to the harvester (or its successor), never to the card.
                registerWei: c.refundPending && !asCard ? c.registerRefundWei : 0
            });
        }
        if (n == 0) revert NothingToHarvest();
        _shrink(picks, n);
        // The marks only keep a card from being picked twice in this call: clear them so a
        // later call in the same transaction starts fresh.
        for (uint256 i; i < n; ++i) {
            _setPicked(picks[i].card, false);
        }
        return _harvest(picks, fee, tickSpacing, minWbmbOut, msg.sender, gasStart, false);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Collect, swap, settle and pay out, all while the PoolManager is unlocked.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Gas is measured per call frame and never across a call boundary (see `_harvest`).
        uint256 innerStart = gasleft();
        if (msg.sender != POOL_MANAGER) revert NotPoolManager();
        Job memory r = abi.decode(data, (Job));
        IPoolManager pm = IPoolManager(POOL_MANAGER);

        // 1. Collect. A card the token refuses to move drops out. (`harvest` already
        //    dropped any card listed twice.)
        Pick[] memory picks = r.picks;
        uint256 n;
        uint256 movnIn;
        for (uint256 i; i < picks.length; ++i) {
            Pick memory p = picks[i];
            if (!_collect(p)) continue;
            movnIn += p.movnIn;
            picks[n++] = p;
        }
        if (n == 0) {
            // At registration a card whose MOVN cannot be moved is simply registered.
            if (r.registering) return abi.encode(uint256(0), uint256(0), uint256(0));
            revert NothingToHarvest();
        }
        _shrink(picks, n);

        // 2. Gas refund: measured now (gas spent in `harvest` before the unlock plus gas
        //    spent in this callback so far), bought as exactly `refundBnb` with part of the MOVN.
        (uint256 gasMovn, uint256 refundBnb, uint256 gasCounted) =
            _gasRefund(r, r.outerUsed + (innerStart - gasleft()));

        // 3. One exact-input swap of everything left. Paying exactly `movnIn` below
        //    makes a partial fill leave an unsettled delta, so it reverts instead.
        //    No card pays more than a tenth of its MOVN for gas, so swapIn is never 0.
        uint256 swapIn = movnIn - gasMovn;
        BalanceDelta delta = pm.swap(
            r.key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(swapIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 wbmbOut = uint256(int256(delta.amount1()));
        if (wbmbOut < r.minWbmbOut) revert TooLittleOut(wbmbOut, r.minWbmbOut);

        // 4. Pay the whole MOVN debt (gas swap and main swap) at once, then the operating
        //    fee (once per round, after the floor check above), then send each recipient its
        //    share of what is left, pro rata to what the card put into the swap; the last
        //    card gets the dust. Then the gas refund in BNB.
        //    A short transfer leaves the debt open and the unlock reverts.
        pm.sync(r.key.currency0);
        IERC20(MOVN).transfer(POOL_MANAGER, movnIn);
        pm.settle();
        uint256 feeWbmb = wbmbOut * FEE_BPS / 10_000;
        if (feeWbmb > 0) pm.take(r.key.currency1, FEE_WALLET, feeWbmb);
        uint256 net = wbmbOut - feeWbmb;
        uint256 left = net;
        for (uint256 i; i < n; ++i) {
            Pick memory p = picks[i];
            uint256 share = i == n - 1 ? left : net * (p.movnIn - p.gasMovn) / swapIn;
            left -= share;
            if (share > 0) pm.take(r.key.currency1, p.recipient, share);
            emit Harvested(p.card, p.recipient, p.movnIn, p.gasMovn, share);
        }
        if (refundBnb > 0) pm.take(Currency.wrap(address(0)), r.refundTo, refundBnb);

        // 5. Round summary: `wbmbOut` is the swap output, `feeWbmb` the part of it sent to
        //    `FEE_WALLET`.
        emit Round(r.caller, n, movnIn, gasMovn, wbmbOut, refundBnb, gasCounted, feeWbmb);
        return abi.encode(movnIn, wbmbOut, refundBnb);
    }

    /// @notice Change where the calling card's WBMB goes; zero means the card itself.
    function setRecipient(address recipient) external {
        Card storage c = cards[msg.sender];
        if (!c.registered) revert NotRegistered();
        recipient = _checkedRecipient(recipient);
        c.recipient = recipient;
        emit RecipientChanged(msg.sender, recipient);
    }

    /// @notice Change the address allowed to harvest the calling card (with its successors).
    ///         A register refund still pending goes to whoever is the harvester (or its
    ///         successor) when it is paid, not to the one named at registration.
    function setHarvester(address harvester) external {
        Card storage c = cards[msg.sender];
        if (!c.registered) revert NotRegistered();
        if (harvester == address(0)) revert ZeroAddress();
        c.harvester = harvester;
        emit HarvesterChanged(msg.sender, harvester);
    }

    /// @notice Change the most MOVN one round takes from the calling card: 0 for the default
    ///         `DEFAULT_MAX_MOVN_PER_ROUND`, otherwise at least `MIN_REGISTER_MOVN`, so the
    ///         10 % gas guard stays safe. For no practical limit pass a large value such as
    ///         `type(uint96).max`. Whatever a round leaves behind waits for the next round.
    function setLimit(uint256 maxMovnPerRound) external {
        Card storage c = cards[msg.sender];
        if (!c.registered) revert NotRegistered();
        uint96 limit = _checkedLimit(maxMovnPerRound);
        c.maxMovnPerRound = limit;
        emit LimitChanged(msg.sender, limit);
    }

    /// @notice Change the MOVN/WBMB pool the calling card is swapped through.
    function setPool(uint24 fee, int24 tickSpacing) external {
        Card storage c = cards[msg.sender];
        if (!c.registered) revert NotRegistered();
        if (fee == 0 || tickSpacing == 0) revert BadPool();
        c.fee = fee;
        c.tickSpacing = tickSpacing;
        emit PoolChanged(msg.sender, fee, tickSpacing);
    }

    /// @notice Hand the caller's harvester role on to `next`, for every card that names the
    ///         caller as harvester; `next` may hand it on again, up to `MAX_SUCCESSOR_HOPS`
    ///         hops from the harvester a card names. The caller keeps the role too. Anyone
    ///         may call; it only affects cards that name the caller (directly or through
    ///         earlier hops). Zero or the caller itself clears it.
    function setSuccessor(address next) external {
        if (next == msg.sender) next = address(0);
        successor[msg.sender] = next;
        emit SuccessorSet(msg.sender, next);
    }

    /// @notice Remove the calling card from the registry.
    function unregister() external {
        if (!cards[msg.sender].registered) revert NotRegistered();
        delete cards[msg.sender];
        emit Unregistered(msg.sender);
    }

    /// @dev Runs one round through the PoolManager on the MOVN/WBMB pool of the given tier.
    ///      MOVN sorts below WBMB by address (as on BSC), so MOVN is currency0 and
    ///      MOVN to WBMB is a zeroForOne swap.
    ///      `registering` (the first swap inside `register`): if no MOVN can be collected,
    ///      nothing is swapped, no event is emitted and all three results are zero.
    /// @param refundTo who gets the gas refund in BNB: the caller of `harvest`, or the
    ///        harvester for the first swap inside `register`. A round whose only card is
    ///        `refundTo` itself (a card harvesting itself) pays no refund at all.
    /// @param gasStart `gasleft()` at the start of `harvest`; unused while registering.
    /// @dev The refund's measured gas is the gas spent in `harvest` up to here plus the gas
    ///      spent inside `unlockCallback`, each read within its own call frame. Reading
    ///      `gasStart - gasleft()` inside the callback would also count the 1/64 of the
    ///      remaining gas that each nested call holds back (EIP-150), which grows with the
    ///      transaction's gas limit: an `eth_call`, an estimate or a large gas limit would then
    ///      inflate the refund up to the cap. What is left out (encoding the job, the
    ///      PoolManager's own unlock work) is small and fixed, and the tail allowance covers it.
    function _harvest(
        Pick[] memory picks,
        uint24 fee,
        int24 tickSpacing,
        uint256 minWbmbOut,
        address refundTo,
        uint256 gasStart,
        bool registering
    ) private returns (uint256 movnIn, uint256 wbmbOut, uint256 refundBnb) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(MOVN),
            currency1: Currency.wrap(WBMB),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        uint256 outerUsed = registering ? 0 : gasStart - gasleft();
        bytes memory out = IPoolManager(POOL_MANAGER)
            .unlock(
                abi.encode(
                    Job({
                        caller: msg.sender,
                        refundTo: refundTo,
                        outerUsed: outerUsed,
                        key: key,
                        minWbmbOut: minWbmbOut,
                        registering: registering,
                        picks: picks
                    })
                )
            );
        return abi.decode(out, (uint256, uint256, uint256));
    }

    /// @dev True if `who` is `harvester` or reached from it in at most `MAX_SUCCESSOR_HOPS`
    ///      `successor` hops. The bound keeps a loop of successors cheap.
    function _isHarvester(address who, address harvester) private view returns (bool) {
        for (uint256 hops; who != harvester; ++hops) {
            if (hops == MAX_SUCCESSOR_HOPS) return false;
            harvester = successor[harvester];
            if (harvester == address(0)) return false;
        }
        return true;
    }

    /// @dev Moves a card's MOVN here. Any failure (revert, `false`, odd return data) only
    ///      skips the card; a token that returns nothing on success is accepted.
    function _collect(Pick memory p) private returns (bool) {
        (bool success, bytes memory data) =
            MOVN.call(abi.encodeCall(IERC20.transferFrom, (p.card, address(this), p.movnIn)));
        if (!success) return false;
        if (data.length == 0) return true;
        return data.length >= 32 && abi.decode(data, (uint256)) == 1;
    }

    /// @dev The one place the gas refund is worked out. Runs right after the collection,
    ///      buys exactly `refundBnb` of BNB with MOVN inside the unlock, sets each pick's
    ///      `gasMovn` and returns the MOVN spent on gas, the BNB to pay `r.refundTo`, and
    ///      the gas counted.
    /// @param measured gas spent so far, as measured per call frame by the caller.
    function _gasRefund(Job memory r, uint256 measured)
        private
        returns (uint256 gasMovn, uint256 refundBnb, uint256 gasCounted)
    {
        Pick[] memory picks = r.picks;
        uint256 n = picks.length;

        // A card harvesting itself (or registering with itself as harvester) pays its own
        // gas: no refund, the gas pools are not touched and its register refund stays
        // pending. Collected picks are distinct cards, so this is the only such case.
        if (n == 1 && picks[0].card == r.refundTo) return (0, 0, 0);

        // Common gas: what this transaction has burned so far plus a fixed allowance for
        // the rest, never above the allowance for n cards. Inside `register` the card
        // sends the transaction and pays its own gas, so nothing is counted.
        if (!r.registering) {
            gasCounted = measured + GAS_TAIL_BASE + n * GAS_TAIL_PER_CARD;
            uint256 cap = GAS_BASE + n * GAS_PER_CARD;
            if (gasCounted > cap) gasCounted = cap;
        }
        uint256 price = tx.gasprice < MAX_GAS_PRICE ? tx.gasprice : MAX_GAS_PRICE;

        // One-time register refund of each card that still owes one, as stored at its
        // registration (only picks run by the harvester or its successor carry it).
        uint256 registerBnb;
        for (uint256 i; i < n; ++i) {
            registerBnb += picks[i].registerWei;
        }
        refundBnb = gasCounted * price + registerBnb;
        // Nothing to pay (for example a zero gas price): no swap, flags stay.
        if (refundBnb == 0) return (0, 0, gasCounted);

        // Exactly refundBnb out of BNB/USDT (USDT to BNB; native BNB is currency0), then
        // exactly that USDT out of MOVN/USDT (MOVN to USDT; MOVN sorts below USDT). USDT
        // nets to zero. A partial fill leaves BNB or USDT unsettled and the unlock reverts.
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        Currency usdt = Currency.wrap(USDT);
        BalanceDelta d = pm.swap(
            PoolKey(Currency.wrap(address(0)), usdt, GAS_POOL_FEE, GAS_POOL_TICK_SPACING, IHooks(address(0))),
            SwapParams({
                zeroForOne: false, amountSpecified: int256(refundBnb), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 usdtIn = uint256(-int256(d.amount1()));
        d = pm.swap(
            PoolKey(Currency.wrap(MOVN), usdt, GAS_POOL_FEE, GAS_POOL_TICK_SPACING, IHooks(address(0))),
            SwapParams({
                zeroForOne: true, amountSpecified: int256(usdtIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        gasMovn = uint256(-int256(d.amount0()));

        // Each card owing a register refund pays its MOVN worth, pro rata to its BNB; the
        // rest is common gas split equally, rounding dust on the first card. No card pays
        // more than MAX_GAS_SHARE_BPS of its own MOVN, or the whole round reverts.
        uint256 common = gasMovn;
        for (uint256 i; i < n; ++i) {
            Pick memory p = picks[i];
            if (p.registerWei == 0) continue;
            p.gasMovn = gasMovn * p.registerWei / refundBnb;
            common -= p.gasMovn;
            cards[p.card].refundPending = false;
        }
        uint256 commonEach = common / n;
        for (uint256 i; i < n; ++i) {
            Pick memory p = picks[i];
            p.gasMovn += i == 0 ? common - commonEach * (n - 1) : commonEach;
            uint256 limit = p.movnIn * MAX_GAS_SHARE_BPS / 10_000;
            if (p.gasMovn > limit) revert GasShareTooHigh(p.card, p.gasMovn, limit);
        }
    }

    /// @dev Cuts a memory array down to its first `n` entries.
    function _shrink(Pick[] memory picks, uint256 n) private pure {
        assembly ("memory-safe") {
            mstore(picks, n)
        }
    }

    /// @dev True if `card` was already picked in this `harvest` call (transient mark).
    function _picked(address card) private view returns (bool on) {
        bytes32 slot = keccak256(abi.encode(card, PICKED_SEED));
        assembly ("memory-safe") {
            on := tload(slot)
        }
    }

    /// @dev Sets or clears the transient mark of `card` (see `_picked`).
    function _setPicked(address card, bool on) private {
        bytes32 slot = keccak256(abi.encode(card, PICKED_SEED));
        assembly ("memory-safe") {
            tstore(slot, on)
        }
    }

    /// @dev What one round takes from a card holding `bal` MOVN under `limit`. A stored
    ///      limit is never 0 (`_checkedLimit` turns 0 into the default), so there is no
    ///      "no limit" branch here.
    function _take(uint256 bal, uint256 limit) private pure returns (uint256) {
        return limit < bal ? limit : bal;
    }

    /// @dev 0 becomes `DEFAULT_MAX_MOVN_PER_ROUND`; otherwise at least `MIN_REGISTER_MOVN`,
    ///      so a card's 10 % gas share is never worked out on a sliver; above a uint96 is
    ///      refused rather than cut.
    function _checkedLimit(uint256 limit) private pure returns (uint96) {
        if (limit == 0) return uint96(DEFAULT_MAX_MOVN_PER_ROUND);
        if (limit < MIN_REGISTER_MOVN || limit > type(uint96).max) revert BadLimit(limit);
        return uint96(limit);
    }

    /// @dev Zero becomes the card itself; addresses that can only be a typo are refused.
    function _checkedRecipient(address recipient) private view returns (address) {
        if (recipient == address(0)) return msg.sender;
        if (
            recipient == address(this) || recipient == MOVN || recipient == WBMB || recipient == USDT
                || recipient == POOL_MANAGER
        ) revert BadRecipient(recipient);
        return recipient;
    }
}
