// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IKoinMinter {
    function isMinter(address) view external returns(bool);
    function amountKoinToMint(uint bnbProfit) view external returns(uint);
    function amountKoinToMintForKoinBNB(uint amount, uint duration) view external returns(uint);
    function withdrawalFee(uint amount, uint depositedAt) view external returns(uint);
    function performanceFee(uint profit) view external returns(uint);
    function mintFor(address flip, uint _withdrawalFee, uint _performanceFee, address to, uint depositedAt) external;
    function mintForKoinBNB(uint amount, uint duration, address to) external;

    function koinPerProfitBNB() view external returns(uint);
    function WITHDRAWAL_FEE_FREE_PERIOD() view external returns(uint);
    function WITHDRAWAL_FEE() view external returns(uint);

    function setMinter(address minter, bool canMint) external;
}
