// SPDX-License-Identifier: MIT

pragma solidity >=0.8.11;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETHGateway} from './interfaces/IWETHGateway.sol';
import "hardhat/console.sol";


error EtherTransferFailed();
error NeedsMoreThanZero();
error ZeroAddress();

contract StakingEthersContract is Ownable, ReentrancyGuard {

    string public constant name = "Staking ethers smart contract";

    // IWETHGateway interface
    IWETHGateway immutable iWethGateway;
    // Lending Pool address for the Aave (v3) lending pool
    address immutable lendingPoolAddress;
    // Contract Address for the aWeth tokens generated after depositing ETH
    // to keep track of the amount deposited in the lending pool
    address immutable aWethAddress;

    // time constant in seconds, lock period
    uint256 immutable lockPeriod; 

    uint private constant granularPrecision = 1e12;
    // Early withdrawal penalties when there are
    // no other users left in the pool to be distributed.
    // It's allocated to the contract owner!
    uint256 private unallocatedRewards;
    // current number of participants
    uint256 private stakersCount;
    // current amount of deposited balance
    uint256 private totalStakedBalance;
    // last calculated reward factor in the system
    uint256 private lastRewardFactor; 

/*
    Algorithm explanation.
    Let's define:
        R - rewards amount generated by the early withdrawal penalties
        S - current staked amount

    1. withdrawal user 1 -> factor = R1/S1 
    2. deposit user 2
    3. withdrawal user3  -> factor = R1/S1 + R3/S3
    4. deposit user 2 or withdrawal user 2

    At the step 4:
    User2 has 'factor = R1/S1' stored in his 'stakeInfo'
    User2 get 'factor = R1/S1 + R3/S3' from the global state variable

    User2 can calculate diff_factor:
    diff_factor = R1/S1 + R3/S3 - R1/S1
    diff_factor = R3/S3

    User2 can calculate his piece of reward generated by the user3 penalties:
    reward = deposit_user_2 * R3/S3

    Of course if there wasn't penalties from withdrawal of user3, factor
    will be the same as previous (step 1), and diff_factor = 0.
    So no rewards for user 2.

    It means constant complexity O(1) is achieved for rewards distribution
    (no iterations and looping).

*/
    // info about user history of deposits
    struct stakeInfo {       
        // last time user made deposit 
        uint256 depositTime;  
        // sum of all deposits by the user       
        uint256 curStakedAmount;   
        // rewardFactor is updated with the global one,  
        // last time reward distribution is calculated
        // for this user
        uint256 lastRewardFactor;    
        // current calculated amount of ETH rewards for 
        // the user to receive once he left the pool
        uint256 rewardAmount;
    }

    mapping(address => stakeInfo) private stakers;


    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert NeedsMoreThanZero();
        }
        _;
    }

    modifier isZeroAddress(address _address) {
        if (_address == address(0)) {
            revert ZeroAddress();
        }
        _;
    }

    modifier distributeRewards(address _address)  {
        // true - no rewards so no distribution
        // 1 - check if this is the new user in the system
        // 2 - check if there wasn't withdrawals yet
        // 3 - check if there wasn't early withdrawal penalties for distribution
        //     after last time updated this user rewards
        bool no_rewards = stakers[_address].depositTime == 0 || 
                          lastRewardFactor == 0 || 
                          stakers[_address].lastRewardFactor == lastRewardFactor;

        if(no_rewards == false) {
            // calculate user rewards
            // update rewardAmount
            stakers[_address].rewardAmount += (lastRewardFactor - stakers[_address].lastRewardFactor) *
                                              stakers[_address].curStakedAmount / granularPrecision;
        }
            
        // 'Dust' or remainders could exist on the contract balance 
        // from the calculations on the Reward pool supply.
        // There are not tracked, but could be distributed to the last
        // user in the pool or even contract owner.
           
        _;
    }

    event Staked(address indexed from, uint256 amount, uint256 time);
    event Unstaked(address indexed from, uint256 amount, uint256 inRewardPool, uint256 time);
    event OwnerIncomeWithdrawn(address indexed from, uint256 amount, uint256 time);
    event OwnerGotRewards(address indexed from, address indexed owner, uint256 amount, uint256 time);
    event OwnerRewardsWithdrawn(address indexed from, uint256 amount, uint256 time);
    

    constructor(uint256 _lockPeriod, address _wETHGateway, address _aWETH, address _lendingPoolAddress) 
        moreThanZero(_lockPeriod) 
        isZeroAddress(_wETHGateway)
        isZeroAddress(_aWETH)
        isZeroAddress(_lendingPoolAddress)
    {
        lockPeriod = _lockPeriod;

        iWethGateway = IWETHGateway(_wETHGateway);
        aWethAddress = _aWETH;
        lendingPoolAddress = _lendingPoolAddress;
    }    

    // Override Ownable renounceOwnership function
    function renounceOwnership() public view override onlyOwner {
        require(false, "Can't renounce contract ownership.");
    }

    // there are no constraints for minimal deposits in ETH
    // visibility 'public' because user can send ethers
    // through receive function 
    function depositETH() public payable
        moreThanZero(msg.value)  
        distributeRewards(msg.sender)
        nonReentrant        
    {      

        if(stakers[msg.sender].depositTime == 0) {
            // new user
            stakersCount++;
        }

        // update the participant staking info
        stakers[msg.sender].curStakedAmount += msg.value;
        // reset lock period
        stakers[msg.sender].depositTime = block.timestamp;
        // update factor with the new one in the system        
        stakers[msg.sender].lastRewardFactor = lastRewardFactor;

        // update the staking global info
        totalStakedBalance += msg.value;

        // Deposit ethers throuh WETHGateway
        // Converts ETH to WETH and fund the AAVE lending pool
        sendDepositsToAAVE(msg.value);

        emit Staked(msg.sender, msg.value, block.timestamp);
    }    

    function withdrawETH() external 
        distributeRewards(msg.sender)       
        nonReentrant         
    {
                
        require(stakers[msg.sender].depositTime != 0, "You are not participant!");
               
        uint256 t_diff = block.timestamp - stakers[msg.sender].depositTime;
  
        uint256 stakedAmount = stakers[msg.sender].curStakedAmount;
        uint256 amountToWithdraw = stakedAmount;
        uint256 amountToRewardPool = 0;

        if(t_diff < lockPeriod){
            // there are early withdrawal penalties.
            // % of half total staked amount

            // assert(stakedAmount*t_diff>=2*lockPeriod);
            // if this condition is not fulfilled, the user
            // will lose half of staked ethers anycase,
            // if he doesn't wait until the end of lock period

            uint256 amountUnlocked = stakedAmount * t_diff / (2*lockPeriod);
            // half amount is unlocked anyway + time based unlocked amount 
            amountToWithdraw = stakedAmount / 2 + amountUnlocked;
            // rest for the reward pool and distributed to the other stakers
            amountToRewardPool = stakedAmount - amountToWithdraw;
        }

        // user's unlocked amount + rewards from other users
        amountToWithdraw += stakers[msg.sender].rewardAmount;

        // update the staking global info       
        stakersCount--;
        totalStakedBalance -= stakedAmount;

        if(totalStakedBalance==0){
            // there are no users left in the staking pool,
            // so no users for reward distribution.
            // If any, then allocate amount for the contract owner!
            unallocatedRewards += amountToRewardPool;
            emit OwnerGotRewards(msg.sender, owner(), unallocatedRewards, block.timestamp);
        }

        // update global rewardFactor
        lastRewardFactor = calculateRewardFactor(amountToRewardPool, totalStakedBalance);

        // free up contract storage space to refund the transaction caller
        delete stakers[msg.sender];

        // Withdraw ethers throuh WETH Gateway
        // Converts back the WETH to ETH and send it to this contract
        withdrawDepositsFromAAVE(amountToWithdraw);

        uint256 _amountToWithdraw = amountToWithdraw;
        amountToWithdraw = 0;      

        // transfer ETH to the caller.
        // maybe constraint with gas cost, because cross-contract attack.
        (bool success,) = msg.sender.call{value:_amountToWithdraw}("");
        if (!success) {
            revert EtherTransferFailed(); 
        }  

        emit Unstaked(msg.sender, _amountToWithdraw, amountToRewardPool, block.timestamp);
    }

    function calculateRewardFactor(uint rewards, uint balance) internal view returns(uint256) {
        if(balance == 0){
            // no users left in the pool
            // so reset current factor
            return 0;
        }
        if(rewards==0){
            // no change, factor is still same
            return lastRewardFactor;
        }
        // add to the previous factor and calculate the new one
        return lastRewardFactor + rewards * granularPrecision / balance;
    }

    function sendDepositsToAAVE(uint256 amount) internal {
        // onBehalfOf - this contract
        iWethGateway.depositETH{value: amount}(lendingPoolAddress, address(this), 0);
    }
    function withdrawDepositsFromAAVE(uint256 amount) internal {
        // require(getContractAWETHBalance() >= amount, "Insufficent account balance!");
        // ERC20 allowance of aWETH, and WETHGateway contract will burn aWETH
        IERC20(aWethAddress).approve(address(iWethGateway), amount);
        // Withdraw ethers throuh WETH Gateway
        iWethGateway.withdrawETH(lendingPoolAddress, amount, address(this));
    }

    // Check the balance of aWeth tokens for this contract address
    function getContractAWETHBalance() internal view returns(uint) {
        return IERC20(aWethAddress).balanceOf(address(this));
    }

   // contract owner is able to remove the passive income from the lending pool.
    function withdrawOwnerRemainingProfit() 
        external
        onlyOwner
        nonReentrant
    {

        // get balance in the Aave v3 lending pool
        uint aWETHBalance = getContractAWETHBalance();
        require(aWETHBalance>totalStakedBalance, "Currently there are no passive income!");
        
        // if there are interests generated by staking in the AAVE lending pool
        uint income = aWETHBalance-totalStakedBalance;
        // Withdraw profit throuh WETH Gateway
        withdrawDepositsFromAAVE(income);

        uint _income = income;
        // reset
        income = 0;

        // transfer ETH to the caller. It's contract owner.
        (bool success,) = msg.sender.call{value:_income}("");
        if (!success) {
            revert EtherTransferFailed(); 
        }  

        emit OwnerIncomeWithdrawn(msg.sender, _income, block.timestamp);
    }

   // contract owner is able to remove the unallocated rewards generated by early withdrawal penalties.
   // case when user is alone in the pool and do withrawal before lock period has expired.
    function withdrawOwnerUnallocatedRewards() 
        external
        onlyOwner
        nonReentrant
    {
        require(unallocatedRewards > 0, "There are no unallocated rewards at the moment!");

        // Currently, unallocated rewards are staked in the Aave v3 lending pool
        // to make to the owner a passive income. Withdraw from there first.
        withdrawDepositsFromAAVE(unallocatedRewards);

        uint256 _unallocatedRewards = unallocatedRewards;
        // reset state variable
        unallocatedRewards = 0;

        // transfer ETH to the caller. It's contract owner.
        (bool success,) = msg.sender.call{value:_unallocatedRewards}("");
        if (!success) {
            revert EtherTransferFailed(); 
        }  

        emit OwnerRewardsWithdrawn(msg.sender, _unallocatedRewards, block.timestamp);
    }

    receive() external payable {
       // Regarding WETH gateway, receive function is needed because withdrawETH 
       // is sending funds to the contract without call data

       if(msg.sender != address(iWethGateway)){
            // if the user send transaction without
            // message data field can stake
            depositETH();
       }       
    } 

    fallback() external payable {
        revert('Fallback not allowed');
    }

    function getCurrentNumberOfUsers() external view returns(uint256) {
        return stakersCount;
    }

    function getCurrentStakedBalance() external view returns(uint256) {
        return totalStakedBalance;
    }

    function getOwnersUnallocatedBalance() external view returns(uint256) {
        return unallocatedRewards;
    }

    function getUserStakedAmount() external view returns(uint256) {
        require(stakers[msg.sender].depositTime != 0, "You are not participant!");
        return stakers[msg.sender].curStakedAmount;
    }

    function getUserStakeInfo() external view returns(stakeInfo memory) {
        require(stakers[msg.sender].depositTime != 0, "You are not participant!");
        return stakers[msg.sender];
    }
}
