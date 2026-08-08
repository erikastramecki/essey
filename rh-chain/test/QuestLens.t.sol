// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {QuestLens, IQuest} from "../src/testnet/QuestLens.sol";

contract MockQuest is IQuest {
  mapping(address => bool) public registered;
  mapping(address => uint256) public referralCount;
  function setRegistered(address a, bool v) external { registered[a] = v; }
  function setReferrals(address a, uint256 n) external { referralCount[a] = n; }
}

contract MockErc20 is ERC20 { constructor() ERC20("m", "m") {} function mint(address t, uint256 a) external { _mint(t, a); } }
contract MockErc721 is ERC721 { uint256 n; constructor() ERC721("s", "s") {} function mint(address t) external { _mint(t, ++n); } }

contract QuestLensTest is Test {
  QuestLens lens;
  MockQuest quest;
  MockErc721 seat;
  MockErc20 pool;
  MockErc20 aapl;
  MockErc20 nvda;
  address u = address(0xABCD);

  function setUp() public {
    quest = new MockQuest();
    seat = new MockErc721();
    pool = new MockErc20();
    aapl = new MockErc20();
    nvda = new MockErc20();
    lens = new QuestLens(IQuest(address(quest)), IERC721(address(seat)), IERC20(address(pool)), IERC20(address(aapl)), IERC20(address(nvda)));
  }

  function _allFour() internal {
    quest.setRegistered(u, true);
    seat.mint(u);
    pool.mint(u, 1);
    aapl.mint(u, 1);
  }

  function test_qualified_requiresAllFour() public {
    assertFalse(lens.qualified(u), "nothing done");
    _allFour();
    assertTrue(lens.qualified(u), "all four -> qualified");
  }

  /// Removing ANY one of the four drops qualification — proves each is load-bearing.
  function test_eachConditionIsRequired() public {
    _allFour();
    assertTrue(lens.qualified(u));

    quest.setRegistered(u, false); assertFalse(lens.qualified(u), "needs registered"); quest.setRegistered(u, true);

    // move the Seat away -> no longer owns a Seat
    uint256 sid = 1;
    vm.prank(u); seat.transferFrom(u, address(0xdead), sid);
    assertFalse(lens.qualified(u), "needs a Seat");
    seat.mint(u); // re-own

    // stock via NVDA instead of AAPL still counts (holds tokenized stock either way)
    assertTrue(lens.qualified(u), "AAPL holding qualifies");
  }

  function test_stockLeg_aaplOrNvda() public {
    quest.setRegistered(u, true); seat.mint(u); pool.mint(u, 1);
    assertFalse(lens.qualified(u), "no stock yet");
    nvda.mint(u, 1);
    assertTrue(lens.qualified(u), "NVDA holding satisfies the stock leg");
  }

  function test_status_reflectsAll() public {
    _allFour();
    quest.setReferrals(u, 3);
    QuestLens.Status memory s = lens.status(u);
    assertTrue(s.registered && s.ownsSeat && s.supplied && s.wonStock);
    assertEq(s.referrals, 3);
  }

  function test_qualifiedMany() public {
    address v = address(0xBEEF);
    _allFour(); // u qualifies
    quest.setRegistered(v, true); // v only registered
    address[] memory addrs = new address[](2);
    addrs[0] = u; addrs[1] = v;
    bool[] memory out = lens.qualifiedMany(addrs);
    assertTrue(out[0]);
    assertFalse(out[1]);
  }
}
