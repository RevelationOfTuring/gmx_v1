// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "src/libraries/utils/ReentrancyGuard.sol";
import "src/access/Governable.sol";
import "src/core/interfaces/IGlpManager.sol";
import "src/core/interfaces/IShortsTracker.sol";
import "src/libraries/token/SafeERC20.sol";
import "src/tokens/interfaces/IMintable.sol";
import "src/tokens/interfaces/IUSDG.sol";

// https://arbiscan.io/address/0x3963FfC9dff443c2A94f21b129D429891E32ec18
contract GlpManager is ReentrancyGuard, Governable, IGlpManager {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // 价格精度
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    // USDG精度
    uint256 public constant USDG_DECIMALS = 18;
    // GLP精度
    uint256 public constant GLP_PRECISION = 10 ** 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    // Vault合约对象
    IVault public override vault;
    // ShortsTracker合约对象
    IShortsTracker public shortsTracker;
    address public override usdg;
    address public override glp;

    uint256 public override cooldownDuration;
    // 添加流动性的地址 -> 最近一次该地址添加流动性的时间戳
    mapping(address => uint256) public override lastAddedAt;

    // 计算AUM的额外增加的数量
    // 主网该值目前是0
    uint256 public aumAddition;
    // 计算AUM的额外减少的数量
    // 主网该值目前是0
    uint256 public aumDeduction;

    // 控制可以直接与GlpManager交互增减流动性的开关
    // 注：此开关为false时，可以直接与GlpManager交互增减流动性
    // 主网目前该值为true
    bool public inPrivateMode;
    // 处理从ShortsTracker中获取的均价的权重
    // 主网该值目前是10000
    uint256 public shortsTrackerAveragePriceWeight;
    mapping(address => bool) public isHandler;

    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 aumInUsdg,
        uint256 glpSupply,
        uint256 usdgAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 glpAmount,
        uint256 aumInUsdg,
        uint256 glpSupply,
        uint256 usdgAmount,
        uint256 amountOut
    );

    constructor(address _vault, address _usdg, address _glp, address _shortsTracker, uint256 _cooldownDuration) public {
        gov = msg.sender;
        vault = IVault(_vault);
        usdg = _usdg;
        glp = _glp;
        shortsTracker = IShortsTracker(_shortsTracker);
        cooldownDuration = _cooldownDuration;
    }

    function setInPrivateMode(bool _inPrivateMode) external onlyGov {
        inPrivateMode = _inPrivateMode;
    }

    function setShortsTracker(IShortsTracker _shortsTracker) external onlyGov {
        shortsTracker = _shortsTracker;
    }

    function setShortsTrackerAveragePriceWeight(uint256 _shortsTrackerAveragePriceWeight) external override onlyGov {
        require(shortsTrackerAveragePriceWeight <= BASIS_POINTS_DIVISOR, "GlpManager: invalid weight");
        shortsTrackerAveragePriceWeight = _shortsTrackerAveragePriceWeight;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setCooldownDuration(uint256 _cooldownDuration) external override onlyGov {
        require(_cooldownDuration <= MAX_COOLDOWN_DURATION, "GlpManager: invalid _cooldownDuration");
        cooldownDuration = _cooldownDuration;
    }

    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction) external onlyGov {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }

    // 调用者添加数量为_amount的_token作为流动性，并获得GLP
    // 参数：
    // - _token：流动性token地址；
    // - _amount：添加流动性token的数量；
    // - _minUsdg：可接受的全部流动性token换成USDG的最小数量
    // - _minGlp：可接受的换来GLP的最小数量
    function addLiquidity(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGlp) external override nonReentrant returns (uint256) {
        // 如果inPrivateMode为true时，表示不允许直接与本合约交互来增添流动性。直接revert
        if (inPrivateMode) {revert("GlpManager: action not enabled");}
        // 调用_addLiquidity()来执行具体的增加流动性操作
        // 注：流动性token的from和GLP的to都是msg.sender
        return _addLiquidity(msg.sender, msg.sender, _token, _amount, _minUsdg, _minGlp);
    }

    // handler调用该方法，将_fundingAccount名下数量为_amount的_token添加为流动性，并将获得GLP发给_account
    function addLiquidityForAccount(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGlp) external override nonReentrant returns (uint256) {
        // 验证msg.sender是handler
        _validateHandler();
        // 调用_addLiquidity()来执行具体的增加流动性操作
        // 注：流动性token的from是_fundingAccount，GLP的to是_account
        return _addLiquidity(_fundingAccount, _account, _token, _amount, _minUsdg, _minGlp);
    }

    function removeLiquidity(address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        if (inPrivateMode) {revert("GlpManager: action not enabled");}
        return _removeLiquidity(msg.sender, _tokenOut, _glpAmount, _minOut, _receiver);
    }

    function removeLiquidityForAccount(address _account, address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _removeLiquidity(_account, _tokenOut, _glpAmount, _minOut, _receiver);
    }

    // 计算当前GLP的价格（带价格精度）
    // 注：返回值为1 GLP的美元价格
    function getPrice(bool _maximise) external view returns (uint256) {
        // 计算vault合约中的AUM的美元价值（带价格精度）
        uint256 aum = getAum(_maximise);
        // glpSupply为当前GLP的总发行量
        uint256 supply = IERC20(glp).totalSupply();
        // GLP当前价格为 aum/(GLP发行量/GLP精度)
        return aum.mul(GLP_PRECISION).div(supply);
    }

    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = getAum(true);
        amounts[1] = getAum(false);
        return amounts;
    }

    // 计算整个流动性池的资产管理规模（以USDG计价）
    // 注：maximise为true表示使用各token的大价格计算AUM，如果maximise为false则表示使用各token的小价格计算AUM
    function getAumInUsdg(bool maximise) public override view returns (uint256) {
        // 计算vault合约中的AUM的美元价值（带价格精度）
        uint256 aum = getAum(maximise);
        // 将上述AUM的美元价值转换成USDG数量
        return aum.mul(10 ** USDG_DECIMALS).div(PRICE_PRECISION);
    }

    // 计算vault合约中的AUM的美元价值（带价格精度），即资产管理规模（asset under management）
    // maximise为true表示使用各token的大价格计算AUM，如果maximise为false则表示使用各token的小价格计算AUM
    function getAum(bool maximise) public view returns (uint256) {
        // 获取vault合约中token白名单数组的长度
        uint256 length = vault.allWhitelistedTokensLength();
        // aum的初始值为aumAddition
        uint256 aum = aumAddition;
        // 全部的空仓的浮盈美元价值为0
        uint256 shortProfits = 0;
        // 定义vault合约的临时局部变量，为了节约gas
        IVault _vault = vault;

        // 开始遍历vault合约的token白名单数组
        for (uint256 i = 0; i < length; i++) {
            // 依次获取token白名单中的成员token地址
            address token = vault.allWhitelistedTokens(i);
            // 该token是否处于真实的token白名单中
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                // 如果该token已经被移除了白名单，直接开始下一轮循环
                continue;
            }

            // 获取该token当前的价格。如果maximise为true则为该token的大价格，反之为小价格
            uint256 price = maximise ? _vault.getMaxPrice(token) : _vault.getMinPrice(token);
            // 获取在vault中，所有服务于开杠杆的该token的数量
            uint256 poolAmount = _vault.poolAmounts(token);
            // 获取该token的精度
            uint256 decimals = _vault.tokenDecimals(token);

            if (_vault.stableTokens(token)) {
                // 如果该token为稳定币
                // 计算poolAmount的美元价值（带价格精度）：price * (poolAmount/10**decimals)
                // aum自增该token的poolAmount的美元价值
                aum = aum.add(poolAmount.mul(price).div(10 ** decimals));
            } else {
                // 如果该token是非稳定币
                // 注：由于开仓者的对手方是整个池子，是个零和博弈。所以，全部仓位的盈利就相当于整个池子的亏损。
                // 反之，整个仓位仓的亏损就相当于整个池子的盈利

                // add global short profit / loss
                // size为该token作为标的token的全部空仓的仓位大小之和
                uint256 size = _vault.globalShortSizes(token);

                if (size > 0) {
                    // 如果全局存在做空该token的仓位
                    // 计算以当前标的token的现价结算，目前全局做空该token的总仓位的盈亏价值 与 盈亏情况
                    // hasProfit为true表示全局空仓总仓位目前处于盈利状态，为false则表示目前处于亏损状态
                    // delta为全局空仓总仓位目前的盈亏价值（恒为正）
                    (uint256 delta, bool hasProfit) = getGlobalShortDelta(token, price, size);
                    if (!hasProfit) {
                        // add losses from shorts
                        // 如果全局做空该token空仓总仓位目前处于亏损状态（相当于开仓者亏，池子赚）
                        // aum要加入这部分亏损的价值
                        aum = aum.add(delta);
                    } else {
                        // 如果全局做空该token空仓总仓位目前处于盈利状态（相当于开仓者赚，池子亏）
                        // shortProfits要加入这部分盈利的价值
                        shortProfits = shortProfits.add(delta);
                    }
                }


                // aum要加入Vault合约中记录的所有该token的多仓的position.size - position.collateral的总和
                // aum加入全部该token的多仓向Vault池子借的美元债务
                aum = aum.add(_vault.guaranteedUsd(token));
                // reservedAmount为Vault合约中全局用于兑付所有仓位（以该token为抵押token的仓位）头寸的该token数量
                uint256 reservedAmount = _vault.reservedAmounts(token);
                // (poolAmount-reservedAmount)*price/10**decimals即目前Vault合约中处于全部闲置的该token的美元价值
                // aum再自增以上部分
                aum = aum.add(poolAmount.sub(reservedAmount).mul(price).div(10 ** decimals));
            }
        }

        // 遍历完所有白名单token之后
        // 如果
        aum = shortProfits > aum ? 0 : aum.sub(shortProfits);
        // aum最后再扣除aumDeduction。如果aum不够减，那么直接截取到0
        return aumDeduction > aum ? 0 : aum.sub(aumDeduction);
    }

    // 计算以当前标的token的现价结算，全局做空该token的总仓位的盈亏价值 与 盈亏情况
    // 注：第二个bool类型的返回值为true，表明盈利；否则为亏损。
    // 参数：
    // - _token：做空的标的token地址；
    // - _price：_token当前的价格；
    // - _size：全局做空_token的全部仓位大小之和
    function getGlobalShortDelta(address _token, uint256 _price, uint256 _size) public view returns (uint256, bool) {
        // averagePrice为 全局做空_token的全部仓位的仓位均价
        uint256 averagePrice = getGlobalShortAveragePrice(_token);
        // priceDelta为 全局做空_token的全部仓位的仓位均价 与 _token的当前价格的差值
        uint256 priceDelta = averagePrice > _price ? averagePrice.sub(_price) : _price.sub(averagePrice);
        // delta为：全局做空_token的全部仓位大小之和 * (|全局做空_token的全部仓位的仓位均价 - _token的当前价格的差值|/全局做空_token的全部仓位的仓位均价)
        uint256 delta = _size.mul(priceDelta).div(averagePrice);
        // 返回(delta, _token当前价格是否小于全局做空_token的全部仓位的仓位均价)
        return (delta, averagePrice > _price);
    }

    // 获取Vault合约中，全局做空_token的空仓总仓位的均价
    function getGlobalShortAveragePrice(address _token) public view returns (uint256) {
        // 缓存ShortsTracker合约对象
        IShortsTracker _shortsTracker = shortsTracker;
        if (address(_shortsTracker) == address(0) || !_shortsTracker.isGlobalShortDataReady()) {
            // 如果ShortsTracker合约地址为0 或 ShortsTracker合约尚未做data的初始化
            // 直接返回Vault合约中记录的 全局以_token作为标的token的全部空仓的仓位均价
            return vault.globalShortAveragePrices(_token);
        }

        // 如果ShortsTracker合约地址不为0 且 ShortsTracker合约已完成data的初始化
        // _shortsTrackerAveragePriceWeight为：缓存全局的 处理从ShortsTracker中获取的均价的权重
        uint256 _shortsTrackerAveragePriceWeight = shortsTrackerAveragePriceWeight;
        if (_shortsTrackerAveragePriceWeight == 0) {
            // 如果处理的权重为0
            // 直接返回Vault合约中记录的 全局以_token作为标的token的全部空仓的仓位均价
            return vault.globalShortAveragePrices(_token);
        } else if (_shortsTrackerAveragePriceWeight == BASIS_POINTS_DIVISOR) {
            // 如果处理的权重为10000
            // 直接返回ShortsTracker合约中记录的 全局以_token作为标的token的全部空仓的仓位均价
            return _shortsTracker.globalShortAveragePrices(_token);
        }

        // 入股处理的权重介于(0,10000)之间
        // vaultAveragePrice为：Vault合约中记录的 全局以_token作为标的token的全部空仓的仓位均价
        uint256 vaultAveragePrice = vault.globalShortAveragePrices(_token);
        // shortsTrackerAveragePrice为：ShortsTracker合约中记录的 全局以_token作为标的token的全部空仓的仓位均价
        uint256 shortsTrackerAveragePrice = _shortsTracker.globalShortAveragePrices(_token);
        // 返回以上两个价格的加权平均值：
        // ( vaultAveragePrice*(10000-处理的权重) + shortsTrackerAveragePrice*处理的权重 )/10000
        return vaultAveragePrice.mul(BASIS_POINTS_DIVISOR.sub(_shortsTrackerAveragePriceWeight))
        .add(shortsTrackerAveragePrice.mul(_shortsTrackerAveragePriceWeight))
        .div(BASIS_POINTS_DIVISOR);
    }

    // _fundingAccount账户添加数量为_amount的_token作为流动性，并将得到的GLP发放给_account
    // 注：整个流程：全部流动性token卖给Vault合约，换取等价值的USDG给本合约。
    // 参数：
    // - _fundingAccount：流动性token的from；
    // - _account：GLP的接收地址；
    // - _token：流动性token地址；
    // - _amount：添加流动性token的数量；
    // - _minUsdg：可接受的全部流动性token换成USDG的最小数量
    // - _minGlp：可接受的换来GLP的最小数量
    function _addLiquidity(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGlp) private returns (uint256) {
        // 要求添加流动性token数量大于0
        require(_amount > 0, "GlpManager: invalid _amount");

        // calculate aum before buyUSDG
        // 计算当前整个流动性池的资产管理规模（以USDG计价）
        uint256 aumInUsdg = getAumInUsdg(true);
        // glpSupply为当前GLP的总发行量
        uint256 glpSupply = IERC20(glp).totalSupply();
        // 将数量为_amount的_token从_fundingAccount名下转移到Vault合约中
        IERC20(_token).safeTransferFrom(_fundingAccount, address(vault), _amount);
        // 调用Vault合约的buyUSDG()方法，将_token卖成等价值的USDG给本合约
        // usdgAmount为本合约收到的USDG数量
        uint256 usdgAmount = vault.buyUSDG(_token, address(this));
        // 要求这部分USDG数量不小于 可接受的全部流动性token换成USDG的最小数量
        require(usdgAmount >= _minUsdg, "GlpManager: insufficient USDG output");
        // 计算换来的GLP数量
        // - 如果添加流动性之前的总资产规模为0，那么将与换来的USDG 1：1 置换GLP；
        // - 如果添加流动性之前的总资产规模不为0，那么换来GLP数量为：( 换来的USDG数量 占 整个流动性池的资产管理规模（以USDG计价）的比例) * GLP发行量
        uint256 mintAmount = aumInUsdg == 0 ? usdgAmount : usdgAmount.mul(glpSupply).div(aumInUsdg);
        // 要求换来的GLP数量不小于 可接受的换来GLP的最小数量
        require(mintAmount >= _minGlp, "GlpManager: insufficient GLP output");
        // 为_account增发数量为mintAmount的GLP
        IMintable(glp).mint(_account, mintAmount);
        // 更新_account最近一次添加流动性的时间戳
        lastAddedAt[_account] = block.timestamp;
        // 抛出事件
        emit AddLiquidity(_account, _token, _amount, aumInUsdg, glpSupply, usdgAmount, mintAmount);
        // 返回换来的GLP数量
        return mintAmount;
    }

    function _removeLiquidity(address _account, address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) private returns (uint256) {
        require(_glpAmount > 0, "GlpManager: invalid _glpAmount");
        require(lastAddedAt[_account].add(cooldownDuration) <= block.timestamp, "GlpManager: cooldown duration not yet passed");

        // calculate aum before sellUSDG
        uint256 aumInUsdg = getAumInUsdg(false);
        uint256 glpSupply = IERC20(glp).totalSupply();

        uint256 usdgAmount = _glpAmount.mul(aumInUsdg).div(glpSupply);
        uint256 usdgBalance = IERC20(usdg).balanceOf(address(this));
        if (usdgAmount > usdgBalance) {
            IUSDG(usdg).mint(address(this), usdgAmount.sub(usdgBalance));
        }

        IMintable(glp).burn(_account, _glpAmount);

        IERC20(usdg).transfer(address(vault), usdgAmount);
        uint256 amountOut = vault.sellUSDG(_tokenOut, _receiver);
        require(amountOut >= _minOut, "GlpManager: insufficient output");

        emit RemoveLiquidity(_account, _tokenOut, _glpAmount, aumInUsdg, glpSupply, usdgAmount, amountOut);

        return amountOut;
    }

    // 验证msg.sender是handler
    function _validateHandler() private view {
        require(isHandler[msg.sender], "GlpManager: forbidden");
    }
}