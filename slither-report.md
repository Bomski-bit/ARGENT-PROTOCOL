Summary
 - [divide-before-multiply](#divide-before-multiply) (1 results) (Medium)
 - [incorrect-equality](#incorrect-equality) (7 results) (Medium)
 - [uninitialized-local](#uninitialized-local) (2 results) (Medium)
 - [unused-return](#unused-return) (1 results) (Medium)
 - [events-maths](#events-maths) (1 results) (Low)
 - [calls-loop](#calls-loop) (9 results) (Low)
 - [reentrancy-events](#reentrancy-events) (1 results) (Low)
 - [timestamp](#timestamp) (15 results) (Low)
 - [low-level-calls](#low-level-calls) (1 results) (Informational)
 - [missing-inheritance](#missing-inheritance) (1 results) (Informational)

## divide-before-multiply
## fixed
Impact: Medium
Confidence: Medium
 - [ ] ID-0
[ArgentProtocol._getMaxLiquidatableDebt(address,address)](src/ArgentProtocol.sol#L716-L752) performs a multiplication on the result of a division:
	- [closeAmountUSD = (numerator * 1e18) / denominator](src/ArgentProtocol.sol#L742)
	- [closeAmountTokens = (closeAmountUSD * (10 ** decimals)) / (assetPrice * 1e10)](src/ArgentProtocol.sol#L747)

src/ArgentProtocol.sol#L716-L752 -->


<!-- ## incorrect-equality
## Known Contract Feature
Impact: Medium
Confidence: High
 - [ ] ID-1
[ArgentProtocol.repay(address,uint256)](src/ArgentProtocol.sol#L347-L384) uses a dangerous strict equality:
	- [currentDebt == 0](src/ArgentProtocol.sol#L355)

src/ArgentProtocol.sol#L347-L384


 - [ ] ID-2
[ArgentProtocol._getAssetValueUSD(address,uint256)](src/ArgentProtocol.sol#L920-L929) uses a dangerous strict equality:
	- [amount == 0](src/ArgentProtocol.sol#L921)

src/ArgentProtocol.sol#L920-L929


 - [ ] ID-3
[ArgentProtocol.accrueInterest(address)](src/ArgentProtocol.sol#L442-L459) uses a dangerous strict equality:
	- [lastAccrual == 0](src/ArgentProtocol.sol#L447)

src/ArgentProtocol.sol#L442-L459


 - [ ] ID-4
[ArgentProtocol._getCurrentIndex(address)](src/ArgentProtocol.sol#L497-L508) uses a dangerous strict equality:
	- [lastAccrual == 0](src/ArgentProtocol.sol#L499)

src/ArgentProtocol.sol#L497-L508


 - [ ] ID-5
[ArgentProtocol.liquidate(address,address,address,uint256)](src/ArgentProtocol.sol#L633-L704) uses a dangerous strict equality:
	- [accruedDebt == 0](src/ArgentProtocol.sol#L648)

src/ArgentProtocol.sol#L633-L704


 - [ ] ID-6
[ArgentProtocol.accrueInterest(address)](src/ArgentProtocol.sol#L442-L459) uses a dangerous strict equality:
	- [currentTime == lastAccrual](src/ArgentProtocol.sol#L454)

src/ArgentProtocol.sol#L442-L459


 - [ ] ID-7
[ArgentProtocol._getCurrentIndex(address)](src/ArgentProtocol.sol#L497-L508) uses a dangerous strict equality:
	- [timeDelta == 0](src/ArgentProtocol.sol#L502)

src/ArgentProtocol.sol#L497-L508 -->


<!-- ## uninitialized-local
## False Positive
Impact: Medium
Confidence: Medium
 - [ ] ID-8
[PriceOracle.getPrice(address).updatedAt](src/PriceOracle.sol#L49) is a local variable never initialized

src/PriceOracle.sol#L49


 - [ ] ID-9
[PriceOracle.getPrice(address).answer](src/PriceOracle.sol#L48) is a local variable never initialized

src/PriceOracle.sol#L48 -->


<!-- ## unused-return
## False Positive
Impact: Medium
Confidence: Medium
 - [ ] ID-10
[PriceOracle.getPrice(address)](src/PriceOracle.sol#L42-L70) ignores return value by [(_answer,_updatedAt) = feed.latestRoundData()](src/PriceOracle.sol#L52-L57)

src/PriceOracle.sol#L42-L70 -->


<!-- ## events-maths
## Fixed!
Impact: Low
Confidence: Medium
 - [ ] ID-11
[ArgentProtocol.setLiquidationBonus(uint256)](src/ArgentProtocol.sol#L828-L831) should emit an event for: 
	- [liquidationBonus = newBonus](src/ArgentProtocol.sol#L830) 

src/ArgentProtocol.sol#L828-L831 -->


<!-- ## calls-loop
## Known Contract Feature and Gas Implications
Impact: Low
Confidence: Medium
 - [ ] ID-12
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.withdrawCollateral(address,uint256)
		ArgentProtocol._isWithdrawalHealthy(address)
		ArgentProtocol._getTotalDebtUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912


 - [ ] ID-13
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.liquidate(address,address,address,uint256)
		ArgentProtocol._isLiquidatable(address)
		ArgentProtocol._isPositionHealthy(address)
		ArgentProtocol._calculateHealthFactor(address)
		ArgentProtocol._getTotalDebtUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912


 - [ ] ID-14
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.getBorrowLimit(address)
		ArgentProtocol._getBorrowLimitUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912


 - [ ] ID-15
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.borrow(address,uint256)
		ArgentProtocol._canBorrow(address,address,uint256)
		ArgentProtocol._getBorrowLimitUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912


 - [ ] ID-16
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.getTotalCollateralUSD(address)
		ArgentProtocol._getTotalCollateralUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912


 - [ ] ID-17
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.getHealthFactor(address)
		ArgentProtocol._calculateHealthFactor(address)
		ArgentProtocol._getTotalDebtUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912


 - [ ] ID-18
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.getUserAvailableBorrow(address)
		ArgentProtocol._getBorrowLimitUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912


 - [ ] ID-19
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.getLiquidatable(address)
		ArgentProtocol._isLiquidatable(address)
		ArgentProtocol._isPositionHealthy(address)
		ArgentProtocol._calculateHealthFactor(address)
		ArgentProtocol._getTotalDebtUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912


 - [ ] ID-20
[ArgentProtocol._getAssetPrice(address)](src/ArgentProtocol.sol#L908-L912) has external calls inside a loop: [priceOracle.getPrice(asset)](src/ArgentProtocol.sol#L911)
	Calls stack containing the loop:
		ArgentProtocol.getTotalDebtUSD(address)
		ArgentProtocol._getTotalDebtUSD(address)
		ArgentProtocol._getAssetValueUSD(address,uint256)

src/ArgentProtocol.sol#L908-L912 -->


<!-- ## reentrancy-events
## Fixed!
Impact: Low
Confidence: Medium
 - [ ] ID-21
Reentrancy in [Treasury.transferETH(address,uint256)](src/Treasury.sol#L56-L64):
	External calls:
	- [(success,None) = to.call{value: amount}()](src/Treasury.sol#L60)
	Event emitted after the call(s):
	- [ETHTransferred(to,amount)](src/Treasury.sol#L63)

src/Treasury.sol#L56-L64 -->


<!-- ## timestamp
## Known Contract Feature and Validator Implications
Impact: Low
Confidence: Medium
 - [ ] ID-22
[ArgentProtocol._getMaxLiquidatableDebt(address,address)](src/ArgentProtocol.sol#L716-L752) uses timestamp for comparisons
	Dangerous comparisons:
	- [closeAmountTokens < actualDebt](src/ArgentProtocol.sol#L751)

src/ArgentProtocol.sol#L716-L752


 - [ ] ID-23
[ArgentProtocol._getAssetValueUSD(address,uint256)](src/ArgentProtocol.sol#L920-L929) uses timestamp for comparisons
	Dangerous comparisons:
	- [amount == 0](src/ArgentProtocol.sol#L921)

src/ArgentProtocol.sol#L920-L929


 - [ ] ID-24
[ArgentProtocol.liquidate(address,address,address,uint256)](src/ArgentProtocol.sol#L633-L704) uses timestamp for comparisons
	Dangerous comparisons:
	- [accruedDebt == 0](src/ArgentProtocol.sol#L648)
	- [collateralToSeize > availableCollateral](src/ArgentProtocol.sol#L663)
	- [actualRepay > accruedDebt](src/ArgentProtocol.sol#L677)
	- [actualRepay == 0](src/ArgentProtocol.sol#L680)
	- [interestAccrued > 0](src/ArgentProtocol.sol#L688)
	- [repayAmount > maxRepay](src/ArgentProtocol.sol#L652)
	- [accruedDebt > principalStored](src/ArgentProtocol.sol#L685)

src/ArgentProtocol.sol#L633-L704


 - [ ] ID-25
[ArgentProtocol._decreaseDebt(address,address,uint256)](src/ArgentProtocol.sol#L419-L432) uses timestamp for comparisons
	Dangerous comparisons:
	- [amount >= currentDebt](src/ArgentProtocol.sol#L422)

src/ArgentProtocol.sol#L419-L432


 - [ ] ID-26
[ArgentProtocol._getTotalDebtUSD(address)](src/ArgentProtocol.sol#L574-L590) uses timestamp for comparisons
	Dangerous comparisons:
	- [debtAmount > 0](src/ArgentProtocol.sol#L583)

src/ArgentProtocol.sol#L574-L590


 - [ ] ID-27
[ArgentProtocol.repay(address,uint256)](src/ArgentProtocol.sol#L347-L384) uses timestamp for comparisons
	Dangerous comparisons:
	- [currentDebt == 0](src/ArgentProtocol.sol#L355)
	- [feeAmount > 0](src/ArgentProtocol.sol#L370)
	- [interestAccrued > 0](src/ArgentProtocol.sol#L374)
	- [amount > currentDebt](src/ArgentProtocol.sol#L358)
	- [repayAmount > principalStored](src/ArgentProtocol.sol#L366)
	- [currentDebt > principalStored](src/ArgentProtocol.sol#L372)

src/ArgentProtocol.sol#L347-L384


 - [ ] ID-28
[PriceOracle.getPrice(address)](src/PriceOracle.sol#L42-L70) uses timestamp for comparisons
	Dangerous comparisons:
	- [updatedAt > block.timestamp](src/PriceOracle.sol#L62)
	- [block.timestamp - updatedAt > heartbeats[asset]](src/PriceOracle.sol#L65)

src/PriceOracle.sol#L42-L70


 - [ ] ID-29
[ArgentProtocol._getWeightedLiquidationThreshold(address)](src/ArgentProtocol.sol#L596-L619) uses timestamp for comparisons
	Dangerous comparisons:
	- [totalCollateralUSD == 0](src/ArgentProtocol.sol#L615)

src/ArgentProtocol.sol#L596-L619


 - [ ] ID-30
[ArgentProtocol.getAvailableLiquidity(address)](src/ArgentProtocol.sol#L1039-L1046) uses timestamp for comparisons
	Dangerous comparisons:
	- [deposits > (borrows + fees)](src/ArgentProtocol.sol#L1045)

src/ArgentProtocol.sol#L1039-L1046


 - [ ] ID-31
[ArgentProtocol._increaseDebt(address,address,uint256)](src/ArgentProtocol.sol#L389-L414) uses timestamp for comparisons
	Dangerous comparisons:
	- [principalDebt == 0](src/ArgentProtocol.sol#L393)
	- [interestRolledIn > 0](src/ArgentProtocol.sol#L401)

src/ArgentProtocol.sol#L389-L414


 - [ ] ID-32
[ArgentProtocol._getCurrentIndex(address)](src/ArgentProtocol.sol#L497-L508) uses timestamp for comparisons
	Dangerous comparisons:
	- [lastAccrual == 0](src/ArgentProtocol.sol#L499)
	- [timeDelta == 0](src/ArgentProtocol.sol#L502)

src/ArgentProtocol.sol#L497-L508


 - [ ] ID-33
[ArgentProtocol.withdrawLiquidity(address,uint256)](src/ArgentProtocol.sol#L278-L294) uses timestamp for comparisons
	Dangerous comparisons:
	- [getAvailableLiquidity(asset) < amount](src/ArgentProtocol.sol#L280)

src/ArgentProtocol.sol#L278-L294


 - [ ] ID-34
[ArgentProtocol._hasSufficientLiquidity(address,uint256)](src/ArgentProtocol.sol#L851-L854) uses timestamp for comparisons
	Dangerous comparisons:
	- [available >= amount](src/ArgentProtocol.sol#L853)

src/ArgentProtocol.sol#L851-L854


 - [ ] ID-35
[ArgentProtocol._canBorrow(address,address,uint256)](src/ArgentProtocol.sol#L860-L873) uses timestamp for comparisons
	Dangerous comparisons:
	- [newTotalDebtUSD <= borrowLimit](src/ArgentProtocol.sol#L872)

src/ArgentProtocol.sol#L860-L873


 - [ ] ID-36
[ArgentProtocol.accrueInterest(address)](src/ArgentProtocol.sol#L442-L459) uses timestamp for comparisons
	Dangerous comparisons:
	- [lastAccrual == 0](src/ArgentProtocol.sol#L447)
	- [currentTime == lastAccrual](src/ArgentProtocol.sol#L454)

src/ArgentProtocol.sol#L442-L459 -->


<!-- ## low-level-calls
## Known Contract Feature
Impact: Informational
Confidence: High
 - [ ] ID-37
Low level call in [Treasury.transferETH(address,uint256)](src/Treasury.sol#L56-L64):
	- [(success,None) = to.call{value: amount}()](src/Treasury.sol#L60)

src/Treasury.sol#L56-L64 -->


<!-- ## missing-inheritance
## Fixed!
Impact: Informational
Confidence: High
 - [ ] ID-38
[PriceOracle](src/PriceOracle.sol#L7-L71) should inherit from [IPriceOracle](src/ArgentProtocol.sol#L14-L17)

src/PriceOracle.sol#L7-L71


