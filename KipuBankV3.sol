// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal metadata interface to query decimals if available.
interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}

/// @notice Minimal Chainlink Aggregator V3 interface (TOKEN/USD).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @notice Minimal Uniswap V2 interfaces in ^0.8 to avoid pragma conflicts.
interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

struct TokenConfig {
    bool supported;         // Habilitado (para vistas / límites de retiro)
    bool isNative;          // ETH pseudo-token (address(0))
    uint8 tokenDecimals;    // Decimales
    uint256 withdrawLimit;  // Límite por retiro (en unidades del token)
    address priceFeed;      // Chainlink TOKEN/USD (opcional)
}

/// @title KipuBankV3
/// @notice Acepta ETH/USDC/ERC20; si no es USDC, se swapea a USDC (router V2) y se acredita en USDC.
contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
    address public constant NATIVE_TOKEN = address(0);
    uint8 public constant USD_DECIMALS = 6; // USDC estándar (6)

    /*//////////////////////////////////////////////////////////////
                                ESTADO
    //////////////////////////////////////////////////////////////*/

    // Cap global en USD(6) (= USDC 6 dec)
    uint256 public immutable bankCapUsd6;
    // Total acumulado acreditado en USD(6)
    uint256 public totalDepositedUsd6;

    // router/factory y USDC
    IUniswapV2Router02 public immutable router;
    IUniswapV2Factory  public immutable factory;
    address public immutable USDC;

    // balances en el banco (solo significativo para USDC en V3)
    mapping(address => mapping(address => uint256)) private balances;

    // configuración por token (para vistas/oráculos/withdraw limits, compatibilidad V2)
    mapping(address => TokenConfig) public tokenConfig;

    // contadores
    uint256 public depositCount;
    uint256 public withdrawCount;

    /*//////////////////////////////////////////////////////////////
                                  ERRORES
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error UnsupportedToken(address token);
    error CapExceeded(uint256 attempted, uint256 cap);
    error InsufficientBalance(uint256 have, uint256 want);
    error PairDoesNotExist(address tokenIn, address tokenOut);
    error PriceFeedNotSet(address token);
    error PriceNegative();

    /*//////////////////////////////////////////////////////////////
                                  EVENTOS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed tokenCredited, address indexed user, uint256 amountIn, uint256 newBalance, uint256 usdcCredited);
    event Withdraw(address indexed tokenDebited, address indexed user, uint256 amount, uint256 newBalance);
    event TokenConfigured(address indexed token, bool supported, bool isNative, uint8 decimals, uint256 withdrawLimit, address priceFeed);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _bankCapUsd6,
        address ethPriceFeed,
        address usdcToken,
        address routerV2,
        address factoryV2,
        uint256 ethWithdrawLimit
    ) {
        if (_bankCapUsd6 == 0) revert ZeroAmount();
        if (usdcToken == address(0) || routerV2 == address(0) || factoryV2 == address(0)) {
            revert UnsupportedToken(address(0));
        }

        bankCapUsd6 = _bankCapUsd6;
        USDC = usdcToken;
        router = IUniswapV2Router02(routerV2);
        factory = IUniswapV2Factory(factoryV2);

        // Roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ROLE_ADMIN, msg.sender);

        // ETH config (para vistas y límites de retiro)
        {
            TokenConfig memory cfg;
            cfg.supported = true;
            cfg.isNative = true;
            cfg.tokenDecimals = 18;
            cfg.withdrawLimit = ethWithdrawLimit;
            cfg.priceFeed = ethPriceFeed;
            tokenConfig[NATIVE_TOKEN] = cfg;
            emit TokenConfigured(NATIVE_TOKEN, true, true, 18, ethWithdrawLimit, ethPriceFeed);
        }

        // USDC config (decimales detectados si es posible)
        {
            TokenConfig memory cfg;
            cfg.supported = true;
            cfg.isNative  = false;
            uint8 dec = 6;
            try IERC20Metadata(USDC).decimals() returns (uint8 d) { dec = d; } catch {}
            cfg.tokenDecimals = dec;
            cfg.withdrawLimit = type(uint256).max;
            cfg.priceFeed     = address(0);
            tokenConfig[USDC] = cfg;
            emit TokenConfigured(USDC, true, false, dec, cfg.withdrawLimit, cfg.priceFeed);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier nonZero(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Agrega/actualiza token (para vistas/oráculos/lim. retiro).
    /// @dev En V3 se acredita USDC; otros tokens sólo se aceptan para depósito y se swapean.
    function setTokenConfig(
        address token,
        bool supported,
        uint8 tokenDecimals,
        uint256 withdrawLimit,
        address priceFeed
    ) external onlyRole(ROLE_ADMIN) {
        if (token == NATIVE_TOKEN) revert UnsupportedToken(token);

        TokenConfig storage cfg = tokenConfig[token];
        cfg.supported = supported;
        cfg.isNative = false;

        if (tokenDecimals == 0) {
            try IERC20Metadata(token).decimals() returns (uint8 dec) {
                cfg.tokenDecimals = dec;
            } catch {
                cfg.tokenDecimals = 18;
            }
        } else {
            cfg.tokenDecimals = tokenDecimals;
        }
        cfg.withdrawLimit = withdrawLimit;
        cfg.priceFeed = priceFeed;

        emit TokenConfigured(token, supported, false, cfg.tokenDecimals, withdrawLimit, priceFeed);
    }

    /*//////////////////////////////////////////////////////////////
                                   VISTAS
    //////////////////////////////////////////////////////////////*/

    function getBalance(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    /// @dev Estimación en USD(6); 1:1 para USDC.
    function getUsdBalance(address token, address user) external view returns (uint256) {
        uint256 amt = balances[token][user];
        if (token == USDC) return amt;
        return _toUsd(token, amt);
    }

    /*//////////////////////////////////////////////////////////////
                                  DEPÓSITOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Depósito directo de USDC.
    function depositUSDC(uint256 amount)
        external
        nonReentrant
        nonZero(amount)
    {
        uint256 attempted = totalDepositedUsd6 + amount;
        if (attempted > bankCapUsd6) revert CapExceeded(attempted, bankCapUsd6);

        // effects
        balances[USDC][msg.sender] += amount;
        totalDepositedUsd6 = attempted;
        unchecked { depositCount++; }

        // interactions
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(USDC, msg.sender, amount, balances[USDC][msg.sender], amount);
    }

    /// @notice Depósito de ETH: se swapea a USDC usando el router V2.
    function depositETH(uint256 amountOutMin)
        external
        payable
        nonReentrant
    {
        if (msg.value == 0) revert ZeroAmount();

        // path: WETH -> USDC
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = USDC;

        uint256 beforeBal = IERC20(USDC).balanceOf(address(this));
        router.swapExactETHForTokens{value: msg.value}(amountOutMin, path, address(this), block.timestamp);
        uint256 afterBal = IERC20(USDC).balanceOf(address(this));
        uint256 outUSDC  = afterBal - beforeBal;

        uint256 attempted = totalDepositedUsd6 + outUSDC;
        if (attempted > bankCapUsd6) revert CapExceeded(attempted, bankCapUsd6);

        balances[USDC][msg.sender] += outUSDC;
        totalDepositedUsd6 = attempted;
        unchecked { depositCount++; }

        emit Deposit(USDC, msg.sender, msg.value, balances[USDC][msg.sender], outUSDC);
    }

    /// @notice Depósito de un ERC20 distinto a USDC -> swap a USDC dentro del contrato.
    function depositTokenAndSwap(address token, uint256 amount, uint256 amountOutMin)
        external
        nonReentrant
        nonZero(amount)
    {
        if (token == address(0)) revert UnsupportedToken(token);
        if (token == USDC) revert UnsupportedToken(token); // usar depositUSDC

        // Debe existir par directo TOKEN/USDC
        address pair = factory.getPair(token, USDC);
        if (pair == address(0)) revert PairDoesNotExist(token, USDC);

        // Pull + approve
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).safeIncreaseAllowance(address(router), amount);

        // path: TOKEN -> USDC
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = USDC;

        uint256 beforeBal = IERC20(USDC).balanceOf(address(this));
        router.swapExactTokensForTokens(amount, amountOutMin, path, address(this), block.timestamp);
        uint256 afterBal = IERC20(USDC).balanceOf(address(this));
        uint256 outUSDC  = afterBal - beforeBal;

        uint256 attempted = totalDepositedUsd6 + outUSDC;
        if (attempted > bankCapUsd6) revert CapExceeded(attempted, bankCapUsd6);

        balances[USDC][msg.sender] += outUSDC;
        totalDepositedUsd6 = attempted;
        unchecked { depositCount++; }

        emit Deposit(USDC, msg.sender, amount, balances[USDC][msg.sender], outUSDC);
    }

    /*//////////////////////////////////////////////////////////////
                                  RETIROS
    //////////////////////////////////////////////////////////////*/

    function withdrawUSDC(uint256 amount)
    external
    nonReentrant
    nonZero(amount)
{
    uint256 bal = balances[USDC][msg.sender];
    if (bal < amount) revert InsufficientBalance(bal, amount);

    // effects
    balances[USDC][msg.sender] = bal - amount;

    unchecked {
        if (totalDepositedUsd6 >= amount) {
            totalDepositedUsd6 -= amount;
        } else {
            totalDepositedUsd6 = 0; // por seguridad defensiva
        }
        withdrawCount++;
    }

    // interactions
    IERC20(USDC).safeTransfer(msg.sender, amount);

    emit Withdraw(USDC, msg.sender, amount, balances[USDC][msg.sender]);
}


    /*//////////////////////////////////////////////////////////////
                           AUXILIAR: Chainlink a USD(6)
    //////////////////////////////////////////////////////////////*/

    function _toUsd(address token, uint256 amount) internal view returns (uint256 usd6) {
        if (amount == 0) return 0;
        TokenConfig memory cfg = tokenConfig[token];
        address feed = cfg.priceFeed;
        if (feed == address(0)) revert PriceFeedNotSet(token);

        (, int256 price,,,) = AggregatorV3Interface(feed).latestRoundData();
        if (price <= 0) revert PriceNegative();

        // amount (tokenDecimals) * price (priceDecimals) -> USD(6)
        uint256 p = uint256(price);
        uint8 pd = AggregatorV3Interface(feed).decimals();
        uint256 numerator = amount * p;

        if (pd > 0) {
            numerator = numerator / (10 ** pd);
        }

        if (cfg.tokenDecimals >= USD_DECIMALS) {
            uint256 factor = 10 ** (cfg.tokenDecimals - USD_DECIMALS);
            usd6 = numerator / factor;
        } else {
            uint256 factor = 10 ** (USD_DECIMALS - cfg.tokenDecimals);
            usd6 = numerator * factor;
        }
    }
}
