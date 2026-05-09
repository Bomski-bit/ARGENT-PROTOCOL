// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title ArgentProtocol
 * @author Ogolo Boma
 * @notice A decentralized finance protocol for managing collateral and debt positions.
 */
contract ArgentProtocol is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    //////////////////////////////////////////////////////////////////////////////////////////
    //                                 ERRORS
    //////////////////////////////////////////////////////////////////////////////////////////

    error Argent__AssetNotSupported();
    error Argent__InvalidAmount();
    error Argent__InsufficientLiquidity();
    error Argent__InsufficientTotalLiquidity();
    error Argent__PositionUnhealthy();
    error Argent__InvalidAsset();
    error Argent__FeeTooHigh();
    error Argent__InvalidAddress();
    error Argent__InvalidParameter();
    error Argent__InsufficientCollateral();
    error Argent__CannotLiquidateSelf();
    error Argent__NoDebt();
    error Argent__NoDebtInAsset();
    error Argent__BonusTooHigh();

    //////////////////////////////////////////////////////////////////////////////////////////
    //                             TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////////////////////////////////
    /// @notice Enum representing the status of an asset in the protocol
    enum AssetStatus {
        INACTIVE,
        FROZEN,
        ACTIVE
    }

    /// @notice Configuration for each supported asset
    struct AssetConfig {
        AssetStatus status; // Status of the asset (INACTIVE, FROZEN, ACTIVE)
        uint256 ltv; // Loan-to-value ratio (basis points, e.g., 7000 = 70%)
        uint256 liquidationThreshold; // Threshold for liquidation (basis points, e.g., 8000 = 80%)
        uint256 interestRate; // Annual interest rate (basis points, e.g., 500 = 5%)
        uint8 decimals; // Token decimals for proper scaling
    }

    //////////////////////////////////////////////////////////////////////////////////////////
    //                             STATE VARIABLES
    //////////////////////////////////////////////////////////////////////////////////////////

    // ========================================
    // MAPPINGS
    // ========================================

    /// @notice Tracks user's collateral deposits per asset
    /// @dev user address => asset address => amount
    mapping(address => mapping(address => uint256)) private userCollateral;

    /// @notice Tracks user's outstanding debt per asset
    /// @dev user address => asset address => debt amount
    mapping(address => mapping(address => uint256)) private userDebt;

    /// @notice Tracks user's liquidity deposits per asset
    /// @dev user address => asset address => liquidity amount
    mapping(address => mapping(address => uint256)) private userLiquidityDeposits;

    /// @notice Tracks user's debt index snapshot for interest calculation
    /// @dev user address => asset address => index snapshot
    mapping(address => mapping(address => uint256)) private userDebtIndex;

    /// @notice Configuration for each asset
    mapping(address => AssetConfig) public assetConfig;

    /// @notice Global borrow index for each asset (tracks accumulated interest)
    mapping(address => uint256) private borrowIndex;

    /// @notice Last timestamp when interest was accrued for an asset
    mapping(address => uint256) public lastAccrualTimestamp;

    /// @notice Total deposits in the protocol per asset
    mapping(address => uint256) public totalDeposits;

    /// @notice Total borrows from the protocol per asset
    mapping(address => uint256) public totalBorrows;

    /// @notice Total liquidity available in the protocol per asset (deposits - borrows)
    mapping(address => uint256) public totalLiquidity;

    /// @notice Protocol fees accumulated per asset
    mapping(address => uint256) public protocolFeesAccrued;

    /// @notice Tracks assets a user currently has collateral or debt in for efficient iteration
    mapping(address => address[]) private userActiveAssets;

    /// @notice Checks if the user has an assest in his userActiveAssets array for efficient iteration.
    mapping(address => mapping(address => bool)) private userHasAsset;

    // ========================================
    // MUTABLES
    // ========================================

    /// @notice Address where protocol fees are sent
    address public treasury;

    /// @notice Protocol fee percentage (basis points, e.g., 1500 = 15%)
    uint256 public protocolFee;

    /// @notice Liquidation bonus for liquidators (basis points, e.g., 800 = 15%)
    uint256 public liquidationBonus;

    /// @notice Reference to the custom PriceOracle contract
    IPriceOracle public priceOracle;

    // ========================================
    // CONSTANTS
    // ========================================

    /// @notice Basis points denominator (100% = 10000 basis points)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Initial borrow index value
    uint256 public constant INITIAL_INDEX = 1e18;

    /// @notice Precision for price bridge calculations (to handle differences in decimals)
    uint256 public constant PRICE_BRIDGE_PRECISION = 1e10;

    /// @notice Seconds in a year for interest calculations
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice USD price precision (8 decimals to match Chainlink)
    uint256 public constant PRICE_PRECISION = 1e8;

    /// @notice Maximum protocol fee allowed (50%)
    uint256 public constant MAX_PROTOCOL_FEE = 5_000;

    // ========================================
    // ARRAYS
    // ========================================

    /// @notice Array of all supported asset addresses for iteration
    address[] public supportedAssets;

    //////////////////////////////////////////////////////////////////////////////////////////
    //                                 EVENTS
    //////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Emitted when a user deposits collateral
     * @param user The address of the user depositing collateral
     * @param asset The address of the collateral asset
     * @param amount The amount of collateral deposited
     */
    event CollateralDeposited(address indexed user, address indexed asset, uint256 indexed amount);

    /**
     * @notice Emitted when a user withdraws collateral
     * @param user The address of the user withdrawing collateral
     * @param asset The address of the collateral asset
     * @param amount The amount of collateral withdrawn
     */
    event CollateralWithdrawn(address indexed user, address indexed asset, uint256 indexed amount);

    /**
     * @notice Emitted when a user borrows an asset
     * @param user The address of the user borrowing
     * @param asset The address of the borrowed asset
     * @param amount The amount of the asset borrowed
     */
    event LiquidityDeposited(address indexed user, address indexed asset, uint256 indexed amount);

    /**
     * @notice Emitted when a user withdraws borrowed asset
     * @param user The address of the user withdrawing liquidity
     * @param asset The address of the asset withdrawn
     * @param amount The amount of the asset withdrawn
     */
    event LiquidityWithdrawn(address indexed user, address indexed asset, uint256 indexed amount);

    /**
     * @notice Emitted when a user borrows an asset
     * @param user The address of the user borrowing
     * @param asset The address of the borrowed asset
     * @param amount The amount of the asset borrowed
     */
    event Borrowed(address indexed user, address indexed asset, uint256 indexed amount);

    /**
     * @notice Emitted when a user repays a loan
     * @param user The address of the user repaying
     * @param asset The address of the asset repaid
     * @param amount The amount of the asset repaid
     */
    event Repaid(address indexed user, address indexed asset, uint256 indexed amount);

    /**
     * @notice Emitted when a user's position is liquidated
     * @param liquidator The address of the user liquidating the position
     * @param user The address of the user whose position is being liquidated
     * @param debtAsset The address of the debt asset
     * @param collateralAsset The address of the collateral asset
     * @param debtRepaid The amount of debt repaid
     * @param collateralSeized The amount of collateral seized
     */
    event Liquidated(
        address indexed liquidator,
        address indexed user,
        address indexed debtAsset,
        address collateralAsset,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    /**
     * @notice Emitted when interest is accrued on an asset
     * @param asset The address of the asset
     * @param newIndex The new interest index
     */
    event InterestAccrued(address indexed asset, uint256 indexed newIndex);

    /**
     * @notice Emitted when an asset is added to the protocol
     * @param asset The address of the asset
     * @param ltv The loan-to-value ratio for the asset
     * @param liquidationThreshold The liquidation threshold for the asset
     * @param interestRate The interest rate for the asset
     */
    event AssetAdded(
        address indexed asset, uint256 indexed ltv, uint256 indexed liquidationThreshold, uint256 interestRate
    );

    /**
     * @notice Emitted when protocol fees are withdrawn
     * @param asset The address of the asset
     * @param amount The amount of fees withdrawn
     */
    event ProtocolFeesWithdrawn(address indexed asset, uint256 indexed amount);

    /**
     * @notice Emitted when the price oracle is updated
     * @param oldOracle The address of the old price oracle
     * @param newOracle The address of the new price oracle
     */
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);

    /**
     * @notice Emitted when an asset's status is updated
     * @param asset The address of the asset
     * @param oldStatus The previous status of the asset
     * @param newStatus The new status of the asset
     */
    event AssetStatusUpdated(address indexed asset, AssetStatus indexed oldStatus, AssetStatus indexed newStatus);

    /**
     * @notice Emitted when the liquidation bonus is updated
     * @param oldBonus The previous liquidation bonus in basis points
     * @param newBonus The new liquidation bonus in basis points
     */
    event LiquidationBonusUpdated(uint256 indexed oldBonus, uint256 indexed newBonus);

    /**
     * @notice Emitted when the protocol fee is updated
     * @param oldFee The previous protocol fee in basis points
     * @param newFee The new protocol fee in basis points
     */
    event ProtocolFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);

    /**
     * @notice Emitted when the treasury address is updated
     * @param oldTreasury The previous treasury address
     * @param newTreasury The new treasury address
     */
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    //////////////////////////////////////////////////////////////////////////////////////////
    //                                  FUNCTIONS
    //////////////////////////////////////////////////////////////////////////////////////////

    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initialize the lending protocol
     * @param _priceOracle Address of the custom PriceOracle contract
     * @param _treasury Address where protocol fees are sent
     * @param _protocolFee Protocol fee in basis points
     * @param _liquidationBonus Liquidation bonus in basis points
     */
    constructor(
        address _priceOracle,
        address _treasury,
        uint256 _protocolFee,
        uint256 _liquidationBonus,
        address _initialOwner
    ) Ownable(_initialOwner) {
        if (_initialOwner == address(0)) revert Argent__InvalidAddress();
        if (_priceOracle == address(0)) revert Argent__InvalidAddress();
        if (_treasury == address(0)) revert Argent__InvalidAddress();
        if (_protocolFee > BASIS_POINTS) revert Argent__FeeTooHigh();
        if (_liquidationBonus > BASIS_POINTS) revert Argent__BonusTooHigh();
        priceOracle = IPriceOracle(_priceOracle);
        treasury = _treasury;
        protocolFee = _protocolFee;
        liquidationBonus = _liquidationBonus;
    }

    // ========================================
    // PAUSE FUNCTIONALITY
    // ========================================

    /**
     * @notice Pause the protocol (emergency only)
     * @dev Only owner can pause. Prevents deposits, borrows, and withdrawals
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the protocol
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========================================
    // COLLATERAL MANAGEMENT
    // ========================================

    /**
     * @notice Deposit collateral into the protocol
     * @param asset Address of the collateral asset
     * @param amount Amount to deposit
     */
    function depositCollateral(address asset, uint256 amount) external nonReentrant whenNotPaused {
        if (assetConfig[asset].status != AssetStatus.ACTIVE) revert Argent__AssetNotSupported();
        if (amount == 0) revert Argent__InvalidAmount();

        // Update user's collateral balance
        _increaseCollateral(msg.sender, asset, amount);

        // Update total deposits for liquidity tracking
        totalDeposits[asset] += amount;

        // Transfer tokens from user to protocol
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralDeposited(msg.sender, asset, amount);
    }

    /**
     * @notice Withdraw collateral from the protocol
     * @param asset Address of the collateral asset
     * @param amount Amount to withdraw
     */
    function withdrawCollateral(address asset, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Argent__InvalidAmount();
        if (userCollateral[msg.sender][asset] < amount) revert Argent__InsufficientCollateral();

        // Accrue interest on every asset the user has debt in
        address[] storage activeAssets = userActiveAssets[msg.sender];
        for (uint256 i = 0; i < activeAssets.length; i++) {
            if (userDebt[msg.sender][activeAssets[i]] > 0) {
                accrueInterest(activeAssets[i]);
            }
        }

        // Decrease collateral first
        _decreaseCollateral(msg.sender, asset, amount);

        // Check if withdrawal maintains healthy position
        if (!_isWithdrawalHealthy(msg.sender)) revert Argent__PositionUnhealthy();

        // Update total deposits
        totalDeposits[asset] -= amount;

        // Transfer tokens back to user
        IERC20(asset).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    /**
     * @dev Internal function to increase user's collateral
     * @param user Address of the user
     * @param asset Address of the collateral asset
     * @param amount Amount to increase
     */
    function _increaseCollateral(address user, address asset, uint256 amount) internal {
        userCollateral[user][asset] += amount;
        _addUserAsset(user, asset);
    }

    /**
     * @dev Internal function to decrease user's collateral
     * @param user Address of the user
     * @param asset Address of the collateral asset
     * @param amount Amount to decrease
     */
    function _decreaseCollateral(address user, address asset, uint256 amount) internal {
        userCollateral[user][asset] -= amount;
        _removeUserAsset(user, asset);
    }

    // ========================================
    // LIQUIDITY MANAGEMENT
    // ========================================

    /**
     * @notice Deposit liquidity into the protocol
     * @param asset Address of the liquidity asset
     * @param amount Amount to deposit
     */
    function depositLiquidity(address asset, uint256 amount) external nonReentrant whenNotPaused {
        if (assetConfig[asset].status != AssetStatus.ACTIVE) revert Argent__AssetNotSupported();
        if (amount == 0) revert Argent__InvalidAmount();

        // Update user's liquidity deposit
        userLiquidityDeposits[msg.sender][asset] += amount;

        // Update total liquidity for the asset
        totalLiquidity[asset] += amount;

        // Transfer tokens from user to protocol
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit LiquidityDeposited(msg.sender, asset, amount);
    }

    /**
     * @notice Withdraw liquidity from the protocol
     * @param asset Address of the liquidity asset
     * @param amount Amount to withdraw
     */
    function withdrawLiquidity(address asset, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Argent__InvalidAmount();
        if (getAvailableLiquidity(asset) < amount) revert Argent__InsufficientTotalLiquidity();
        if (userLiquidityDeposits[msg.sender][asset] < amount) revert Argent__InsufficientLiquidity();

        // Decrease total liquidity for the asset
        totalLiquidity[asset] -= amount;

        // Decrease user's liquidity deposit
        userLiquidityDeposits[msg.sender][asset] -= amount;

        // Transfer tokens back to user
        IERC20(asset).safeTransfer(msg.sender, amount);

        emit LiquidityWithdrawn(msg.sender, asset, amount);
    }

    // ========================================
    // BORROWING & REPAYMENT
    // ========================================

    /**
     * @notice Borrow assets against deposited collateral
     * @param asset Address of the asset to borrow
     * @param amount Amount to borrow
     */
    function borrow(address asset, uint256 amount) external nonReentrant whenNotPaused {
        if (assetConfig[asset].status != AssetStatus.ACTIVE) revert Argent__AssetNotSupported();
        if (amount == 0) revert Argent__InvalidAmount();

        // Accrue interest on every asset the user has debt in before allowing new borrow
        accrueInterest(asset);

        if (!_hasSufficientLiquidity(asset, amount)) revert Argent__InsufficientLiquidity();
        if (!_canBorrow(msg.sender, asset, amount)) revert Argent__PositionUnhealthy();

        // Increase user's debt
        _increaseDebt(msg.sender, asset, amount);

        // Update total borrows
        totalBorrows[asset] += amount;

        // Transfer borrowed assets to user
        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, asset, amount);
    }

    /**
     * @notice Repay borrowed assets
     * @param asset Address of the borrowed asset
     * @param amount Amount to repay
     */
    function repay(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert Argent__InvalidAmount();

        // Accrue interest before repayment
        accrueInterest(asset);

        // Get user's current debt (with accrued interest)
        uint256 currentDebt = _getAccruedDebt(msg.sender, asset);
        if (currentDebt == 0) revert Argent__NoDebt();

        // Cap repayment at actual debt
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        // Transfer tokens from user to protocol
        IERC20(asset).safeTransferFrom(msg.sender, address(this), repayAmount);

        uint256 principalStored = userDebt[msg.sender][asset];

        // Calculate protocol fee on interest portion
        uint256 interestPaid = repayAmount > principalStored ? repayAmount - principalStored : 0;
        uint256 feeAmount = (interestPaid * protocolFee) / BASIS_POINTS;

        // Accrue protocol fees
        if (feeAmount > 0) protocolFeesAccrued[asset] += feeAmount;

        // Calculate interest accrued since last update to adjust total borrows correctly
        uint256 interestAccrued = currentDebt > principalStored ? currentDebt - principalStored : 0;

        // If there's interest accrued that hasn't been accounted for in totalBorrows, we need to add it before subtracting the repayment.
        if (interestAccrued > 0) {
            totalBorrows[asset] += interestAccrued;
        }

        // Decrease total borrows by the amount repaid (which includes principal + interest)
        totalBorrows[asset] -= repayAmount;

        // Decrease user's debt
        _decreaseDebt(msg.sender, asset, repayAmount);

        emit Repaid(msg.sender, asset, repayAmount);
    }

    /**
     * @dev Internal function to increase user's debt
     * @param user Address of the user
     * @param asset Address of the borrowed asset
     * @param amount Amount to increase (new borrow amount)
     */
    function _increaseDebt(address user, address asset, uint256 amount) internal {
        uint256 principalDebt = userDebt[user][asset];

        // If user has no existing debt, set their index snapshot to current index
        if (principalDebt == 0) {
            principalDebt = amount;
        } else {
            // Always realize accrued interest before modifying principal
            uint256 accruedDebt = _getAccruedDebt(user, asset);

            // If there's accrued interest, we need to roll it into the principal before adding the new borrow amount.
            uint256 interestRolledIn = accruedDebt - principalDebt;
            if (interestRolledIn > 0) {
                totalBorrows[asset] += interestRolledIn;
            }

            // Update principal to include accrued interest + new borrow
            principalDebt = accruedDebt + amount;
        }

        // Sync user index to current global index
        userDebt[user][asset] = principalDebt;
        userDebtIndex[user][asset] = borrowIndex[asset];

        // Add asset to user's active assets for iteration
        _addUserAsset(user, asset);
    }

    /**
     * @dev Internal function to decrease user's debt
     * @param user Address of the user
     * @param asset Address of the borrowed asset
     * @param amount Amount to decrease
     */
    function _decreaseDebt(address user, address asset, uint256 amount) internal {
        uint256 currentDebt = _getAccruedDebt(user, asset);

        if (amount >= currentDebt) {
            // Fully repaid
            userDebt[user][asset] = 0;
            userDebtIndex[user][asset] = 0;
        } else {
            // Partial repayment - update debt and index
            userDebt[user][asset] = currentDebt - amount;
            userDebtIndex[user][asset] = borrowIndex[asset];
        }

        // If user's debt in this asset is now zero, we can remove it from their active assets
        _removeUserAsset(user, asset);
    }

    // ========================================
    // INTEREST ACCRUAL
    // ========================================

    /**
     * @notice Accrue interest for an asset (updates global index)
     * @param asset Address of the asset
     */
    function accrueInterest(address asset) public {
        uint256 currentTime = block.timestamp;
        uint256 lastAccrual = lastAccrualTimestamp[asset];

        // Initialize on first call
        if (lastAccrual == 0) {
            borrowIndex[asset] = INITIAL_INDEX;
            lastAccrualTimestamp[asset] = currentTime;
            return;
        }

        // Skip if already accrued this block
        if (currentTime == lastAccrual) {
            return;
        }

        // Update the global interest index for this asset
        _updateInterestIndex(asset);
    }

    /**
     * @dev Updates the global interest index for an asset
     * @param asset Address of the asset to update
     */
    function _updateInterestIndex(address asset) internal {
        // Calculate time elapsed since last accrual
        uint256 timeDelta = block.timestamp - lastAccrualTimestamp[asset];

        // Calculate interest: rate * time / year
        uint256 interestRate = assetConfig[asset].interestRate;
        uint256 interestFactor = (interestRate * timeDelta * INITIAL_INDEX) / (SECONDS_PER_YEAR * BASIS_POINTS);

        // Update index: index * (1 + interestFactor)
        borrowIndex[asset] = (borrowIndex[asset] * (INITIAL_INDEX + interestFactor)) / INITIAL_INDEX;

        // Update timestamp
        lastAccrualTimestamp[asset] = block.timestamp;

        emit InterestAccrued(asset, borrowIndex[asset]);
    }

    /**
     * @dev Get user's debt with accrued interest
     * @param user Address of the user
     * @param asset Address of the borrowed asset
     */
    function _getAccruedDebt(address user, address asset) internal view returns (uint256) {
        uint256 principalDebt = userDebt[user][asset];
        if (principalDebt == 0) return 0;

        uint256 userIndex = userDebtIndex[user][asset];
        uint256 currentIndex = _getCurrentIndex(asset);

        // Debt = principal * (currentIndex / userIndex)
        return (principalDebt * currentIndex) / userIndex;
    }

    /**
     * @dev Calculate current index without updating state
     * @param asset Address of the asset
     */
    function _getCurrentIndex(address asset) internal view returns (uint256) {
        uint256 lastAccrual = lastAccrualTimestamp[asset];
        if (lastAccrual == 0) return INITIAL_INDEX;

        // Calculate time elapsed since last accrual
        uint256 timeDelta = block.timestamp - lastAccrual;
        if (timeDelta == 0) return borrowIndex[asset];

        // Calculate interest factor for the time elapsed
        uint256 interestRate = assetConfig[asset].interestRate;
        uint256 interestFactor = (interestRate * timeDelta * INITIAL_INDEX) / (SECONDS_PER_YEAR * BASIS_POINTS);

        // Current index = last index * (1 + interestFactor)
        return (borrowIndex[asset] * (INITIAL_INDEX + interestFactor)) / INITIAL_INDEX;
    }

    // ========================================
    // HEALTH FACTOR & COLLATERALIZATION
    // ========================================

    /**
     * @dev Check if user's position is healthy (CRITICAL FUNCTION)
     * @param user Address of the user
     * @return true if health factor >= 1,false otherwise
     */
    function _isPositionHealthy(address user) internal view returns (bool) {
        uint256 healthFactor = _calculateHealthFactor(user);
        return healthFactor >= INITIAL_INDEX; // HF >= 1.0
    }

    /**
     * @dev Check if withdrawal maintains healthy position
     * @param user Address of the user
     * @return true if withdrawal is safe, false if it would put position under collateralized
     */
    function _isWithdrawalHealthy(address user) internal view returns (bool) {
        // If no debt, withdrawal is always safe
        if (_getTotalDebtUSD(user) == 0) return true;

        return _isPositionHealthy(user);
    }

    /**
     * @dev Calculate health factor for a user
     * @param user Address of the user
     * @return Health factor scaled by 1e18 (1e18 = 1.0)
     */
    function _calculateHealthFactor(address user) internal view returns (uint256) {
        uint256 totalDebtUSD = _getTotalDebtUSD(user);

        // No debt = infinite health factor
        if (totalDebtUSD == 0) return type(uint256).max;

        uint256 totalCollateralUSD = _getTotalCollateralUSD(user);
        uint256 weightedThreshold = _getWeightedLiquidationThreshold(user);

        // HF = (collateral * liquidationThreshold) / debt
        // Multiply by 1e18 to keep HF precision (1e18 = HF of 1.0)
        return (totalCollateralUSD * weightedThreshold * INITIAL_INDEX) / (totalDebtUSD * BASIS_POINTS);
    }

    /**
     * @dev Get total collateral value in USD for a user
     * @param user Address of the user
     * @return Total collateral value scaled by 1e8 (USD with 8 decimals)
     */
    function _getTotalCollateralUSD(address user) internal view returns (uint256) {
        uint256 totalUSD = 0;

        // Loop through users assets
        address[] storage assets = userActiveAssets[user]; // only their assets
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 collateralAmount = userCollateral[user][assets[i]];
            if (collateralAmount > 0) {
                totalUSD += _getAssetValueUSD(assets[i], collateralAmount);
            }
        }

        return totalUSD;
    }

    /**
     * @dev Get total debt value in USD for a user
     * @param user Address of the user
     * @return Total debt value scaled by 1e8 (USD with 8 decimals)
     */
    function _getTotalDebtUSD(address user) internal view returns (uint256) {
        uint256 totalUSD = 0;

        // Loop through user's active assets
        address[] storage assets = userActiveAssets[user]; // only their assets
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 debtAmount = _getAccruedDebt(user, asset);

            if (debtAmount > 0) {
                // Get USD value of this debt
                totalUSD += _getAssetValueUSD(asset, debtAmount);
            }
        }

        return totalUSD;
    }

    /**
     * @dev Calculate weighted average liquidation threshold
     * Formula: Σ(collateralUSD × assetLT) / totalCollateralUSD
     * @param user Address of the user
     * @return Weighted average liquidation threshold in basis points (e.g., 8000 for 80%)
     */
    function _getWeightedLiquidationThreshold(address user) internal view returns (uint256) {
        uint256 totalCollateralUSD = 0;
        uint256 weightedSum = 0;

        // Loop through user's active assets
        address[] storage assets = userActiveAssets[user];
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 collateralAmount = userCollateral[user][asset];

            // Only consider assets with collateral for the weighted average
            if (collateralAmount > 0) {
                // Get USD value of the collateral and the asset's liquidation threshold
                uint256 collateralUSD = _getAssetValueUSD(asset, collateralAmount);
                uint256 liquidationThreshold = assetConfig[asset].liquidationThreshold;

                // Accumulate total collateral value and weighted sum
                totalCollateralUSD += collateralUSD;
                weightedSum += collateralUSD * liquidationThreshold;
            }
        }

        // If user has no collateral, return 0 to prevent division by zero.
        // This also means their position is extremely unhealthy, which is consistent with having a 0% threshold.
        // In practice, they would be immediately liquidatable.
        if (totalCollateralUSD == 0) return 0;

        // Return weighted average threshold
        return weightedSum / totalCollateralUSD;
    }

    // ========================================
    // LIQUIDATIONS
    // ========================================

    /**
     * @notice Liquidate an undercollateralized position
     * @dev Liquidations can happen even when paused to protect protocol solvency
     * @param user Address of the user to liquidate
     * @param debtAsset Asset to repay
     * @param collateralAsset Asset to seize
     * @param repayAmount Amount of debt to repay
     */
    function liquidate(address user, address debtAsset, address collateralAsset, uint256 repayAmount)
        external
        nonReentrant
    {
        if (user == msg.sender) revert Argent__CannotLiquidateSelf();
        if (repayAmount == 0) revert Argent__InvalidAmount();

        // Accrue interest before liquidation
        accrueInterest(debtAsset);

        // Check if position is liquidatable
        if (!_isLiquidatable(user)) revert Argent__PositionUnhealthy();

        // Get user's actual debt
        uint256 accruedDebt = _getAccruedDebt(user, debtAsset);
        if (accruedDebt == 0) revert Argent__NoDebtInAsset();

        // Cap repayment at max liquidatable amount
        uint256 maxRepay = _getMaxLiquidatableDebt(user, debtAsset);
        uint256 actualRepay = repayAmount > maxRepay ? maxRepay : repayAmount;

        // Calculate collateral to seize (with liquidation bonus)
        uint256 collateralToSeize = _calculateCollateralSeized(debtAsset, collateralAsset, actualRepay);

        uint256 availableCollateral = userCollateral[user][collateralAsset];

        // Instead of reverting when collateral is insufficient,
        // cap the seize at what's available and scale the repay down proportionally.
        // This prevents positions from becoming permanently stuck when the bonus
        // pushes the required seize above the available collateral (bad debt scenario).
        if (collateralToSeize > availableCollateral) {
            collateralToSeize = availableCollateral;

            // Scale repay down proportionally to match the capped collateral.
            // actualRepay =
            uint256 collateralPrice = _getAssetPrice(collateralAsset);
            uint8 collateralDecimals = assetConfig[collateralAsset].decimals;
            uint256 debtPrice = _getAssetPrice(debtAsset);
            uint8 debtDecimals = assetConfig[debtAsset].decimals;

            actualRepay = (availableCollateral * collateralPrice * BASIS_POINTS * (10 ** debtDecimals))
                / (debtPrice * (BASIS_POINTS + liquidationBonus) * (10 ** collateralDecimals));

            // Safety check: never repay more than the actual outstanding debt
            if (actualRepay > accruedDebt) actualRepay = accruedDebt;
        }

        if (actualRepay == 0) revert Argent__InvalidAmount();

        // actualRepay includes accrued interest → subtracting it directly causes underflow.
        // Cap the totalBorrows reduction at the stored principal, same as repay() does.
        uint256 principalStored = userDebt[user][debtAsset];
        uint256 interestAccrued = accruedDebt > principalStored ? accruedDebt - principalStored : 0;

        // Sync totalBorrows with accrued interest before subtracting
        if (interestAccrued > 0) {
            totalBorrows[debtAsset] += interestAccrued;
        }

        // Decrease total borrows by the actual repay amount
        totalBorrows[debtAsset] -= actualRepay;

        // Decrease user's debt
        _decreaseDebt(user, debtAsset, actualRepay);

        // Transfer debt repayment from liquidator
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), actualRepay);

        // Seize collateral
        _seizeCollateral(user, msg.sender, collateralAsset, collateralToSeize);

        emit Liquidated(msg.sender, user, debtAsset, collateralAsset, actualRepay, collateralToSeize);
    }

    /**
     * @dev Check if a position can be liquidated
     * @param user Address of the user
     * @return true if position is under collateralized and can be liquidated, false if position is healthy
     */
    function _isLiquidatable(address user) internal view returns (bool) {
        return !_isPositionHealthy(user);
    }

    /**
     * @dev Get maximum debt that can be liquidated (typically 50% of total debt)
     * @param user Address of the user
     * @param debtAsset Address of the debt asset
     * @return Maximum liquidatable debt amount in debt asset tokens
     */
    function _getMaxLiquidatableDebt(address user, address debtAsset) internal view returns (uint256) {
        uint256 totalDebtUSD = _getTotalDebtUSD(user);
        uint256 totalCollateralUSD = _getTotalCollateralUSD(user);
        uint256 weightedLT = _getWeightedLiquidationThreshold(user);

        // Bonus multiplier e.g. 11500 for 15% bonus
        uint256 bonusMultiplier = BASIS_POINTS + liquidationBonus;

        // Numerator: how far below the health threshold the position currently is
        // debtUSD * BASIS_POINTS - collateralUSD * LT
        // If this is <= 0 the position is already healthy, nothing to liquidate
        if (totalCollateralUSD * weightedLT >= totalDebtUSD * BASIS_POINTS) return 0;

        uint256 numerator = (totalDebtUSD * BASIS_POINTS) - (totalCollateralUSD * weightedLT);

        // Denominator: the net debt reduction per unit repaid after bonus is applied
        // BASIS_POINTS - (bonusMultiplier * LT / BASIS_POINTS)
        uint256 denominator = BASIS_POINTS - ((bonusMultiplier * weightedLT) / BASIS_POINTS);

        // denominator <= 0 means bonus is so large that liquidation
        // can never restore health — cap at 100% of debt asset in this case
        if (denominator == 0 || bonusMultiplier * weightedLT >= BASIS_POINTS * BASIS_POINTS) {
            return _getAccruedDebt(user, debtAsset);
        }

        // Convert USD amount to debt asset tokens
        uint256 assetPrice = _getAssetPrice(debtAsset);
        uint8 decimals = assetConfig[debtAsset].decimals;
        uint256 closeAmountTokens =
            ((numerator * INITIAL_INDEX) * (10 ** decimals)) / (assetPrice * PRICE_BRIDGE_PRECISION) * denominator;

        // Never exceed actual debt on this asset
        uint256 actualDebt = _getAccruedDebt(user, debtAsset);
        return closeAmountTokens < actualDebt ? closeAmountTokens : actualDebt;
    }

    /**
     * @dev Calculate collateral to seize including liquidation bonus
     * @param debtAsset Address of the debt asset
     * @param collateralAsset Address of the collateral asset
     * @param debtAmount Amount of debt being repaid in debt asset tokens
     * @return Amount of collateral to seize in collateral asset tokens
     */
    function _calculateCollateralSeized(address debtAsset, address collateralAsset, uint256 debtAmount)
        internal
        view
        returns (uint256)
    {
        uint256 debtValueUSD = _getAssetValueUSD(debtAsset, debtAmount);

        uint256 collateralPrice = _getAssetPrice(collateralAsset);
        if (collateralPrice == 0) revert Argent__InvalidAsset(); // explicit oracle guard

        uint8 collateralDecimals = assetConfig[collateralAsset].decimals;

        // Numerator:  18-dec USD value × bonus ratio × token decimal scaler
        // Denominator: 8-dec price × 1e10 bridge × BASIS_POINTS cancel
        // Single division = minimum precision loss
        // Max numerator ~2e49, well within uint256 bounds for realistic amounts
        return (debtValueUSD * (BASIS_POINTS + liquidationBonus) * (10 ** collateralDecimals))
            / (collateralPrice * PRICE_BRIDGE_PRECISION * BASIS_POINTS);
    }

    /**
     * @dev Transfer collateral from user to liquidator
     * @param user Address of the user being liquidated
     * @param liquidator Address of the liquidator
     * @param asset Address of the collateral asset
     * @param amount Amount of collateral to transfer
     */
    function _seizeCollateral(address user, address liquidator, address asset, uint256 amount) internal {
        userCollateral[user][asset] -= amount;
        totalDeposits[asset] -= amount;

        IERC20(asset).safeTransfer(liquidator, amount);
    }

    // ========================================
    // PROTOCOL FEES & TREASURY
    // ========================================

    /**
     * @notice Withdraw accumulated protocol fees (DAO only)
     * @param asset Asset to withdraw fees for
     */
    function withdrawProtocolFees(address asset) external onlyOwner {
        uint256 amount = protocolFeesAccrued[asset];
        if (amount == 0) revert Argent__InvalidAmount();

        protocolFeesAccrued[asset] = 0;
        IERC20(asset).safeTransfer(treasury, amount);

        emit ProtocolFeesWithdrawn(asset, amount);
    }

    /**
     * @notice Set protocol fee percentage (DAO only)
     * @param newFee New fee in basis points
     */
    function setProtocolFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_PROTOCOL_FEE) revert Argent__FeeTooHigh();
        emit ProtocolFeeUpdated(protocolFee, newFee);
        protocolFee = newFee;
    }

    /**
     * @notice Set treasury address (DAO only)
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert Argent__InvalidAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /**
     * @notice Set liquidation bonus (DAO only)
     * @param newBonus New bonus in basis points
     */
    function setLiquidationBonus(uint256 newBonus) external onlyOwner {
        if (newBonus > BASIS_POINTS) revert Argent__BonusTooHigh();
        emit LiquidationBonusUpdated(liquidationBonus, newBonus);
        liquidationBonus = newBonus;
    }

    /**
     * @notice Update the PriceOracle contract address (DAO only)
     * @param newOracle Address of the new PriceOracle contract
     */
    function setPriceOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert Argent__InvalidAddress();
        address oldOracle = address(priceOracle);
        priceOracle = IPriceOracle(newOracle);
        emit PriceOracleUpdated(oldOracle, newOracle);
    }

    // ========================================
    // VALIDATION HELPERS
    // ========================================

    /**
     * @dev Check if protocol has sufficient liquidity for a borrow
     * @param asset Address of the asset to borrow
     * @param amount Amount to borrow
     */
    function _hasSufficientLiquidity(address asset, uint256 amount) internal view returns (bool) {
        uint256 available = getAvailableLiquidity(asset);
        return available >= amount;
    }

    /**
     * @dev Check if user can borrow the requested amount
     * @notice Must pass BOTH checks: solvency AND liquidity
     * @param user Address of the user
     * @param asset Address of the asset to borrow
     * @param amount Amount to borrow
     * @return true if borrow is allowed, false if borrow would under collateralize the position or if protocol lacks liquidity
     */
    function _canBorrow(address user, address asset, uint256 amount) internal view returns (bool) {
        // Get borrow limit in USD
        uint256 borrowLimit = _getBorrowLimitUSD(user);

        // Get current total debt in USD
        uint256 currentDebtUSD = _getTotalDebtUSD(user);

        // Calculate new debt amount in USD
        uint256 borrowAmountUSD = _getAssetValueUSD(asset, amount);
        uint256 newTotalDebtUSD = currentDebtUSD + borrowAmountUSD;

        // Check if new debt exceeds borrow limit
        return newTotalDebtUSD <= borrowLimit;
    }

    /**
     * @dev Calculate user's borrow limit based on LTV
     * @notice Formula: Σ(collateralUSD × assetLTV)
     * @param user Address of the user
     * @return Borrow limit in USD
     */
    function _getBorrowLimitUSD(address user) internal view returns (uint256) {
        uint256 borrowLimit = 0;
        address[] storage assets = userActiveAssets[user];
        // Loop through user's active assets
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 collateralAmount = userCollateral[user][asset];

            if (collateralAmount > 0) {
                uint256 collateralUSD = _getAssetValueUSD(asset, collateralAmount);
                uint256 ltv = assetConfig[asset].ltv;

                // Add weighted collateral value
                borrowLimit += (collateralUSD * ltv) / BASIS_POINTS;
            }
        }

        return borrowLimit;
    }

    // ========================================
    // PRICE ORACLE INTEGRATION
    // ========================================

    /**
     * @notice Get the latest price for an asset from custom PriceOracle
     * @param asset Address of the asset
     * @return Price in USD with 8 decimals
     */
    function _getAssetPrice(address asset) internal view returns (uint256) {
        // Calls custom PriceOracle contract
        // It already handles staleness checks and validation
        return priceOracle.getPrice(asset);
    }

    /**
     * @notice Get the USD value of an asset amount
     * @param asset Address of the asset
     * @param amount Amount of the asset in its native decimals
     * @return USD value
     */
    function _getAssetValueUSD(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;

        uint256 price = _getAssetPrice(asset);
        uint8 decimals = assetConfig[asset].decimals;

        // Multiply before dividing — avoids early truncation
        // Result: 18 decimal USD value
        return (amount * price * PRICE_BRIDGE_PRECISION) / (10 ** decimals);
    }

    // ========================================
    // USER ASSET FUNCTIONS
    // ========================================

    /**
     * @dev Add an asset to user's active assets list if not already present
     * @param user Address of the user
     * @param asset Address of the asset to add
     */
    function _addUserAsset(address user, address asset) internal {
        if (!userHasAsset[user][asset]) {
            userHasAsset[user][asset] = true;
            userActiveAssets[user].push(asset);
        }
    }

    /**
     * @dev Remove an asset from user's active assets list if collateral and debt are zero
     * @param user Address of the user
     * @param asset Address of the asset to remove
     */
    function _removeUserAsset(address user, address asset) internal {
        // Only remove when both collateral AND debt reach zero
        if (userCollateral[user][asset] == 0 && userDebt[user][asset] == 0) {
            userHasAsset[user][asset] = false;

            address[] storage assets = userActiveAssets[user];
            for (uint256 i = 0; i < assets.length; i++) {
                if (assets[i] == asset) {
                    assets[i] = assets[assets.length - 1];
                    assets.pop();
                    break;
                }
            }
        }
    }

    // ========================================
    // VIEW FUNCTIONS (MANDATORY FOR UIs & BOTS)
    // ========================================

    /**
     * @notice Get user's collateral balance for an asset
     * @param user Address of the user
     * @param asset Address of the collateral asset
     * @return Collateral amount in asset's native decimals
     */
    function getUserCollateral(address user, address asset) external view returns (uint256) {
        return userCollateral[user][asset];
    }

    /**
     * @notice Get user's debt for an asset (with accrued interest)
     * @param user Address of the user
     * @param asset Address of the borrowed asset
     * @return Debt amount in asset's native decimals, including accrued interest
     */
    function getUserDebt(address user, address asset) external view returns (uint256) {
        return _getAccruedDebt(user, asset);
    }

    /**
     * @notice Get user's debt index for an asset (used to calculate accrued interest)
     * @param user Address of the user
     * @param asset Address of the borrowed asset
     * @return User's debt index (scaled by 1e18)
     */
    function getUserDebtIndex(address user, address asset) external view returns (uint256) {
        return userDebtIndex[user][asset];
    }

    /**
     * @notice Get user's liquidity deposit for an asset
     * @param user Address of the user
     * @param asset Address of the asset
     * @return Liquidity deposit amount in asset's native decimals
     */
    function getUserLiquidityDeposit(address user, address asset) external view returns (uint256) {
        return userLiquidityDeposits[user][asset];
    }

    /**
     * @notice Get borrow index for an asset
     * @param asset Address of the asset
     * @return Borrow index (scaled by 1e18)
     */
    function getBorrowIndex(address asset) external view returns (uint256) {
        return _getCurrentIndex(asset);
    }

    /**
     * @notice Get user's health factor
     * @param user Address of the user
     * @return Health factor scaled by 1e18 (1e18 = 1.0)
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _calculateHealthFactor(user);
    }

    /**
     * @notice Check if a user is eligible for liquidation
     * @param user The address of the borrower
     * @return true if the health factor is below 1.0
     */
    function getLiquidatable(address user) external view returns (bool) {
        return _isLiquidatable(user);
    }

    /**
     * @notice Get user's borrow limit in USD
     * @param user Address of the user
     * @return Borrow limit in USD with 8 decimals
     */
    function getBorrowLimit(address user) external view returns (uint256) {
        return _getBorrowLimitUSD(user);
    }

    /**
     * @notice Get user's available borrowing power
     * @param user Address of the user
     * @return Available borrowing power in USD with 8 decimals
     */
    function getUserAvailableBorrow(address user) external view returns (uint256) {
        uint256 borrowLimit = _getBorrowLimitUSD(user);
        uint256 currentDebt = _getTotalDebtUSD(user);

        return borrowLimit > currentDebt ? borrowLimit - currentDebt : 0;
    }

    /**
     * @notice Get liquidation threshold for an asset
     * @param asset Address of the asset
     * @return Liquidation threshold in basis points (e.g., 8000 for 80%)
     */
    function getLiquidationThreshold(address asset) external view returns (uint256) {
        return assetConfig[asset].liquidationThreshold;
    }

    /**
     * @notice Get interest rate for an asset
     * @param asset Address of the asset
     * @return Interest rate in basis points (e.g., 500 for 5%)
     */
    function getInterestRate(address asset) external view returns (uint256) {
        return assetConfig[asset].interestRate;
    }

    /**
     * @notice Get available liquidity in the protocol for an asset
     * @param asset Address of the asset
     * @return Available liquidity in asset's native decimals
     */
    function getAvailableLiquidity(address asset) public view returns (uint256) {
        uint256 deposits = totalDeposits[asset] + totalLiquidity[asset];
        uint256 borrows = totalBorrows[asset];
        uint256 fees = protocolFeesAccrued[asset];

        // Available = deposits - borrows - reserved fees
        return deposits > (borrows + fees) ? deposits - borrows - fees : 0;
    }

    /**
     * @notice Get asset price from oracle (external view function for UIs)
     * @param asset Address of the asset
     * @return Price in USD with 8 decimals
     */
    function getAssetPrice(address asset) external view returns (uint256) {
        return _getAssetPrice(asset);
    }

    /**
     * @notice Get USD value of an amount (external view function for UIs)
     * @param asset Address of the asset
     * @param amount Amount in asset's native decimals
     * @return USD value with 8 decimals
     */
    function getAssetValueUSD(address asset, uint256 amount) external view returns (uint256) {
        return _getAssetValueUSD(asset, amount);
    }

    /**
     * @notice Get total collateral value in USD for a user (external view)
     * @param user Address of the user
     * @return Total collateral in USD with 8 decimals
     */
    function getTotalCollateralUSD(address user) external view returns (uint256) {
        return _getTotalCollateralUSD(user);
    }

    /**
     * @notice Get total debt value in USD for a user (external view)
     * @param user Address of the user
     * @return Total debt in USD with 8 decimals
     */
    function getTotalDebtUSD(address user) external view returns (uint256) {
        return _getTotalDebtUSD(user);
    }

    /**
     * @notice Get all supported assets
     * @return Array of supported asset addresses
     */
    function getSupportedAssets() external view returns (address[] memory) {
        return supportedAssets;
    }

    // ========================================
    // ADMIN FUNCTIONS
    // ========================================

    /**
     * @notice Add or update an asset configuration (DAO only)
     * @param asset Address of the asset token
     * @param ltv Loan-to-value ratio in basis points
     * @param liquidationThreshold Liquidation threshold in basis points
     * @param interestRate Annual interest rate in basis points
     * @param decimals Number of decimals for the token
     */
    function addAsset(address asset, uint256 ltv, uint256 liquidationThreshold, uint256 interestRate, uint8 decimals)
        external
        onlyOwner
    {
        if (asset == address(0)) revert Argent__InvalidAddress();
        if (ltv > BASIS_POINTS) revert Argent__FeeTooHigh();
        if (liquidationThreshold > BASIS_POINTS) revert Argent__FeeTooHigh();
        if (ltv > liquidationThreshold) revert Argent__InvalidParameter();

        // Check if this is a brand new asset to the protocol
        bool isNew = assetConfig[asset].status == AssetStatus.INACTIVE && borrowIndex[asset] == 0;

        // Update asset configuration
        assetConfig[asset] = AssetConfig({
            status: AssetStatus.ACTIVE,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            interestRate: interestRate,
            decimals: decimals
        });

        // Initialize interest index and timestamp if this is a new asset
        if (isNew) {
            borrowIndex[asset] = INITIAL_INDEX;
            lastAccrualTimestamp[asset] = block.timestamp;
            supportedAssets.push(asset);
        }

        emit AssetAdded(asset, ltv, liquidationThreshold, interestRate);
    }

    /**
     * @notice Update asset status (DAO only)
     * @param asset Address of the asset
     * @param status New status for the asset
     */
    function setAssetStatus(address asset, AssetStatus status) external onlyOwner {
        if (borrowIndex[asset] == 0) revert Argent__InvalidAsset();

        // 1. Capture old status for the event
        AssetStatus oldStatus = assetConfig[asset].status;

        // 2. State change
        assetConfig[asset].status = status;

        // 3. Emit event
        emit AssetStatusUpdated(asset, oldStatus, status);
    }
}
