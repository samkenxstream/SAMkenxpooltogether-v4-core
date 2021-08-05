// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";

import "hardhat/console.sol";

import "./interfaces/IClaimer.sol";
import "./interfaces/ITicket.sol";


contract Ticket is ITicket, IClaimer, ERC20PermitUpgradeable, OwnableUpgradeable {
  using SafeERC20Upgradeable for IERC20Upgradeable;
  using SafeCastUpgradeable for uint256;
  using SafeMathUpgradeable for uint256;

  struct Twab {
    uint224 balance;
    uint32 timestamp;
  }

  /// @notice Emitted when ticket is initialized.
  /// @param name Ticket name (eg: PoolTogether Dai Ticket (Compound)).
  /// @param symbol Ticket symbol (eg: PcDAI).
  /// @param decimals Ticket decimals.
  event TicketInitialized(
    string name,
    string symbol,
    uint8 decimals
  );

  event NewTwab(
    address indexed user,
    Twab newTwab
  );

  uint32 public constant CARDINALITY = 32;

  /// @notice Record of token twabs for each account
  mapping (address => Twab[CARDINALITY]) internal twabs;

  /// @notice
  mapping (address => uint256) internal mostRecentTwabIndex;

  /// @notice Initializes Ticket with passed parameters.
  /// @param _name Ticket's EIP-20 token name.
  /// @param _symbol Ticket's EIP-20 token symbol.
  /// @param _decimals Ticket's EIP-20 token decimals.
  function initialize (
    string calldata _name,
    string calldata _symbol,
    uint8 _decimals
  ) public initializer {
    // name = _name;
    // symbol = _symbol;

    // __ERC20_init(_name, _symbol);
    // __ERC20Permit_init("PoolTogether Ticket");

    require(_decimals > 0, "Ticket/decimals-gt-zero");
    // _setupDecimals(_decimals);

    emit TicketInitialized(_name, _symbol, _decimals);
  }

  // @notice Get the number of tokens held by the `account`
  // @param account Address of the account to get the balance of
  // @return Number of tokens held
  // function balanceOf(address account) external view override returns (uint256) {
  //     return twabs[account];
  // }

  /* ============ External Functions ============ */

  function claim(address user, IClaimable claimable, uint256[] calldata timestamps, bytes calldata data) external override returns (bool) {
    uint256 timestampsLength = timestamps.length;
    uint256[] memory timestampBalances = new uint256[](timestampsLength);
    for (uint256 i = 0; i < timestampsLength; i++) {
      timestampBalances[i] = _getBalance(user, uint32(timestamps[i]));
    }
    claimable.claim(user, timestamps, timestampBalances, data);
  }

    /// @notice comparator for 32-bit timestamps
    /// @dev safe for 0 or 1 overflows, a and b _must_ be chronologically before or equal to time
    /// @param time A timestamp truncated to 32 bits
    /// @param a A comparison timestamp from which to determine the relative position of `time`
    /// @param b From which to determine the relative position of `time`
    /// @return bool Whether `a` is chronologically <= `b`
    function lte(
        uint32 time,
        uint32 a,
        uint32 b
    ) private pure returns (bool) {
        // if there hasn't been overflow, no need to adjust
        if (a <= time && b <= time) return a <= b;

        uint256 aAdjusted = a > time ? a : a + 2**32;
        uint256 bAdjusted = b > time ? b : b + 2**32;

        return aAdjusted <= bAdjusted;
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a target, i.e. where [beforeOrAt, atOrAfter] is satisfied.
    /// The result may be the same observation, or adjacent observations.
    /// @dev The answer must be contained in the array, used when the target is located within the stored observation
    /// boundaries: older than the most recent observation and younger, or the same age as, the oldest observation
    /// @param target The timestamp at which the reserved observation should be for
    /// @param user The address of the user whose observations are being fetched
    /// @return beforeOrAt The observation recorded before, or at, the target
    /// @return atOrAfter The observation recorded at, or after, the target
    function _binarySearch(
        uint32 target,
        address user
    ) internal view returns (Twab memory beforeOrAt, Twab memory atOrAfter) {
        uint32 time = uint32(block.timestamp);
        // console.log("time: ", time);
        // index is the most recent observation
        uint256 index = _indexOfUser(user);
        // index = 1
        // console.log("index: ", index);

        uint32 cardinality = CARDINALITY;

        uint256 l = (index + 1) % cardinality; // oldest observation
        uint256 r = l + cardinality - 1; // newest observation
        uint256 i;

        while (true) {
            // console.log("l: ", l);
            // console.log("r: ", r);
            i = (l + r) / 2;
            // i = (32 + 33) / 2 = 32

            beforeOrAt = twabs[user][i % cardinality];
            // beforeOrAt = twabs[user][32 % 32]
            // beforeOrAt = index 0

            // we've landed on an uninitialized tick, keep searching higher (more recently)
            if (beforeOrAt.timestamp == 0) {
                l = i + 1;
                continue;
            }

            atOrAfter = twabs[user][(i + 1) % cardinality];
            // atOrAfter = twabs[user][33 % 32]
            // atOrAfter = index 1

            bool targetAtOrAfter = lte(time, beforeOrAt.timestamp, target);

            // TODO: add less than function to check for overflow and underflow
            // check if we've found the answer!
            if (targetAtOrAfter && (target < atOrAfter.timestamp)) break;

            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

  function _indexOfUser(address user) internal view returns (uint256) {
    return (mostRecentTwabIndex[user] + CARDINALITY - 1) % CARDINALITY;
  }

  function _newTwab(address user) internal {
    // **New twab = last twab (or zero) + (balance * elapsed seconds)**

    uint32 currentTimestamp = uint32(block.timestamp);
    uint256 currentIndex = _indexOfUser(user);
    Twab memory lastTwab = twabs[user][currentIndex];

    if (lastTwab.timestamp == currentTimestamp) {
      return;
    }

    uint32 elapsedSeconds = currentTimestamp - lastTwab.timestamp;
    uint224 newTwabBalance = (lastTwab.balance + (balanceOf(user) * elapsedSeconds)).toUint224();

    // Turn (currentIndex + 1) % CARDINALITY into a util function
    Twab memory newTwab = Twab ({
      balance: newTwabBalance,
      timestamp: currentTimestamp
    });

    twabs[user][(currentIndex + 1) % CARDINALITY] = newTwab;

    mostRecentTwabIndex[user] = (currentIndex + 2) % CARDINALITY;

    emit NewTwab(user, newTwab);
  }

  function _beforeTokenTransfer(address from, address to, uint256) internal override {
    if (from != address(0)) {
      _newTwab(from);
    }

    if (to != address(0)) {
      _newTwab(to);
    }
  }

  function getBalance(address user, uint32 target) override external view returns (uint256) {
    return _getBalance(user, target);
  }

  function getBalances(address user, uint32[] calldata targets) external view override returns (uint256[] memory){
    uint256 length = targets.length;
    uint256[] memory balances = new uint256[](length);
    
    for(uint256 i =0; i < length; i++){
      balances[i] = _getBalance(user, targets[i]);
    }

    return balances;
  }

  function _getBalance(address user, uint32 target) internal view returns (uint256) {
    uint256 index = _indexOfUser(user);

    Twab memory beforeOrAt = twabs[user][index];
    // beforeOrAt = index 1
    uint32 time = uint32(block.timestamp);
    uint32 targetTimestamp = target > time ? time : target;

    // if the target is chronologically at or after the newest observation, we can early return
    if (lte(time, beforeOrAt.timestamp, targetTimestamp)) {
      return balanceOf(user);
    }

    // now, set before to the oldest observation
    beforeOrAt = twabs[user][(index + 1) % CARDINALITY];
    if (beforeOrAt.timestamp == 0) beforeOrAt = twabs[user][0];

    // NOTE: could use a 'less than' here
    if (targetTimestamp < beforeOrAt.timestamp) {
      return 0;
    }

    // ensure that the target is chronologically at or after the oldest observation
    // if (targetTimestamp == beforeOrAt.timestamp) {
    //   return beforeOrAt.balance;
    // }

    Twab memory afterOrAt;
    (beforeOrAt, afterOrAt) = _binarySearch(target, user);

    // difference in balance / time
    uint224 differenceInBalance = afterOrAt.balance - beforeOrAt.balance;
    uint32 differenceInTime = afterOrAt.timestamp - beforeOrAt.timestamp;

    return differenceInBalance / differenceInTime;
  }
}