// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

/*
  ___                      _   _
 | _ )_  _ _ _  _ _ _  _  | | | |
 | _ \ || | ' \| ' \ || | |_| |_|
 |___/\_,_|_||_|_||_\_, | (_) (_)
                    |__/

*
* MIT License
* ===========
*
* Copyright (c) 2020 KoinFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";

import "../interfaces/IKoinMinterV2.sol";
import "../interfaces/legacy/IStakingRewards.sol";
import "../dashboard/calculator/PriceCalculatorBSC.sol";
import "../zap/ZapBSC.sol";

contract KoinMinterV2 is IKoinMinterV2, OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant KOIN = 0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51;
    address public constant KOIN_BNB = 0x7Bb89460599Dbf32ee3Aa50798BBcEae2A5F7f6a;
    address public constant KOIN_POOL = 0xCADc8CB26c8C7cB46500E61171b5F27e9bd7889D;

    address public constant DEPLOYER = 0xe87f02606911223C2Cf200398FFAF353f60801F7;
    address private constant TIMELOCK = 0x85c9162A51E03078bdCd08D4232Bab13ed414cC3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint public constant FEE_MAX = 10000;

    ZapBSC public constant zapBSC = ZapBSC(0xCBEC8e7AB969F6Eb873Df63d04b4eAFC353574b1);
    PriceCalculatorBSC public constant priceCalculator = PriceCalculatorBSC(0x542c06a5dc3f27e0fbDc9FB7BC6748f26d54dDb0);

    /* ========== STATE VARIABLES ========== */

    address public koinChef;
    mapping(address => bool) private _minters;
    address public _deprecated_helper; // deprecated

    uint public PERFORMANCE_FEE;
    uint public override WITHDRAWAL_FEE_FREE_PERIOD;
    uint public override WITHDRAWAL_FEE;

    uint public override koinPerProfitBNB;
    uint public koinPerKoinBNBFlip;   // will be deprecated

    /* ========== MODIFIERS ========== */

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "KoinMinterV2: caller is not the minter");
        _;
    }

    modifier onlyKoinChef {
        require(msg.sender == koinChef, "KoinMinterV2: caller not the koin chef");
        _;
    }

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
        WITHDRAWAL_FEE = 50;
        PERFORMANCE_FEE = 3000;

        koinPerProfitBNB = 5e18;
        koinPerKoinBNBFlip = 6e18;

        IBEP20(KOIN).approve(KOIN_POOL, uint(-1));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferKoinOwner(address _owner) external onlyOwner {
        Ownable(KOIN).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");
        // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external override onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setKoinPerProfitBNB(uint _ratio) external onlyOwner {
        koinPerProfitBNB = _ratio;
    }

    function setKoinPerKoinBNBFlip(uint _koinPerKoinBNBFlip) external onlyOwner {
        koinPerKoinBNBFlip = _koinPerKoinBNBFlip;
    }

    function setKoinChef(address _koinChef) external onlyOwner {
        require(koinChef == address(0), "KoinMinterV2: setKoinChef only once");
        koinChef = _koinChef;
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(KOIN).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountKoinToMint(uint bnbProfit) public view override returns (uint) {
        return bnbProfit.mul(koinPerProfitBNB).div(1e18);
    }

    function amountKoinToMintForKoinBNB(uint amount, uint duration) public view override returns (uint) {
        return amount.mul(koinPerKoinBNBFlip).mul(duration).div(365 days).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) external view override returns (uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) public view override returns (uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    /* ========== V1 FUNCTIONS ========== */

    function mintFor(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint) external payable override onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        _transferAsset(asset, feeSum);

        if (asset == KOIN) {
            IBEP20(KOIN).safeTransfer(DEAD, feeSum);
            return;
        }

        uint koinBNBAmount = _zapAssetsToKoinBNB(asset);
        if (koinBNBAmount == 0) return;

        IBEP20(KOIN_BNB).safeTransfer(KOIN_POOL, koinBNBAmount);
        IStakingRewards(KOIN_POOL).notifyRewardAmount(koinBNBAmount);

        (uint valueInBNB,) = priceCalculator.valueOfAsset(KOIN_BNB, koinBNBAmount);
        uint contribution = valueInBNB.mul(_performanceFee).div(feeSum);
        uint mintKoin = amountKoinToMint(contribution);
        if (mintKoin == 0) return;
        _mint(mintKoin, to);
    }

    // @dev will be deprecated
    function mintForKoinBNB(uint amount, uint duration, address to) external override onlyMinter {
        uint mintKoin = amountKoinToMintForKoinBNB(amount, duration);
        if (mintKoin == 0) return;
        _mint(mintKoin, to);
    }

    /* ========== V2 FUNCTIONS ========== */

    function mint(uint amount) external override onlyKoinChef {
        if (amount == 0) return;
        _mint(amount, address(this));
    }

    function safeKoinTransfer(address _to, uint _amount) external override onlyKoinChef {
        if (_amount == 0) return;

        uint bal = IBEP20(KOIN).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(KOIN).safeTransfer(_to, _amount);
        } else {
            IBEP20(KOIN).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Koin is transferred to the timelock contract.
    function mintGov(uint amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, TIMELOCK);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _transferAsset(address asset, uint amount) private {
        if (asset == address(0)) {
            // case) transferred BNB
            require(msg.value >= amount);
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _zapAssetsToKoinBNB(address asset) private returns (uint) {
        if (asset != address(0) && IBEP20(asset).allowance(address(this), address(zapBSC)) == 0) {
            IBEP20(asset).safeApprove(address(zapBSC), uint(-1));
        }

        if (asset == address(0)) {
            zapBSC.zapIn{value : address(this).balance}(KOIN_BNB);
        }
        else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("Cake-LP")) {
            zapBSC.zapOut(asset, IBEP20(asset).balanceOf(address(this)));

            IPancakePair pair = IPancakePair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == WBNB || token1 == WBNB) {
                address token = token0 == WBNB ? token1 : token0;
                if (IBEP20(token).allowance(address(this), address(zapBSC)) == 0) {
                    IBEP20(token).safeApprove(address(zapBSC), uint(-1));
                }
                zapBSC.zapIn{value : address(this).balance}(KOIN_BNB);
                zapBSC.zapInToken(token, IBEP20(token).balanceOf(address(this)), KOIN_BNB);
            } else {
                if (IBEP20(token0).allowance(address(this), address(zapBSC)) == 0) {
                    IBEP20(token0).safeApprove(address(zapBSC), uint(-1));
                }
                if (IBEP20(token1).allowance(address(this), address(zapBSC)) == 0) {
                    IBEP20(token1).safeApprove(address(zapBSC), uint(-1));
                }

                zapBSC.zapInToken(token0, IBEP20(token0).balanceOf(address(this)), KOIN_BNB);
                zapBSC.zapInToken(token1, IBEP20(token1).balanceOf(address(this)), KOIN_BNB);
            }
        }
        else {
            zapBSC.zapInToken(asset, IBEP20(asset).balanceOf(address(this)), KOIN_BNB);
        }

        return IBEP20(KOIN_BNB).balanceOf(address(this));
    }

    function _mint(uint amount, address to) private {
        BEP20 tokenKOIN = BEP20(KOIN);

        tokenKOIN.mint(amount);
        if (to != address(this)) {
            tokenKOIN.transfer(to, amount);
        }

        uint koinForDev = amount.mul(15).div(100);
        tokenKOIN.mint(koinForDev);
        IStakingRewards(KOIN_POOL).stakeTo(koinForDev, DEPLOYER);
    }
}
