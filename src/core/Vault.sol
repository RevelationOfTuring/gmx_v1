// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "src/libraries/token/SafeERC20.sol";
import "src/libraries/utils/ReentrancyGuard.sol";
import "src/tokens/interfaces/IUSDG.sol";
import "src/core/interfaces/IVault.sol";
import "src/core/interfaces/IVaultPriceFeed.sol";

// https://arbiscan.io/address/0x489ee077994B6658eAfA855C308275EAd8097C4A
contract Vault is ReentrancyGuard, IVault {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // 仓位信息
    struct Position {
        // 仓位大小（以USD计价，带价格精度30）
        uint256 size;
        // 每次加仓时，投入到本仓位中的抵押token的价值的累计和（以USD计价，带价格精度30）
        uint256 collateral;
        // 当前的仓位均价
        uint256 averagePrice;
        // 最近一次改变仓位大小时的累计资金费率
        uint256 entryFundingRate;
        // 每次加仓时，本仓位的仓位增量对应的抵押token的数量累计和
        // 注：reserveAmount的作用是用于兑付未来本仓位的盈利
        uint256 reserveAmount;
        int256 realisedPnl;
        // 最近一次加仓的时间戳
        uint256 lastIncreasedTime;
    }

    // 基点分母，即合约中1基点表示原数值的万分之1
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    // 资金费率的精度
    // 注：如果某仓位的资金费率为100，那么意味着的资金费是：100 * 仓位大小 / FUNDING_RATE_PRECISION
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    // 从VaultPriceFeed合约获得的价格所携带的价格精度
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    // USDG精度
    uint256 public constant USDG_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public override isInitialized;
    // 是否可以进行swap的开关
    bool public override isSwapEnabled = true;
    // 是否可以开杠杆的开关
    // 注：该开关直接控制{increasePosition}函数
    bool public override isLeverageEnabled = true;

    // 具有修改mapping {errors}内容权限的地址，即VaultErrorController合约地址
    address public errorController;

    // Router合约地址
    address public override router;
    // VaultPriceFeed合约地址
    address public override priceFeed;
    // USDG合约地址
    address public override usdg;
    // gov地址
    address public override gov;

    // token白名单中的token个数，即可以做流动性的token个数
    uint256 public override whitelistedTokenCount;

    // 杠杆数上限
    // 主网该值目前是100*10000，即100x
    uint256 public override maxLeverage = 50 * 10000; // 50x

    //
    uint256 public override liquidationFeeUsd;
    // 非稳定币之间swap时的税费基点，即在动态手续费计算中，用于计算手续费减免和新增的基础基点
    // 主网该值目前是60
    uint256 public override taxBasisPoints = 50; // 0.5%

    // 稳定币之间swap时的税费基点，即在动态手续费计算中，用于计算手续费减免和新增的基础基点
    // 主网该值目前是5
    uint256 public override stableTaxBasisPoints = 20; // 0.2%

    // buyUSDG和sellUSDG时，使用的手续费基点
    // 主网该值目前是25
    uint256 public override mintBurnFeeBasisPoints = 30; // 0.3%

    // 非稳定币之间swap时，使用的手续费基点
    // 主网该值目前是25
    uint256 public override swapFeeBasisPoints = 30; // 0.3%

    // 稳定币之间swap时，使用的手续费基点
    // 主网该值目前是1
    uint256 public override stableSwapFeeBasisPoints = 4; // 0.04%
    // 保证金手续费基点
    // 主网该值目前是40
    uint256 public override marginFeeBasisPoints = 10; // 0.1%

    // 触发最小盈利阈值机制的间隔时长
    // 注：用于防止front-running（提前交易）的问题。抢跑机器人一般会通过监听pending pool做高频的抢跑操作，从而盈利。
    // 所以抢跑机器人往往会对于相同的标的token进行高频的加减仓操作。引入minProfitTime的限制后，针对`盈利仓位`的以下操作，在计算收益时会加入最小盈利阈值限制：
    // 1. 加仓后短时间内减仓；
    // 2. 加仓后短时间内连续加仓；
    // 如果`本次盈利价值占总仓位大小的比例`不大于minProfitBasisPoints[_indexToken]，系统会认为其仓位未盈利。至此，那些高频的微盈利操作均得到了限制
    // 主网该值目前是10800，即3 hours
    uint256 public override minProfitTime;
    // 计算手续费时使用动态手续费的开关
    // 主网该值目前是true
    bool public override hasDynamicFees = false;

    // 资金费率的更新时间间隔
    // 主网该值目前是3600，即1 hour
    uint256 public override fundingInterval = 8 hours;
    // 非稳定币的资金费率因数
    // 主网该值目前是100
    uint256 public override fundingRateFactor;
    // 稳定币的资金费率因数
    // 主网该值目前是100
    uint256 public override stableFundingRateFactor;
    // 当前全部白名单token的总权重
    uint256 public override totalTokenWeights;

    bool public includeAmmPrice = true;
    // 从VaultPriceFeed合约获得的价格时携带的一个参数标志位，但是在VaultPrinceFeed合约的{getPrice}方法的具体实现中并未真正使用到该参数
    bool public useSwapPricing = false;

    // Vault合约进入manager模式的开关
    // 注：在manager模式下，{buyUSDG}和{sellUSDG}只有manager才可以调用。目前线上Vault合约是处于manager模式。
    bool public override inManagerMode = false;
    bool public override inPrivateLiquidationMode = false;

    // 合约接受交易的gqs price上限，用于防MEV
    uint256 public override maxGasPrice;

    // key1的已授权的router名单。key2为key1的授权router地址，value2为key2当前是否已得到key1的授权
    // 注：如果key2得到了key1的授权，那么key2就可以操作key1的仓位（加仓+减仓）。且router合约默认是所有人// todo
    mapping(address => mapping(address => bool)) public override approvedRouters;
    mapping(address => bool) public override isLiquidator;
    // manager名单
    // 注：目前在manager中，有GlpManager
    mapping(address => bool) public override isManager;

    // 所有添加过的白名单token列表（如果某token添加后又被移除了，那么该token也会存在于该列表中）
    address[] public override allWhitelistedTokens;

    // token地址 -> 该token是否在当前的白名单内
    mapping(address => bool) public override whitelistedTokens;
    // token地址 -> 该token的decimals
    mapping(address => uint256) public override tokenDecimals;
    // token地址 -> 该token最小的盈利基点
    // 即当该token作为标的token时，计算仓位盈亏情况时
    // 目前主网该mapping的所有值都是0，即不开启最小盈利阈值限制
    mapping(address => uint256) public override minProfitBasisPoints;
    // token地址 -> 该token是否是稳定币
    mapping(address => bool) public override stableTokens;
    // token地址 -> 该token是否可以做空
    // 即该token是否可以作为加空仓的标的token
    mapping(address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    // token地址 -> （经过{_transferIn}统计）本合约当下的该token的余额
    // 注：每当有token的转入操作就会调用{_transferIn}来更新本mapping
    mapping(address => uint256) public override tokenBalances;

    // tokenWeights allows customisation of index composition
    // token地址 -> 该token的权重
    mapping(address => uint256) public override tokenWeights;

    // usdgAmounts tracks the amount of USDG debt for each whitelisted token
    // token地址 -> 为该token产生的USDG债务（USDG计价）
    // 注：使用该token在不同时间点购买USDG的债务累计和（USDG计价）
    mapping(address => uint256) public override usdgAmounts;

    // maxUsdgAmounts allows setting a max amount of USDG debt for a token
    mapping(address => uint256) public override maxUsdgAmounts;

    // poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    // token地址 -> 全局可用于开杠杆头寸的该token的数量（可以理解为闲置的该token数量）
    // 注：poolAmounts与tokenBalances不一样，前者中不包含已抵押作为保证金的该token数量
    mapping(address => uint256) public override poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    // token地址 -> 目前池中已用于开杠杆的该token数量（即锁定在未平仓杠杆头寸中的token数量）
    // todo?
    mapping(address => uint256) public override reservedAmounts;

    // bufferAmounts allows specification of an amount to exclude from swaps
    // this can be used to ensure a certain amount of liquidity is available for leverage positions
    // token地址 -> 必须留存在本合约中该token的最小数量
    // 注：这部分的token数量必须留存在Vault合约中，不允许被swap出去的
    mapping(address => uint256) public override bufferAmounts;

    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    // this value is used to calculate the redemption values for selling of USDG
    // this is an estimated amount, it is possible for the actual guaranteed value to be lower
    // in the case of sudden price decreases, the guaranteed value should be corrected
    // after liquidations are carried out
    mapping(address => uint256) public override guaranteedUsd;

    // cumulativeFundingRates tracks the funding rates based on utilization
    // token地址 -> 该token累计的资金费率
    mapping(address => uint256) public override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    // token地址 -> 最近一次更新该token的funding的时间戳
    mapping(address => uint256) public override lastFundingTimes;

    // positions tracks all open positions
    // 仓位列表
    // position key -> 仓位信息
    mapping(bytes32 => Position) public positions;

    // feeReserves tracks the amount of fees per token
    // token地址 -> 使用针对该token产生的手续费总和
    // 产生手续费的地方：
    // 1. 使用该token购买USDG；
    // 2. // todo
    // 3. 清算使用该token作为抵押物的仓位；
    // 4.
    mapping(address => uint256) public override feeReserves;

    // token地址 -> 全局以该token作为标的token的全部空仓的仓位大小之和
    // 注：key应为非稳定币
    mapping(address => uint256) public override globalShortSizes;
    // token地址 -> 全局以该token作为标的token的全部空仓的仓位均价
    // 注：key应为非稳定币
    mapping(address => uint256) public override globalShortAveragePrices;

    mapping(uint256 => string) public errors;

    event BuyUSDG(address account, address token, uint256 tokenAmount, uint256 usdgAmount, uint256 feeBasisPoints);
    event SellUSDG(address account, address token, uint256 usdgAmount, uint256 tokenAmount, uint256 feeBasisPoints);
    event Swap(address account, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 amountOutAfterFees, uint256 feeBasisPoints);

    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(address token, uint256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(address token, uint256 amount);
    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);
    event IncreaseUsdgAmount(address token, uint256 amount);
    event DecreaseUsdgAmount(address token, uint256 amount);
    event IncreaseReservedAmount(address token, uint256 amount);
    event DecreaseReservedAmount(address token, uint256 amount);
    event IncreaseGuaranteedUsd(address token, uint256 amount);
    event DecreaseGuaranteedUsd(address token, uint256 amount);

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() public {
        gov = msg.sender;
    }

    function initialize(
        address _router,
        address _usdg,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external {
        _onlyGov();
        _validate(!isInitialized, 1);
        isInitialized = true;

        router = _router;
        usdg = _usdg;
        priceFeed = _priceFeed;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    function setErrorController(address _errorController) external {
        _onlyGov();
        errorController = _errorController;
    }

    function setError(uint256 _errorCode, string calldata _error) external override {
        require(msg.sender == errorController, "Vault: invalid errorController");
        errors[_errorCode] = _error;
    }

    // 返回全部添加过的白名单token列表长度
    function allWhitelistedTokensLength() external override view returns (uint256) {
        return allWhitelistedTokens.length;
    }

    // gov管理manager模式的开关
    function setInManagerMode(bool _inManagerMode) external override {
        // 校验msg.sender是gov
        _onlyGov();
        inManagerMode = _inManagerMode;
    }

    // gov管理manger状态
    function setManager(address _manager, bool _isManager) external override {
        // 校验msg.sender是gov
        _onlyGov();
        // 设置管理员状态
        isManager[_manager] = _isManager;
    }

    function setInPrivateLiquidationMode(bool _inPrivateLiquidationMode) external override {
        _onlyGov();
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }

    function setLiquidator(address _liquidator, bool _isActive) external override {
        _onlyGov();
        isLiquidator[_liquidator] = _isActive;
    }

    // gov管理swap的开关
    function setIsSwapEnabled(bool _isSwapEnabled) external override {
        // 校验msg.sender是gov
        _onlyGov();
        // 设置swap开关
        isSwapEnabled = _isSwapEnabled;
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyGov();
        isLeverageEnabled = _isLeverageEnabled;
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyGov();
        maxGasPrice = _maxGasPrice;
    }

    function setGov(address _gov) external {
        _onlyGov();
        gov = _gov;
    }

    function setPriceFeed(address _priceFeed) external override {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, 2);
        maxLeverage = _maxLeverage;
    }

    function setBufferAmount(address _token, uint256 _amount) external override {
        _onlyGov();
        bufferAmounts[_token] = _amount;
    }

    function setFees(
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external override {
        _onlyGov();
        _validate(_taxBasisPoints <= MAX_FEE_BASIS_POINTS, 3);
        _validate(_stableTaxBasisPoints <= MAX_FEE_BASIS_POINTS, 4);
        _validate(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 5);
        _validate(_swapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 6);
        _validate(_stableSwapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 7);
        _validate(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 8);
        _validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, 9);
        taxBasisPoints = _taxBasisPoints;
        stableTaxBasisPoints = _stableTaxBasisPoints;
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        swapFeeBasisPoints = _swapFeeBasisPoints;
        stableSwapFeeBasisPoints = _stableSwapFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    function setFundingRate(uint256 _fundingInterval, uint256 _fundingRateFactor, uint256 _stableFundingRateFactor) external override {
        _onlyGov();
        _validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, 10);
        _validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 11);
        _validate(_stableFundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 12);
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    // gov向token白名单中添加token并做相关参数的设置（可新增新的token，也可更新之前已有的）
    function setTokenConfig(
    // 目标token地址
        address _token,
    // 目标token的精度
        uint256 _tokenDecimals,
    // 目标token权重
        uint256 _tokenWeight,
    // 目标token的最小盈利阈值基点
        uint256 _minProfitBps,
    // 允许为目标token产生的最大USDG债务
        uint256 _maxUsdgAmount,
    // 目标token是否是稳定币
        bool _isStable,
    // 目标token是否允许做空
        bool _isShortable
    ) external override {
        // msg.sender必须是gov
        _onlyGov();
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            // 如果_token不在当前token白名单中，whitelistedTokenCount自增1
            whitelistedTokenCount = whitelistedTokenCount.add(1);
            // 向allWhitelistedTokens中追加_token
            allWhitelistedTokens.push(_token);
        }

        // _totalTokenWeights为全局的token总权重
        uint256 _totalTokenWeights = totalTokenWeights;
        // _totalTokenWeights自减_token对应的权重（如果是新增token，tokenWeights[_token]为0）
        _totalTokenWeights = _totalTokenWeights.sub(tokenWeights[_token]);

        // 将_token加入token白名单
        whitelistedTokens[_token] = true;
        // 记录_token的精度
        tokenDecimals[_token] = _tokenDecimals;
        // 记录_token的权重
        tokenWeights[_token] = _tokenWeight;
        // 记录_token的最小盈利阈值基点
        minProfitBasisPoints[_token] = _minProfitBps;
        // 记录允许为_token产生的USDG债务上限
        maxUsdgAmounts[_token] = _maxUsdgAmount;
        // 记录_token是否是稳定币
        stableTokens[_token] = _isStable;
        // 记录_token是否可以做空
        shortableTokens[_token] = _isShortable;
        // 更新全局的totalTokenWeights，值为_totalTokenWeights + 本次设置的token权重
        totalTokenWeights = _totalTokenWeights.add(_tokenWeight);

        // validate price feed
        // 获取一次_token的大价格，用于验证_token价格的获取是否正常
        getMaxPrice(_token);
    }

    // gov从token白名单中删除_token，并清除所有与其相关的配置
    function clearTokenConfig(address _token) external {
        // msg.sender必须是gov
        _onlyGov();
        // 要求_token为在册token白名单成员
        _validate(whitelistedTokens[_token], 13);
        // 全局的token总权重自减合约中记录的_token的权重
        totalTokenWeights = totalTokenWeights.sub(tokenWeights[_token]);
        // 从白名单中注销_token
        delete whitelistedTokens[_token];
        // 删除合约中记录的_token精度
        delete tokenDecimals[_token];
        // 删除合约中记录的_token权重
        delete tokenWeights[_token];
        // 删除合约中记录的_token最小盈利阈值基点
        delete minProfitBasisPoints[_token];
        // 删除合约中记录的允许为_token产生的USDG债务上限
        delete maxUsdgAmounts[_token];
        // 删除合约中记录的_token是否为稳定币
        delete stableTokens[_token];
        // 删除合约中记录的_token是否可以做空
        delete shortableTokens[_token];
        // token白名单元素个数自减1
        whitelistedTokenCount = whitelistedTokenCount.sub(1);
    }

    // gov从本合约中取出_token累计的手续费，接收人为_receiver
    function withdrawFees(address _token, address _receiver) external override returns (uint256) {
        // msg.sender必须是gov
        _onlyGov();
        // 获取_token目前累计的手续费数量
        uint256 amount = feeReserves[_token];
        // 如果amount为0，直接返回0
        if (amount == 0) {return 0;}
        // _token目前累计的手续费数量清0
        feeReserves[_token] = 0;
        // 从本合约转移数量为_amount的_token转移给_receiver
        _transferOut(_token, amount, _receiver);
        // 返回本次转出的手续费数量
        return amount;
    }

    // 为自己增添授权的Router地址_router
    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    // 为自己移除授权的Router地址_router
    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    function setUsdgAmount(address _token, uint256 _amount) external override {
        _onlyGov();

        uint256 usdgAmount = usdgAmounts[_token];
        if (_amount > usdgAmount) {
            _increaseUsdgAmount(_token, _amount.sub(usdgAmount));
            return;
        }

        _decreaseUsdgAmount(_token, usdgAmount.sub(_amount));
    }

    // the governance controlling this function should have a timelock
    function upgradeVault(address _newVault, address _token, uint256 _amount) external {
        _onlyGov();
        IERC20(_token).safeTransfer(_newVault, _amount);
    }

    // deposit into the pool without minting USDG tokens
    // useful in allowing the pool to become over-collaterised
    // 不增发USDG的情况下，向Vault合约中直接注入_token
    // 注：该方法是用来提升整个vault的质押率的
    function directPoolDeposit(address _token) external override nonReentrant {
        // 要求注入的_token处于白名单中
        _validate(whitelistedTokens[_token], 14);
        // 向本合约转移_token后，同步更新tokenBalances[_token]。本次注入的_token数量为tokenAmount
        uint256 tokenAmount = _transferIn(_token);
        // 要求tokenAmount大于0
        _validate(tokenAmount > 0, 15);
        // 注入的这部分_token直接增加到可用于开杠杆的_token的数量中
        _increasePoolAmount(_token, tokenAmount);
        // 抛出事件
        emit DirectPoolDeposit(_token, tokenAmount);
    }

    // 向Vault合约转入白名单中的_token，并将其换成等价值的USDG。这部分_token可以理解为向Vault添加流动性
    // 注：在manager模式下，只有在册的manager（官方其他合约）才可以调用该函数
    function buyUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        // 检验msg.sender为在册的manager
        _validateManager();
        // 检验_token为在册白名单token
        _validate(whitelistedTokens[_token], 16);

        // tokenAmount为转入Vault合约的_token数量，即购买USDG的_token数量
        uint256 tokenAmount = _transferIn(_token);
        // 要求转入_token数量大于0
        _validate(tokenAmount > 0, 17);

        // 更新_token的累计资金费率和最近一次更新资金费率的时间戳（如果当前距离上一次更新资金费率不到8小时，什么都不做）
        updateCumulativeFundingRate(_token);

        // price为获取的_token的小价格（decimal为30）
        uint256 price = getMinPrice(_token);

        // usdgAmount为转入_token的USD价值（带_token精度）
        // 即：tokenAmount * _token的小价格(带价格decimal) / 价格decimal
        uint256 usdgAmount = tokenAmount.mul(price).div(PRICE_PRECISION);
        // 将usdgAmount移除_token精度，并提升到USDG精度
        // 此时，usdgAmount为购买USDG的全部_token的USDG价值
        usdgAmount = adjustForDecimals(usdgAmount, _token, usdg);
        // 要求usdgAmount大于0
        _validate(usdgAmount > 0, 18);

        // 根据添加流动性_token的USDG价值，计算购买USDG要花费的手续费基点
        // 注：增加债务数量为usdgAmount，使用的基础手续费为mintBurnFeeBasisPoints，动态手续费减免或新增的基础基点为taxBasisPoints
        uint256 feeBasisPoints = getFeeBasisPoints(_token, usdgAmount, mintBurnFeeBasisPoints, taxBasisPoints, true);
        // 收swap的手续费，amountAfterFees为扣除手续费后的_token数量
        uint256 amountAfterFees = _collectSwapFees(_token, tokenAmount, feeBasisPoints);
        // mintAmount为扣除手续费后的_token的USD价值（带_token精度）
        // 即：扣除手续费后的_token数量 * _token的小价格(带价格decimal) / 价格decimal
        uint256 mintAmount = amountAfterFees.mul(price).div(PRICE_PRECISION);
        // 将mintAmount移除_token精度，并提升到USDG精度
        // 此时，mintAmount扣除手续费后全部购买USDG的_token的USDG价值
        mintAmount = adjustForDecimals(mintAmount, _token, usdg);

        // 增加为_token的产生的USDG债务，债务增量为_amount（以USDG计价）
        _increaseUsdgAmount(_token, mintAmount);
        // 增加全局可用于开杠杆的_token的数量，增量为扣除手续费后的_token数量
        // 注：至此，用户购买USDG的_token流向了两个地方：1. poolAmounts[_token] 2.feeReserves[_token]
        _increasePoolAmount(_token, amountAfterFees);
        // 为_receiver增发mintAmount数量的USDG
        IUSDG(usdg).mint(_receiver, mintAmount);

        // 抛出事件
        emit BuyUSDG(_receiver, _token, tokenAmount, mintAmount, feeBasisPoints);
        // 标志位useSwapPricing设置为false（该标志位实际上无作用，可以删除）
        useSwapPricing = false;
        // 返回增发的USDG数量
        return mintAmount;
    }

    // 向Vault合约转入usdg，并将其换成等价值的_token。这部分_token可以理解为从Vault中减少的流动性
    // 注：在manager模式下，只有在册的manager（官方其他合约）才可以调用该函数
    function sellUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        // 检验msg.sender为在册的manager
        _validateManager();
        // 检验_token为在册白名单token
        _validate(whitelistedTokens[_token], 19);
        // 标志位useSwapPricing设置为true（该标志位实际上无作用，可以删除）
        useSwapPricing = true;

        // usdgAmount为转入Vault合约的USDG数量，即卖出的USDG数量
        uint256 usdgAmount = _transferIn(usdg);
        // 要求转入USDG数量不为0
        _validate(usdgAmount > 0, 20);

        // 更新_token的累计资金费率和最近一次更新资金费率的时间戳（如果当前距离上一次更新资金费率不到8小时，什么都不做）
        updateCumulativeFundingRate(_token);

        // redemptionAmount为当前_usdgAmount数量的USDG可以兑换的_token数量
        uint256 redemptionAmount = getRedemptionAmount(_token, usdgAmount);
        // 要求可兑换_token数量大于0
        _validate(redemptionAmount > 0, 21);

        // 减少为_token的产生的USDG债务，债务减量为usdgAmount
        _decreaseUsdgAmount(_token, usdgAmount);
        // 减少全局可用于开杠杆的_token的数量redemptionAmount
        _decreasePoolAmount(_token, redemptionAmount);
        // 销毁本合约名下数量为usdgAmount的USDG
        IUSDG(usdg).burn(address(this), usdgAmount);

        // 由于上一步已经销毁了本合约名下数量为usdgAmount的USDG，所以这里调用{_updateTokenBalance}来同步取齐tokenBalances[usdg]
        _updateTokenBalance(usdg);

        // 根据为_token减少的USDG债务数量，计算卖出USDG要花费的手续费基点
        // 注：减少债务数量为usdgAmount，使用的基础手续费为mintBurnFeeBasisPoints，动态手续费减免或新增的基础基点为taxBasisPoints
        uint256 feeBasisPoints = getFeeBasisPoints(_token, usdgAmount, mintBurnFeeBasisPoints, taxBasisPoints, false);
        // 收swap的手续费，amountOuts为扣除手续费后的_token数量
        uint256 amountOut = _collectSwapFees(_token, redemptionAmount, feeBasisPoints);
        // 要求扣除手续费后的_token数量不大于0
        _validate(amountOut > 0, 22);

        // 从本合约转移数量为amountOut的_token转移给_receiver
        _transferOut(_token, amountOut, _receiver);
        // 抛出事件
        emit SellUSDG(_receiver, _token, usdgAmount, amountOut, feeBasisPoints);
        // 标志位useSwapPricing设置为false（该标志位实际上无作用，可以删除）
        useSwapPricing = false;
        // 返回最终转移给_receiver的_token数量
        return amountOut;
    }

    // 向Vault合约转入_tokenIn，并将其换成等价值的_tokenOut给_receiver
    // 注：swap的手续费收的是_tokenOut
    function swap(address _tokenIn, address _tokenOut, address _receiver) external override nonReentrant returns (uint256) {
        // 要求swap的开关已打开
        _validate(isSwapEnabled, 23);
        // 要求_tokenIn和tokenOut都是在册白名单token
        _validate(whitelistedTokens[_tokenIn], 24);
        _validate(whitelistedTokens[_tokenOut], 25);
        // 要求_tokenIn和_tokenOut不是同一个token地址
        _validate(_tokenIn != _tokenOut, 26);
        // 标志位useSwapPricing设置为true（该标志位实际上无作用，可以删除）
        useSwapPricing = true;

        // 更新_tokenIn的累计资金费率和最近一次更新资金费率的时间戳（如果当前距离上一次更新资金费率不到8小时，什么都不做）
        updateCumulativeFundingRate(_tokenIn);
        // 更新_tokenOut的累计资金费率和最近一次更新资金费率的时间戳（如果当前距离上一次更新资金费率不到8小时，什么都不做）
        updateCumulativeFundingRate(_tokenOut);

        // amountIn为转入Vault合约的_tokenIn数量，即用于兑换_tokenOut的_tokenIn数量
        uint256 amountIn = _transferIn(_tokenIn);
        // 要求转入_token数量大于0
        _validate(amountIn > 0, 27);

        // priceIn为获取的_tokenIn的小价格（decimal为30）
        uint256 priceIn = getMinPrice(_tokenIn);
        // priceOut为获取的_tokenOut的大价格（decimal为30）
        uint256 priceOut = getMaxPrice(_tokenOut);

        // amountOut为：转入_tokenIn数量 * _tokenIn价格 / priceOut
        // 注：此时amountOut带有_tokenIn的精度
        uint256 amountOut = amountIn.mul(priceIn).div(priceOut);
        // 从amountOut中去除_tokenIn精度，加入_tokenOut精度
        amountOut = adjustForDecimals(amountOut, _tokenIn, _tokenOut);

        // adjust usdgAmounts by the same usdgAmount as debt is shifted between the assets
        // usdgAmount为转入_tokenIn的USDG价值，即转入_tokenIn数量 * _tokenIn价格 / _tokenIn价格所带的价格精度
        // 注：此时usdgAmount带有_tokenIn精度
        uint256 usdgAmount = amountIn.mul(priceIn).div(PRICE_PRECISION);
        // 从amountOut中去除_tokenIn精度，加入USDG精度
        usdgAmount = adjustForDecimals(usdgAmount, _tokenIn, usdg);

        // 如果_tokenIn和_tokenOut都是稳定币，isStableSwap为true。否则为false
        bool isStableSwap = stableTokens[_tokenIn] && stableTokens[_tokenOut];
        uint256 feeBasisPoints;
        {
            // 如果是稳定币之间的swap，手续费基点为stableSwapFeeBasisPoints；否则为swapFeeBasisPoints
            uint256 baseBps = isStableSwap ? stableSwapFeeBasisPoints : swapFeeBasisPoints;
            // 如果是稳定币之间的swap，税费基点为stableTaxBasisPoints；否则为taxBasisPoints
            uint256 taxBps = isStableSwap ? stableTaxBasisPoints : taxBasisPoints;
            // 计算为_tokenIn增加usdgAmount数量的债务时的手续费基点feesBasisPoints0
            uint256 feesBasisPoints0 = getFeeBasisPoints(_tokenIn, usdgAmount, baseBps, taxBps, true);
            // 计算为_tokenOut减少usdgAmount数量的债务时的手续费基点feesBasisPoints1
            uint256 feesBasisPoints1 = getFeeBasisPoints(_tokenOut, usdgAmount, baseBps, taxBps, false);
            // use the higher of the two fee basis points
            // feesBasisPoints0和feesBasisPoints1中取大值作为本次swap的手续费基点
            feeBasisPoints = feesBasisPoints0 > feesBasisPoints1 ? feesBasisPoints0 : feesBasisPoints1;
        }

        // 收swap手续费，amountOutAfterFees为扣除手续费后的_token数量
        uint256 amountOutAfterFees = _collectSwapFees(_tokenOut, amountOut, feeBasisPoints);

        // 增加为_tokenIn的产生的USDG债务，债务增量为usdgAmount（以USDG计价）
        _increaseUsdgAmount(_tokenIn, usdgAmount);
        // 减少为_tokenOut的产生的USDG债务，债务减量为usdgAmount
        _decreaseUsdgAmount(_tokenOut, usdgAmount);

        // 增加全局可用于开杠杆的_tokenIn的数量，增量为转入本合约的_tokenIn的数量
        // 注：至此，转入的_tokenIn流向只流向一个地方 poolAmounts[_tokenIn]
        _increasePoolAmount(_tokenIn, amountIn);
        // 减少全局可用于开杠杆的_tokenOut的数量，减量为amountOut
        _decreasePoolAmount(_tokenOut, amountOut);
        // 对_tokenOut进行现有杠杆头寸的可对付检查，保证swap后Vault中有足够的闲置_tokenOut来兑付全部_tokenOut的杠杆头寸
        _validateBufferAmount(_tokenOut);

        // 从本合约转移数量为amountOutAfterFees的_tokenOut转移给_receiver
        _transferOut(_tokenOut, amountOutAfterFees, _receiver);
        // 抛出事件
        emit Swap(_receiver, _tokenIn, _tokenOut, amountIn, amountOut, amountOutAfterFees, feeBasisPoints);
        // 标志位useSwapPricing设置为false（该标志位实际上无作用，可以删除）
        useSwapPricing = false;
        // 返回最终转移给_receiver的_tokenOut数量
        return amountOutAfterFees;
    }

    // 进行开仓或加仓
    // 参数：
    // - _account：仓位持有人地址；
    // - _collateralToken：抵押token地址；
    // - _indexToken：标的token地址；
    // - _sizeDelta：仓位改变的增量（以USD计价，并带价格精度30）
    // - _isLong：true为加多仓，false为加空仓
    function increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) external override nonReentrant {
        // 要求可以开杠杆的开关是被打开状态
        _validate(isLeverageEnabled, 28);
        // 防止交易给出过高的gas price（防MEV）
        _validateGasPrice();
        // 检查当前msg.sender与被操作账户_account的关系
        _validateRouter(_account);
        // 对抵押token和标的token做的相关校验
        _validateTokens(_collateralToken, _indexToken, _isLong);
        // 更新抵押token的累计资金费率和最近一次更新资金费率的时间戳（如果当前距离上一次更新资金费率不到8小时，什么都不做）
        updateCumulativeFundingRate(_collateralToken);

        // 计算本仓位的key
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        // 获取仓位key对应的storage指针，指向仓位信息
        // 注：如果不存在对应仓位（即开仓），则position的所有成员值均为0
        Position storage position = positions[key];

        // 获取当前标的token价格。如果是做多，取标的token的大价格；如果是做空，取标的token的小价格
        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);
        if (position.size == 0) {
            // 如果是开仓操作（即第一次加仓），仓位的均价为price
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {
            // 如果是加仓（之前已有仓位大小）且加仓量大于0
            // 更新加仓后的仓位均价
            position.averagePrice = getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta, position.lastIncreasedTime);
        }

        // 收取margin fee（以USD计价，并带价格精度30）
        // margin fee为position fee + 资金费，这两部分费用均是以USD计价。最后会将margin fee折算成抵押token来收取
        uint256 fee = _collectMarginFees(_collateralToken, _sizeDelta, position.size, position.entryFundingRate);
        // collateralDelta为新转入Vault合约的新增抵押token数量
        uint256 collateralDelta = _transferIn(_collateralToken);
        // 计算刚转入Vault合约的抵押token的USD价值（带价格精度30）
        uint256 collateralDeltaUsd = tokenToUsdMin(_collateralToken, collateralDelta);

        // 仓位信息中的抵押token的累计价值自增collateralDeltaUsd
        position.collateral = position.collateral.add(collateralDeltaUsd);
        // 要求仓位的抵押token累计价值不小于当前的margin fee
        _validate(position.collateral >= fee, 29);
        // 从仓位信息中的抵押token的累计价值中扣除margin fee
        position.collateral = position.collateral.sub(fee);
        // 仓位信息中最近一次改变仓位大小时的累计资金费率 更新为 当前抵押token的累计资金费率
        position.entryFundingRate = cumulativeFundingRates[_collateralToken];
        // 仓位信息中的仓位大小自增_sizeDelta
        position.size = position.size.add(_sizeDelta);
        // 仓位信息中的最近一次加仓的时间戳更新为当前时间戳
        position.lastIncreasedTime = block.timestamp;
        // 要求加仓后仓位大小大于0
        _validate(position.size > 0, 30);
        // 做仓位检查
        _validatePosition(position.size, position.collateral);
        // 验证仓位加仓后不会触发清算。如果会触发清算 或 仓位杠杆数超过上限，会直接revert
        validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

        // reserve tokens to pay profits on the position
        // reserveDelta为：以抵押token的小价格做为单价，将 仓位改变的增量 兑换为抵押token的数量
        // 即本次加仓导致reserveAmount的改变量
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        // 本仓位的仓位大小对应的抵押token累计数量自增reserveDelta
        position.reserveAmount = position.reserveAmount.add(reserveDelta);
        _increaseReservedAmount(_collateralToken, reserveDelta);

        if (_isLong) {
            // 如果是加仓多仓
            // guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
            // if a fee is charged on the collateral then guaranteedUsd should be increased by that fee amount
            // since (position.size - position.collateral) would have increased by `fee`
            _increaseGuaranteedUsd(_collateralToken, _sizeDelta.add(fee));
            _decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // treat the deposited collateral as part of the pool
            _increasePoolAmount(_collateralToken, collateralDelta);
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, fee));
        } else {
            // 如果是加仓空仓
            if (globalShortSizes[_indexToken] == 0) {
                // 如果当前全局没有做空该标的token仓位，那么将全局做空该标的token的全部空仓均价设置为price
                globalShortAveragePrices[_indexToken] = price;
            } else {
                // 如果当前全局已有做空该标的token仓位，那么更新全局做空该标的token的全部空仓均价
                globalShortAveragePrices[_indexToken] = getNextGlobalShortAveragePrice(_indexToken, price, _sizeDelta);
            }
            // 全局做空该标的token仓位 自增 本次加空仓的仓位改变量
            globalShortSizes[_indexToken] = globalShortSizes[_indexToken].add(_sizeDelta);
        }

        // 抛出事件
        emit IncreasePosition(key, _account, _collateralToken, _indexToken, collateralDeltaUsd, _sizeDelta, _isLong, price, fee);
        emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);
    }

    function decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external override nonReentrant returns (uint256) {
        _validateGasPrice();
        _validateRouter(_account);
        return _decreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) private returns (uint256) {
        updateCumulativeFundingRate(_collateralToken);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];
        _validate(position.size > 0, 31);
        _validate(position.size >= _sizeDelta, 32);
        _validate(position.collateral >= _collateralDelta, 33);

        uint256 collateral = position.collateral;
        // scrop variables to avoid stack too deep errors
        {
            uint256 reserveDelta = position.reserveAmount.mul(_sizeDelta).div(position.size);
            position.reserveAmount = position.reserveAmount.sub(reserveDelta);
            _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);

        if (position.size != _sizeDelta) {
            position.entryFundingRate = cumulativeFundingRates[_collateralToken];
            position.size = position.size.sub(_sizeDelta);

            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral.sub(position.collateral));
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);
        } else {
            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral);
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit ClosePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);

            delete positions[key];
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            if (_isLong) {
                _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, usdOut));
            }
            uint256 amountOutAfterFees = usdToTokenMin(_collateralToken, usdOutAfterFee);
            _transferOut(_collateralToken, amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }

        return 0;
    }

    function liquidatePosition(address _account, address _collateralToken, address _indexToken, bool _isLong, address _feeReceiver) external nonReentrant {
        if (inPrivateLiquidationMode) {
            _validate(isLiquidator[msg.sender], 34);
        }

        // set includeAmmPrice to false prevent manipulated liquidations
        // 关闭获取抵押token价格时参考amm价格
        // 这是防止在进行清算时，通过闪电贷操控amm价格进而实现对仓位清算的操控
        includeAmmPrice = false;

        updateCumulativeFundingRate(_collateralToken);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.size > 0, 35);

        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(_account, _collateralToken, _indexToken, _isLong, false);
        _validate(liquidationState != 0, 36);
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(_account, _collateralToken, _indexToken, 0, position.size, _isLong, _account);
            return;
        }

        uint256 feeTokens = usdToTokenMin(_collateralToken, marginFees);
        feeReserves[_collateralToken] = feeReserves[_collateralToken].add(feeTokens);
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        _decreaseReservedAmount(_collateralToken, position.reserveAmount);
        if (_isLong) {
            _decreaseGuaranteedUsd(_collateralToken, position.size.sub(position.collateral));
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, marginFees));
        }

        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        emit LiquidatePosition(key, _account, _collateralToken, _indexToken, _isLong, position.size, position.collateral, position.reserveAmount, position.realisedPnl, markPrice);

        if (!_isLong && marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral.sub(marginFees);
            _increasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, remainingCollateral));
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, position.size);
        }

        delete positions[key];

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd));
        _transferOut(_collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd), _feeReceiver);

        includeAmmPrice = true;
    }

    // validateLiquidation returns (state, fees)
    // 验证当前仓位是否可清算。返回值有两个：1. 清算状态；2. 该仓位遭清算时可支付的起margin fee
    // 注：清算状态码含义。
    // - 状态0：该仓位不需要清算；
    // - 状态1：该仓位需要清算；
    // - 状态2：该仓位不需要被清算，但本仓位的杠杆数已超上限。
    // 参数：
    // - _account：持有该仓位的地址；
    // - _collateralToken：抵押token地址；
    // - _indexToken：标的token地址；
    // - _isLong：true为多仓，false为空仓；
    // - _raise：当清算状态出现非0状态时，是否引发revert。
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) public view returns (uint256, uint256) {
        // 计算仓位key
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        // 获取仓位key对应的storage指针，指向仓位信息
        Position memory position = positions[key];

        // 计算目前该仓位的盈亏情况
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
        // 计算目前该仓位目前产生的margin fee
        // 注：margin fee由资金费和position fee组成
        uint256 marginFees = getFundingFee(_collateralToken, position.size, position.entryFundingRate);
        // 此处涉及的position fee部分为：仓位改变量为整个仓位时产生的position fee
        marginFees = marginFees.add(getPositionFee(position.size));

        if (!hasProfit && position.collateral < delta) {
            // 如果该仓位目前处于亏损状态 且 亏损 大于 该仓位的抵押token的累计价值，说明此时已资不抵债
            // 如果_raise为true，则直接revert
            if (_raise) {revert("Vault: losses exceed collateral");}
            // 如果_raise为false，返回状态1和margin fee
            return (1, marginFees);
        }

        // 注：到此说明该仓位的抵押token的累计价值还能cover住亏损（如果仓位产生亏损的话）

        // remainingCollateral为该仓位的抵押token的累计价值
        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            // 如果该仓位目前处于亏损状态
            // 从remainingCollateral中减去亏损价值
            remainingCollateral = position.collateral.sub(delta);
        }

        // 如果仓位盈利，则remainingCollateral不变（无亏损）

        if (remainingCollateral < marginFees) {
            // 如果扣除亏损后的remainingCollateral不足以支付margin fee
            // 如果_raise为true，则直接revert
            if (_raise) {revert("Vault: fees exceed collateral");}

            // cap the fees to the remainingCollateral
            // 如果_raise为false，直接返回状态1和remainingCollateral
            // 即remainingCollateral直接全部充当margin fee
            return (1, remainingCollateral);
        }

        if (remainingCollateral < marginFees.add(liquidationFeeUsd)) {
            // 如果扣除亏损后的remainingCollateral足以支付margin fee，但是不足以再支付额外的清算fee时
            // 如果_raise为true，则直接revert
            if (_raise) {revert("Vault: liquidation fees exceed collateral");}
            // 如果_raise为false，直接返回状态1和margin fee
            return (1, marginFees);
        }

        if (remainingCollateral.mul(maxLeverage) < position.size.mul(BASIS_POINTS_DIVISOR)) {
            // 如果扣除亏损后的remainingCollateral足以支付margin fee + 清算fee
            // 但总仓位大小 已经大于 扣除亏损后的remainingCollateral * 最大杠杆数，即本仓位的杠杆数已超杠杆上限
            // 如果_raise为true，则直接revert
            if (_raise) {revert("Vault: maxLeverage exceeded");}
            // 如果_raise为false，直接返回状态2和margin fee
            return (2, marginFees);
        }

        // 至此，返回状态0和margin fee。即本仓位不需要清算
        return (0, marginFees);
    }

    // 获取_token的大价格（decimal为30）
    function getMaxPrice(address _token) public override view returns (uint256) {
        // 调用VaultPriceFeed合约的{getPrice}方法来获取_token的大价格
        return IVaultPriceFeed(priceFeed).getPrice(_token, true, includeAmmPrice, useSwapPricing);
    }

    // 获取_token的小价格（decimal为30）
    function getMinPrice(address _token) public override view returns (uint256) {
        // 调用VaultPriceFeed合约的{getPrice}方法来获取_token的小价格
        return IVaultPriceFeed(priceFeed).getPrice(_token, false, includeAmmPrice, useSwapPricing);
    }

    // 计算当前_usdgAmount数量的USDG可以兑换的_token数量
    // 注：返回值携带_token精度
    function getRedemptionAmount(address _token, uint256 _usdgAmount) public override view returns (uint256) {
        // 获取_token当前的大价格（带价格精度）
        uint256 price = getMaxPrice(_token);
        // 计算以price作为单价，_usdgAmount可以兑换成_token的数量
        // 即 _usdgAmount * 价格精度 / price，计算结果是带USDG精度的
        uint256 redemptionAmount = _usdgAmount.mul(PRICE_PRECISION).div(price);
        // 将redemptionAmount去除USDG精度并加入_token的精度
        return adjustForDecimals(redemptionAmount, usdg, _token);
    }

    function getRedemptionCollateral(address _token) public view returns (uint256) {
        if (stableTokens[_token]) {
            return poolAmounts[_token];
        }
        uint256 collateral = usdToTokenMin(_token, guaranteedUsd[_token]);
        return collateral.add(poolAmounts[_token]).sub(reservedAmounts[_token]);
    }

    function getRedemptionCollateralUsd(address _token) public view returns (uint256) {
        return tokenToUsdMin(_token, getRedemptionCollateral(_token));
    }

    // 精度调整。由于USDG和所有白名单token都有decimal，一些业务数值需要精度之间的转换
    // 即将业务数值_amount赋予_tokenMul的精度，然后再去除_tokenDiv的精度
    // 计算逻辑为： 输入_amount值先扩大_tokenMul的精度，然后再缩小_tokenDiv的精度
    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) public view returns (uint256) {
        // _tokenDiv和_tokenMul都是token地址，处理逻辑一样即：
        // 如果_tokenXxx是USDG地址，那么decimalXxx就是USDG的精度；如果_tokenXxx不是USDG地址，那么decimalXxx就是该token的精度（tokenDecimals[_tokenXxx]）
        uint256 decimalsDiv = _tokenDiv == usdg ? USDG_DECIMALS : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdg ? USDG_DECIMALS : tokenDecimals[_tokenMul];
        // 精度转换：amount * (10^decimalsMul) / (10^decimalsDiv)
        return _amount.mul(10 ** decimalsMul).div(10 ** decimalsDiv);
    }

    // 计算当前_tokenAmount数量的_token的USD价值（单价为_token的小价格）
    // 注：返回值的带有价格精度PRICE_PRECISION
    function tokenToUsdMin(address _token, uint256 _tokenAmount) public override view returns (uint256) {
        // 如果amount为0，返回0
        if (_tokenAmount == 0) {return 0;}
        // 获取_token当前的小价格（带价格decimal）
        uint256 price = getMinPrice(_token);
        // 获取_token的精度
        uint256 decimals = tokenDecimals[_token];
        // 计算USD价值，即_tokenAmount * token小价格 / 10^_token的精度
        return _tokenAmount.mul(price).div(10 ** decimals);
    }

    // 以_token的小价格作为单价，计算美元价值为_usdAmount的_token的数量。
    // 注：_usdAmount带价格精度30
    function usdToTokenMax(address _token, uint256 _usdAmount) public view returns (uint256) {
        // 如果美元价值为0，直接返回0
        if (_usdAmount == 0) {return 0;}
        // 以_token的小价格作为单价，计算美元价值为_usdAmount的_token的数量
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    // 以_token的大价格作为单价，计算美元价值为_usdAmount的_token的数量。
    // 注：_usdAmount带价格精度30
    function usdToTokenMin(address _token, uint256 _usdAmount) public view returns (uint256) {
        // 如果美元价值为0，直接返回0
        if (_usdAmount == 0) {return 0;}
        // 以_token的大价格作为单价，计算美元价值为_usdAmount的_token的数量
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    // 以_price作为_token的单价，计算美元价值为_usdAmount的_token的数量
    // 注：_usdAmount和_price都是带价格精度30
    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) public view returns (uint256) {
        // 如果美元价值为0，直接返回0
        if (_usdAmount == 0) {return 0;}
        // 获取_token的精度
        uint256 decimals = tokenDecimals[_token];
        // 计算_token数量，即美元价值 * _token精度 / _token价格
        return _usdAmount.mul(10 ** decimals).div(_price);
    }

    // 查询仓位信息
    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) public override view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0 ? uint256(position.realisedPnl) : uint256(- position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    }

    // 计算_account账户下以_collateralToken作为抵押token，_indexToken作为标的token的多仓或空仓（由_isLong决定）的仓位key
    // 注： 每一个仓位都有一个唯一对应的key
    function getPositionKey(address _account, address _collateralToken, address _indexToken, bool _isLong) public pure returns (bytes32) {
        // 将_account、_collateralToken、_indexToken和_isLong压缩连接后取hash
        return keccak256(abi.encodePacked(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        ));
    }

    // 更新_token的累积的资金费率（如果当前距离上一次更新资金费率不到8小时，什么都不做）
    // 注：会更新两个mapping：lastFundingTimes[_token]（最近一次更新_token的资金费率时间戳）和cumulativeFundingRates[_token]（_token的累计资金费率）
    function updateCumulativeFundingRate(address _token) public {
        if (lastFundingTimes[_token] == 0) {
            // 如果是第一次更新_token的funding rate
            // lastFundingTimes[_token]为 当前时间戳 / 8 hours * 8 hours
            lastFundingTimes[_token] = block.timestamp.div(fundingInterval).mul(fundingInterval);
            // 直接返回
            return;
        }

        if (lastFundingTimes[_token].add(fundingInterval) > block.timestamp) {
            // 如果当前时间戳距离上一次更新资金费率不到8小时
            // 什么都不做，直接返回
            return;
        }

        // 如果非第一次更新资金费率 && 当前时间戳距离上一次更新资金费率大于等于8小时
        // fundingRate为_token的下一个时间区间的资金费率
        uint256 fundingRate = getNextFundingRate(_token);
        // _token的累计资金费率自增fundingRate
        cumulativeFundingRates[_token] = cumulativeFundingRates[_token].add(fundingRate);
        // _token的最近更新资金费率的时间戳更新为：当前时间戳 / 8 hours * 8 hours
        lastFundingTimes[_token] = block.timestamp.div(fundingInterval).mul(fundingInterval);
        // 抛出事件
        emit UpdateFundingRate(_token, cumulativeFundingRates[_token]);
    }

    // 获取_token的下一个时间区间的资金费率
    // 注：reservedAmounts[_token]/poolAmounts[_token]越大，资金费率越高
    function getNextFundingRate(address _token) public override view returns (uint256) {
        // 如果当前时间戳距离上一次更新资金费率小于8小时，不需要更新资金费率，直接返回0
        if (lastFundingTimes[_token].add(fundingInterval) > block.timestamp) {return 0;}

        // 如果当前时间戳距离上一次更新资金费率大于等于8小时
        // intervals为(当前时间戳 - 上一次更新资金费率的时间戳)/8 hours，即当前距离上一次更新资金费率有多少个8 hours
        uint256 intervals = block.timestamp.sub(lastFundingTimes[_token]).div(fundingInterval);
        // poolAmount为目前可用于开杠杆的_token的数量
        uint256 poolAmount = poolAmounts[_token];
        // 如果可用于开杠杆的_token的数量为0，那也不需要资金费率了，直接返回0
        if (poolAmount == 0) {return 0;}

        // 如果可用于开杠杆的_token的数量不为0
        // 根据_token是否为稳定币，决定资金费率因数_fundingRateFactor是stableFundingRateFactor或fundingRateFactor
        uint256 _fundingRateFactor = stableTokens[_token] ? stableFundingRateFactor : fundingRateFactor;
        // 下一个时间区间的资金费率为：资金费率因数 * intervals *（目前已锁定在未平仓杠杆头寸中的token数量 / 目前可用于开杠杆的_token的数量）
        return _fundingRateFactor.mul(reservedAmounts[_token]).mul(intervals).div(poolAmount);
    }

    function getUtilisation(address _token) public view returns (uint256) {
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) {return 0;}

        return reservedAmounts[_token].mul(FUNDING_RATE_PRECISION).div(poolAmount);
    }

    function getPositionLeverage(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.collateral > 0, 37);
        return position.size.mul(BASIS_POINTS_DIVISOR).div(position.collateral);
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)

    // 计算经过加仓后的仓位均价（加权平均）
    // 参数：
    // - _indexToken: 仓位的标的token；
    // - _size：原仓位大小；
    // - _averagePrice：原仓位均价；
    // - _isLong：true为加多仓，false为加空仓；
    // - _nextPrice：加仓时，标的token的价格；
    // - _sizeDelta：仓位改变的增量；
    // - _lastIncreasedTime：最近一次加仓的时间戳
    function getNextAveragePrice(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _nextPrice, uint256 _sizeDelta, uint256 _lastIncreasedTime) public view returns (uint256) {
        // 根据传入的当前仓位的相关信息计算目前该仓位的盈亏情况
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime);
        // nextSize为加仓后的仓位大小
        uint256 nextSize = _size.add(_sizeDelta);
        // 定义除数
        uint256 divisor;
        if (_isLong) {
            // 如果是多仓且仓位盈利，除数为：加仓后的仓位大小 + 盈利值
            // 如果是多仓且仓位亏损，除数为：加仓后的仓位大小 - 盈利值
            divisor = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
        } else {
            // 如果是空仓且仓位盈利，除数为：加仓后的仓位大小 - 盈利值
            // 如果是空仓且仓位亏损，除数为：加仓后的仓位大小 + 盈利值
            divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
        }

        // 加仓后的仓位加权平均价格为：加仓时标的token价格 * 加仓后仓位大小 / 除数
        return _nextPrice.mul(nextSize).div(divisor);
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    // 计算经过加空仓后的全局针对_indexToken的总空仓均价（加权平均）
    // 参数：
    // - _indexToken: 加空仓的标的token；
    // - _nextPrice：加空仓时，标的token价格；
    // - _sizeDelta：仓位改变的增量
    function getNextGlobalShortAveragePrice(address _indexToken, uint256 _nextPrice, uint256 _sizeDelta) public view returns (uint256) {
        // size为 当前全局针对_indexToken的总空仓大小
        uint256 size = globalShortSizes[_indexToken];
        // averagePrice为 当前全局针对_indexToken的总空仓均价
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        // priceDelta为 | 当前全局针对_indexToken的总空仓均价 - 加空仓时的标的token价格 |
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice.sub(_nextPrice) : _nextPrice.sub(averagePrice);
        // delta为 当前全局针对_indexToken的总空仓大小 * priceDelta / 当前全局针对_indexToken的总空仓均价
        uint256 delta = size.mul(priceDelta).div(averagePrice);
        // hasProfit为 当前全局针对_indexToken的总空仓均价 是否大于 本次加空仓时的_indexToken价格
        bool hasProfit = averagePrice > _nextPrice;
        // nextSize为 加空仓后的全局针对_indexToken的总空仓大小
        uint256 nextSize = size.add(_sizeDelta);
        // 如果hasProfit为true，除数为：加空仓后的全局针对_indexToken的总空仓大小 - delta
        // 如果hasProfit为true，除数为：加空仓后的全局针对_indexToken的总空仓大小 - delta
        uint256 divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);

        // 加空仓后的全局针对_indexToken的总空仓均价为：加仓时标的token价格 * 加空仓后的全局针对_indexToken的总空仓大小 / 除数
        return _nextPrice.mul(nextSize).div(divisor);
    }

    function getGlobalShortDelta(address _token) public view returns (bool, uint256) {
        uint256 size = globalShortSizes[_token];
        if (size == 0) {return (false, 0);}

        uint256 nextPrice = getMaxPrice(_token);
        uint256 averagePrice = globalShortAveragePrices[_token];
        uint256 priceDelta = averagePrice > nextPrice ? averagePrice.sub(nextPrice) : nextPrice.sub(averagePrice);
        uint256 delta = size.mul(priceDelta).div(averagePrice);
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }

    function getPositionDelta(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
    }

    // 根据当前仓位的相关信息计算仓位的盈亏情况。返回值有两个：1. 盈亏标志（盈利为true，亏损为false）；2. 盈亏价值
    // 参数：
    // - _indexToken：仓位的标的token；
    // - _size：仓位大小；
    // - _averagePrice：仓位均价；
    // - _isLong：true为多仓，false为空仓；
    // - _lastIncreasedTime：最近一次加仓的时间戳
    // 注：如果对于同一仓位出现高频的加仓或减仓操作会触发最小盈利阈值限制检查
    function getDelta(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _lastIncreasedTime) public override view returns (bool, uint256) {
        // 要求仓位均价大于0
        _validate(_averagePrice > 0, 38);
        // 获取标的token价格。如果是多仓，price为小价格；如果是空仓，price为大价格
        uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        // priceDelta为仓位均价与标的token价格的差值
        uint256 priceDelta = _averagePrice > price ? _averagePrice.sub(price) : price.sub(_averagePrice);
        // 计算盈亏价值delta，即仓位仓位大小 * |仓位均价 - 标的token价格|/仓位均价
        uint256 delta = _size.mul(priceDelta).div(_averagePrice);
        // 定义盈亏标志hasProfit
        bool hasProfit;

        if (_isLong) {
            // 如果是多仓
            // 只有当标的token价格price大于仓位均价时，盈亏标志hasProfit才为true。否则为false
            hasProfit = price > _averagePrice;
        } else {
            // 如果是空仓
            // 只有当标的token价格price小于仓位均价时，盈亏标志hasProfit才为true。否则为false
            hasProfit = _averagePrice > price;
        }

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues

        // 如果当前时间戳 距离 该仓位上一次加仓时间戳 大于 minProfitTime，minBps为0。否则，为minProfitBasisPoints[_indexToken]
        uint256 minBps = block.timestamp > _lastIncreasedTime.add(minProfitTime) ? 0 : minProfitBasisPoints[_indexToken];

        if (hasProfit && delta.mul(BASIS_POINTS_DIVISOR) <= _size.mul(minBps)) {
            // 如果当前仓位盈利，但盈利价值/仓位大小 <= minBp/10000
            // 系统将判定这种情况盈利价值为0
            delta = 0;
        }

        // 返回盈亏标志和盈亏价值
        return (hasProfit, delta);
    }

    // 计算资金费（USDG计价），即：仓位大小 * (抵押token当前累计资金费率 - 本仓位最近一次改变仓位大小时的累计资金费率)
    // 参数：
    // - _token：本仓位的抵押token；
    // - _size：本仓位大小；
    // - _entryFundingRate: 最近一次改变本仓位大小时的累计资金费率
    function getFundingFee(address _token, uint256 _size, uint256 _entryFundingRate) public view returns (uint256) {
        // 仓位为0，无资金费，返回
        if (_size == 0) {return 0;}

        // fundingRate为本次应缴纳的资金费率
        // 即当前抵押token的累计资金费率 - 本仓位最近一次改变仓位大小时的累计资金费率
        uint256 fundingRate = cumulativeFundingRates[_token].sub(_entryFundingRate);
        // 如果本次应缴纳的资金费率为0，无资金费，返回
        if (fundingRate == 0) {return 0;}

        // 如果本次应缴纳的资金费率非0，应缴纳的资金费为：本仓位大小 * 本次应缴纳的资金费率 / FUNDING_RATE_PRECISION
        return _size.mul(fundingRate).div(FUNDING_RATE_PRECISION);
    }

    // 通过仓位改变量_sizeDelta计算position fee（以USD计价，并带价格精度30）
    // 即：_sizeDelta * marginFeeBasisPoints / 10000
    function getPositionFee(uint256 _sizeDelta) public view returns (uint256) {
        // 改变量为0，position fee为0
        if (_sizeDelta == 0) {return 0;}
        // afterFeeUsd为扣除position fee后的仓位改变量，即仓位改变量 * (10000 - 保证金手续费基点) / 10000
        uint256 afterFeeUsd = _sizeDelta.mul(BASIS_POINTS_DIVISOR.sub(marginFeeBasisPoints)).div(BASIS_POINTS_DIVISOR);
        // position fee就是_sizeDelta - afterFeeUsd
        // 注：之所以不直接用_sizeDelta * marginFeeBasisPoints / 10000计算，是因为该计算方式由于除法存在截断而导致计算结果略小于真实值
        // 通过反向减的方式可以增大手续费
        return _sizeDelta.sub(afterFeeUsd);
    }

    // cases to consider
    // 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
    // 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
    // 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
    // 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
    // 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
    // 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
    // 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
    // 8. a large swap should have similar fees as the same trade split into multiple smaller swaps

    // 计算改变_token的债务时的手续费基点
    // 参数：
    // - _token：目标token；
    // - _usdgDelta：USDG债务的改变量；
    // - _feeBasisPoints：默认的手续费基点；
    // - _taxBasisPoints：税费基点。即在动态手续费计算中，用于计算手续费减免和增加的基础基点；
    // - _increment：true表示增加债务，false表示减少债务。
    function getFeeBasisPoints(address _token, uint256 _usdgDelta, uint256 _feeBasisPoints, uint256 _taxBasisPoints, bool _increment) public override view returns (uint256) {
        // 如果不使用动态手续费，直接返回_feeBasisPoints作为手续费基点
        if (!hasDynamicFees) {return _feeBasisPoints;}

        // 如果使用动态手续费
        // initialAmount是为_token产生的全部USDG债务（USDG计价）
        uint256 initialAmount = usdgAmounts[_token];
        // nextAmount = initialAmount + _usdgDelta，即增加债务
        uint256 nextAmount = initialAmount.add(_usdgDelta);
        if (!_increment) {
            // 如果是减少债务，判断_usdgDelta是否大于为_token产生的全部USDG债务（USDG计价）
            // - 如果大于，那么nextAmount清0，即全部债务清零
            // - 如果不大于，nextAmount为initialAmount - _usdgDelta
            nextAmount = _usdgDelta > initialAmount ? 0 : initialAmount.sub(_usdgDelta);
        }

        // targetAmount是按照_token权重占token总权重的百分比计算出的_token产生的USDG的数量
        uint256 targetAmount = getTargetUsdgAmount(_token);
        // 如果targetAmount为0，直接返回_feeBasisPoints
        if (targetAmount == 0) {return _feeBasisPoints;}

        // initialDiff是 债务改变前，_token实际产生的USDG总债务 与 按照_token权重占token总权重的百分比计算出的USDG数量的差值
        uint256 initialDiff = initialAmount > targetAmount ? initialAmount.sub(targetAmount) : targetAmount.sub(initialAmount);
        // nextDiff是 债务改变后，_token实际产生的USDG总债务 与 按照_token权重占token总权重的百分比计算出的USDG数量的差值
        uint256 nextDiff = nextAmount > targetAmount ? nextAmount.sub(targetAmount) : targetAmount.sub(nextAmount);

        // action improves relative asset balance
        if (nextDiff < initialDiff) {
            // 如果债务改变后，_token实际产生的USDG总债务 与 按照_token权重占token总权重的百分比计算出的USDG数量的差值变小了，手续费上将获部分减免
            // rebateBps是减免的基点，计算公式为 _taxBasisPoints * initialDiff / targetAmount
            uint256 rebateBps = _taxBasisPoints.mul(initialDiff).div(targetAmount);
            // 最后的手续费基点为：
            // 如果rebateBps>_feeBasisPoints，直接不收手续费；
            // 如果rebateBps<_feeBasisPoints，最终手续费为_feeBasisPoints - rebateBps
            return rebateBps > _feeBasisPoints ? 0 : _feeBasisPoints.sub(rebateBps);
        }

        // 如果债务改变后，_token实际产生的USDG总债务 与 按照_token权重占token总权重的百分比计算出的USDG数量的差值没变小，手续费基点将变大
        // averageDiff是债务改变前后的diff均值，即(initialDiff + nextDiff)/2
        uint256 averageDiff = initialDiff.add(nextDiff).div(2);
        if (averageDiff > targetAmount) {
            // averageDiff的上限是targetAmount
            averageDiff = targetAmount;
        }
        // 手续费增加的基点为 _taxBasisPoints * averageDiff / targetAmount
        // 注：由于averageDiff<=targetAmount, 所以这续费增加的这部分基点taxBps最大为_taxBasisPoints
        uint256 taxBps = _taxBasisPoints.mul(averageDiff).div(targetAmount);
        // 最终手续费为_feeBasisPoints + taxBps
        return _feeBasisPoints.add(taxBps);
    }

    // 返回全部产生USDG中，由_token产生的USDG的数量。即按照_token权重占token总权重的百分比计算
    function getTargetUsdgAmount(address _token) public view returns (uint256) {
        // supply为当前usdg的总发行量
        uint256 supply = IERC20(usdg).totalSupply();
        // 如果usdg无发行量，直接返回0
        if (supply == 0) {return 0;}
        // 获取_token的权重
        uint256 weight = tokenWeights[_token];
        // 返回 usdg总发行量 * (_token权重 / token总权重)
        return weight.mul(supply).div(totalTokenWeights);
    }

    function _reduceCollateral(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(_collateralToken, _sizeDelta, position.size, position.entryFundingRate);
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = _sizeDelta.mul(delta).div(position.size);
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral.sub(adjustedDelta);

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _increasePoolAmount(_collateralToken, tokenAmount);
            }

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut = usdOut.add(_collateralDelta);
            position.collateral = position.collateral.sub(_collateralDelta);
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut = usdOut.add(position.collateral);
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut.sub(fee);
        } else {
            position.collateral = position.collateral.sub(fee);
            if (_isLong) {
                uint256 feeTokens = usdToTokenMin(_collateralToken, fee);
                _decreasePoolAmount(_collateralToken, feeTokens);
            }
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    // 校验仓位
    // 注：该检查为sanity check，即要求 本仓位大小 一定不可小于 本仓位的抵押token的累计价值
    function _validatePosition(uint256 _size, uint256 _collateral) private view {
        if (_size == 0) {
            // 如果仓位大小为0
            // 严格要求此时的本仓位的抵押token累计价值为0
            _validate(_collateral == 0, 39);
            return;
        }
        // 如果仓位大小不为0
        // 要求 本仓位大小 一定不可小于 本仓位的抵押token的累计价值
        _validate(_size >= _collateral, 40);
    }

    // 检查当前msg.sender与被操作账户_account的关系
    // 三种情况可以通过检验：1. _account自己本人调用；2.Router合约来调用；3.被添加到_account的授权router名单中的地址来调用
    // 注：只有{increasePosition}和{decreasePosition}时会调用
    function _validateRouter(address _account) private view {
        // 如果是_account自己本人在操作自己的仓位，直接通过
        if (msg.sender == _account) {return;}
        // 如果是通过Router合约来调用本合约，直接通过
        if (msg.sender == router) {return;}
        // 如果都不是以上情况，那么要求当前msg.sender是被_account授权过的
        _validate(approvedRouters[_account][msg.sender], 41);
    }

    // 加仓时对抵押token和标的token做的相关校验
    // 注：此处对标的token做出了限制，即
    // - 做多时，抵押token和标的token必须一样且只能做多非稳定币
    // - 做空时，抵押token必须是稳定币且只能做空非稳定币
    function _validateTokens(address _collateralToken, address _indexToken, bool _isLong) private view {
        if (_isLong) {
            // 如果是开多仓，那么：
            // 抵押token必须和标的token相同，即如果想做多BTC，那么抵押物必须是BTC
            _validate(_collateralToken == _indexToken, 42);
            // 抵押token必须是当前在册的白名单token
            _validate(whitelistedTokens[_collateralToken], 43);
            // 抵押token不可以是稳定币
            _validate(!stableTokens[_collateralToken], 44);
            return;
        }

        // 如果是开空仓，那么：
        // 抵押token必须是当前在册的白名单token
        _validate(whitelistedTokens[_collateralToken], 45);
        // 抵押token必须是稳定币
        _validate(stableTokens[_collateralToken], 46);
        // 标的token不可以是稳定币
        _validate(!stableTokens[_indexToken], 47);
        // 标的token是允许被做空的
        _validate(shortableTokens[_indexToken], 48);
    }

    // 收swap手续费，返回值为扣除手续费后的_token数量
    // _token和_amount确定了输入的token种类和数量，_feeBasisPoints为使用的手续费基点
    function _collectSwapFees(address _token, uint256 _amount, uint256 _feeBasisPoints) private returns (uint256) {
        // 扣除手续费后的值： _amount * (10000 - 手续费基点) / 10000
        uint256 afterFeeAmount = _amount.mul(BASIS_POINTS_DIVISOR.sub(_feeBasisPoints)).div(BASIS_POINTS_DIVISOR);
        // 作为手续费的_token数量：_amount - afterFeeAmount
        uint256 feeAmount = _amount.sub(afterFeeAmount);
        // _token的累计手续费自增feeAmount
        feeReserves[_token] = feeReserves[_token].add(feeAmount);
        // 抛出事件（手续费token种类，手续费的token数量，手续费的USD价值（小价格)）
        emit CollectSwapFees(_token, feeAmount, tokenToUsdMin(_token, feeAmount));
        // 返回扣除手续费后的_token数量
        return afterFeeAmount;
    }

    // 收加减仓手续费（即margin fee，以USDG计价），返回值为收取的margin fee
    // 注：
    // 1. margin fee由两部分组成：1. position fee；2. funding fee;
    // 2. 手续费以_token的形式收。
    // 参数：
    // - _token：仓位的抵押token；
    // - _sizeDelta：仓位改变的增量（以USD计价，并带价格精度30)；
    // - _size：仓位改变前的仓位大小；
    // - _entryFundingRate：最近一次改变仓位大小时的累计资金费率。
    function _collectMarginFees(address _token, uint256 _sizeDelta, uint256 _size, uint256 _entryFundingRate) private returns (uint256) {
        // 通过仓位改变量_sizeDelta计算position fee（以USD计价，并带价格精度30）
        // 注：该部分手续费是由仓位增量产生
        uint256 feeUsd = getPositionFee(_sizeDelta);
        // fundingFee为本仓位产生的资金费（以USD计价，并带价格精度30）
        // 注：该部分手续费是由原仓位产生
        uint256 fundingFee = getFundingFee(_token, _size, _entryFundingRate);
        // 要收取的margin fee为position fee和资金费之和
        feeUsd = feeUsd.add(fundingFee);

        // 以_token的大价格作为单价，计算margin fee等价值的_token的数量
        uint256 feeTokens = usdToTokenMin(_token, feeUsd);
        // _token的累计手续费自增feeTokens
        feeReserves[_token] = feeReserves[_token].add(feeTokens);

        // 抛出事件
        emit CollectMarginFees(_token, feeUsd, feeTokens);
        // 返回收取的margin fee
        return feeUsd;
    }

    // 向本合约转移_token后，同步更新tokenBalances[_token]并返回向本合约转移的_token数量
    function _transferIn(address _token) private returns (uint256) {
        // 向本合约转移_token之前的tokenBalances[_token]
        uint256 prevBalance = tokenBalances[_token];
        // nextBalance为转移后本合约名下的_token余额
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        // 更新tokenBalances[_token]为转移后本合约名下的_token余额
        tokenBalances[_token] = nextBalance;
        // 返回向本合约转入的_token数量
        return nextBalance.sub(prevBalance);
    }

    // 从本合约转移数量为_amount的_token转移给_receiver
    function _transferOut(address _token, uint256 _amount, address _receiver) private {
        // 将本合约名下数量为_amount的_token转移给_receiver
        IERC20(_token).safeTransfer(_receiver, _amount);
        // tokenBalances[_token]更新为转移后本合约名下的_token余额
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    // 同步更新tokenBalances[_token]，使其与当前本合约名下_token的余额取齐
    function _updateTokenBalance(address _token) private {
        // 获取本合约名下的_token余额
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        // 更新tokenBalances[_token]为nextBalance
        tokenBalances[_token] = nextBalance;
    }

    // 增加全局可用于开杠杆的_token的数量_amount
    function _increasePoolAmount(address _token, uint256 _amount) private {
        // poolAmounts[_token]自增_amount
        poolAmounts[_token] = poolAmounts[_token].add(_amount);
        // 本合约名下的_token数量
        uint256 balance = IERC20(_token).balanceOf(address(this));
        // 要求增加后的可用于开杠杆的_token的数量不可大于本合约名下的_token数量
        _validate(poolAmounts[_token] <= balance, 49);
        // 抛出事件
        emit IncreasePoolAmount(_token, _amount);
    }

    // 减少全局可用于开杠杆的_token的数量_amount
    function _decreasePoolAmount(address _token, uint256 _amount) private {
        // poolAmounts[_token]自减_amount
        poolAmounts[_token] = poolAmounts[_token].sub(_amount, "Vault: poolAmount exceeded");
        // 要求减少后的可用于开杠杆的_token的数量不可小于目前池中已用于开杠杆的该token数量
        // todo ??
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 50);
        // 抛出事件
        emit DecreasePoolAmount(_token, _amount);
    }

    // 对_token进行现有杠杆头寸的可兑付检查
    function _validateBufferAmount(address _token) private view {
        // 要求此时的 可用于开杠杆头寸的_tokenOut数量 >= 支持杠杆头寸兑付的_tokenOut数量
        // 如果poolAmounts[_token] < bufferAmounts[_token]，可能导致现有的杠杆头寸平仓后无法对付
        if (poolAmounts[_token] < bufferAmounts[_token]) {
            revert("Vault: poolAmount < buffer");
        }
    }

    // 增加为_token的产生的USDG债务，债务增量为_amount（以USDG计价）
    function _increaseUsdgAmount(address _token, uint256 _amount) private {
        // 增加为_token的产生的USDG债务，债务增量为_amount
        usdgAmounts[_token] = usdgAmounts[_token].add(_amount);
        // 获取允许为_token产生的USDG债务上限
        uint256 maxUsdgAmount = maxUsdgAmounts[_token];
        if (maxUsdgAmount != 0) {
            // 如果债务上限不为0，那么要求增加债务后_token的债务不得大于该债务上限
            _validate(usdgAmounts[_token] <= maxUsdgAmount, 51);
        }
        // 抛出事件
        emit IncreaseUsdgAmount(_token, _amount);
    }

    // 减少为_token的产生的USDG债务，债务减量为_amount（以USDG计价）
    function _decreaseUsdgAmount(address _token, uint256 _amount) private {
        // 获取当前为_token的产生的USDG债务
        uint256 value = usdgAmounts[_token];
        // 因为USDG可以通过白名单中的所有token来铸造，那么某个单一资产的债务有可能会小于0。比如：全部USDG通过BTC来mint，但是偏要用USDT来赎回
        // 所以当出现负债务的时候，直接将债务下限设为0
        if (value <= _amount) {
            // 如果减少量大于等于当前为_token的产生的USDG债务
            // 直接将为_token的产生的USDG债务清0
            usdgAmounts[_token] = 0;
            // 抛出事件
            emit DecreaseUsdgAmount(_token, value);
            // 返回
            return;
        }
        // 如果减少量小于当前为_token的产生的USDG债务
        // _token的债务减去债务减少量
        usdgAmounts[_token] = value.sub(_amount);
        // 抛出事件
        emit DecreaseUsdgAmount(_token, _amount);
    }

    // 增加为全局保留_token的产生的USDG债务，增量为_amount
    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].add(_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 52);
        emit IncreaseReservedAmount(_token, _amount);
    }

    function _decreaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].sub(_amount, "Vault: insufficient reserve");
        emit DecreaseReservedAmount(_token, _amount);
    }

    function _increaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].add(_usdAmount);
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].sub(_usdAmount);
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
            globalShortSizes[_token] = 0;
            return;
        }

        globalShortSizes[_token] = size.sub(_amount);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    // 用于校验msg.sender是gov。之所以不用modifier是为了减小合约的字节码长度。
    function _onlyGov() private view {
        // 要求msg.sender为gov，否则revert
        _validate(msg.sender == gov, 53);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    // 用于检验msg.sender是否是manager（当合约进入manager模式时）
    function _validateManager() private view {
        if (inManagerMode) {
            // 如果Vault合约处于manager模式下，要求msg.sender必须是在册的manager
            _validate(isManager[msg.sender], 54);
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    // 防止交易给出过高的gas price（防MEV）
    function _validateGasPrice() private view {
        // 如果全局的maxGasPrice为0，直接返回，即不做检查
        if (maxGasPrice == 0) {return;}
        // 如果全局的maxGasPrice不为0，要求当前交易的gas price不可大于maxGasPrice，否则revert
        _validate(tx.gasprice <= maxGasPrice, 55);
    }

    // 用于做校验的helper函数。_condition为要校验的条件判断布尔值，_errorCode为如果出现revert那么将返回的错误编号
    function _validate(bool _condition, uint256 _errorCode) private view {
        // 要求_condition为true，否则revert并返回编号为_errorCode的error msg
        require(_condition, errors[_errorCode]);
    }
}