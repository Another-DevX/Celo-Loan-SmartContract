// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract SmartContractCELO is Pausable, Ownable, ReentrancyGuard {
    uint256 public constant INTEREST_RATE_PER_DAY = 5;
    uint256 public constant INTEREST_PERIOD = 24 hours;

    IERC20 public cUSDToken;
    uint256 public totalFunds;
    uint256 public totalInterest;
    AggregatorV3Interface public priceFeed;

    constructor(address _cUSDTokenAddress, address _priceFeedAddress)
        Ownable(msg.sender)
    {
        cUSDToken = IERC20(_cUSDTokenAddress);
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
    }

    struct Lending {
        uint256 amount;
        uint256 startDate;
        uint256 blockMonths;
    }

    struct Lender {
        address lender;
        uint256 aggreedQuota;
        Lending[] lendings;
    }

    mapping(address => bool) public whitelist;
    mapping(address => uint256) public property;
    mapping(address => Lender) public lenders;

    event WhitelistedUserAdded(address indexed user);
    event WhitelistedUserRemoved(address indexed user);
    event LoanRequested(
        address indexed borrower,
        uint256 amount,
        uint16 blockMonths
    );
    event QuotaAdjusted(address indexed lender, uint256 newQuota);
    event PaymentMade(
        address indexed borrower,
        uint256 lendingIndex,
        uint256 amountPaid,
        uint256 remainingDebt
    );
    event LoanFullyRepaid(address indexed borrower, uint256 lendingIndex);

    function capitalize(uint256 _amount) external whenNotPaused {
        require(_amount > 0, "Amount must be greater than 0");
        require(
            cUSDToken.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
        property[msg.sender] += _amount;
        totalFunds += _amount;
    }

    function accrueInterest(address _lender, uint256 _lendingIndex) internal {
        Lending storage lending = lenders[_lender].lendings[_lendingIndex];
        uint256 timeElapsed = block.timestamp - lending.startDate;

        if (timeElapsed >= INTEREST_PERIOD) {
            uint256 periodsElapsed = timeElapsed / INTEREST_PERIOD;
            uint256 interestAmount = ((lending.amount * INTEREST_RATE_PER_DAY) /
                100) * periodsElapsed;
            lending.amount += interestAmount;
            totalInterest += interestAmount;
            lending.startDate += periodsElapsed * INTEREST_PERIOD;
        }
    }

    function payDebt(uint256 _lendingIndex, uint256 _amount)
        external
        whenNotPaused
        nonReentrant
    {
        require(_amount > 0, "Payment amount must be greater than 0");
        Lender storage lender = lenders[msg.sender];
        require(
            _lendingIndex < lender.lendings.length,
            "Invalid lending index"
        );
        Lending storage lending = lender.lendings[_lendingIndex];

        accrueInterest(msg.sender, _lendingIndex);

        require(lending.amount > 0, "No active debt to pay");
        require(_amount <= lending.amount, "Payment exceeds the debt amount");

        require(
            cUSDToken.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );

        lending.amount -= _amount;

        emit PaymentMade(msg.sender, _lendingIndex, _amount, lending.amount);

        if (lending.amount == 0) {
            emit LoanFullyRepaid(msg.sender, _lendingIndex);

            removeLending(msg.sender, _lendingIndex);
        }
    }

    function removeLending(address _lender, uint256 _lendingIndex) internal {
        Lender storage lender = lenders[_lender];
        uint256 lastLendingIndex = lender.lendings.length - 1;

        if (_lendingIndex < lastLendingIndex) {
            lender.lendings[_lendingIndex] = lender.lendings[lastLendingIndex];
        }

        lender.lendings.pop();
    }

    function increaseQuota(address _lender, uint256 _amount)
        external
        onlyOwner
    {
        require(_amount > 0, "Increase amount must be greater than 0");
        require(_lender != address(0), "Invalid lender address");

        Lender storage lender = lenders[_lender];
        lender.aggreedQuota += _amount;

        emit QuotaAdjusted(_lender, lender.aggreedQuota);
    }

    // Function for the owner to decrease a lender's quota
    function decreaseQuota(address _lender, uint256 _amount)
        external
        onlyOwner
    {
        require(_amount > 0, "Decrease amount must be greater than 0");
        require(_lender != address(0), "Invalid lender address");

        Lender storage lender = lenders[_lender];
        require(
            lender.aggreedQuota >= _amount,
            "Decrease amount exceeds the agreed quota"
        );

        lender.aggreedQuota -= _amount;

        emit QuotaAdjusted(_lender, lender.aggreedQuota);
    }

    function getActiveLoans(address _lender)
        external
        view
        returns (Lending[] memory)
    {
        Lender storage lender = lenders[_lender];
        uint256 activeCount = 0;

        for (uint256 i = 0; i < lender.lendings.length; i++) {
            if (lender.lendings[i].amount > 0) {
                activeCount++;
            }
        }

        Lending[] memory activeLoans = new Lending[](activeCount);
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < lender.lendings.length; i++) {
            if (lender.lendings[i].amount > 0) {
                activeLoans[currentIndex] = lender.lendings[i];
                currentIndex++;
            }
        }

        return activeLoans;
    }

    function requestLoan(uint256 _amount, uint16 _blockMonths)
        external
        whenNotPaused
    {
        require(
            whitelist[msg.sender],
            "The current address is not able to get a loan"
        );
        require(_amount > 0, "The amount is invalid");
        require(
            lenders[msg.sender].aggreedQuota >= _amount,
            "The agreed quota is insuficent"
        );
        lenders[msg.sender].aggreedQuota -= _amount;
        lenders[msg.sender].lendings.push(
            Lending({
                amount: _amount,
                startDate: block.timestamp,
                blockMonths: _blockMonths
            })
        );

        require(
            cUSDToken.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
        emit LoanRequested(msg.sender, _amount, _blockMonths);
    }

    function addToWhitelist(address _user) external onlyOwner {
        require(_user != address(0), "Invalid address");
        require(!whitelist[_user], "User already whitelisted");
        whitelist[_user] = true;
        emit WhitelistedUserAdded(_user);
    }

    function removeFromWhitelist(address _user) external onlyOwner {
        require(_user != address(0), "Invalid address");
        require(whitelist[_user], "User not whitelisted");
        whitelist[_user] = false;
        emit WhitelistedUserRemoved(_user);
    }

    function withdrawFunds() external whenNotPaused nonReentrant {
        uint256 userFunds = property[msg.sender];
        require(userFunds > 0, "No funds to withdraw");
        require(totalFunds >= userFunds, "Insufficient funds in the contract");
        uint256 userPercentage = (userFunds * 1e18) / totalFunds;
        uint256 userInterest = (totalInterest * userPercentage) / 1e18;
        uint256 amountToWithdraw = userFunds + userInterest;

        uint256 contractBalance = cUSDToken.balanceOf(address(this));
        require(
            contractBalance >= amountToWithdraw,
            "Contract has insufficient funds"
        );

        totalFunds -= userFunds;
        totalInterest -= userInterest;
        property[msg.sender] = 0;
        require(
            cUSDToken.transfer(msg.sender, amountToWithdraw),
            "Failed to send funds"
        );
    }
}
