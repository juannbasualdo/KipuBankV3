// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Interfaz mínima de metadatos para consultar `decimals()` si está disponible.
interface IERC20Metadata is IERC20 {
    /// @notice Devuelve la cantidad de decimales del token.
    function decimals() external view returns (uint8);
}

/// @notice Interfaz mínima de Chainlink Aggregator V3 (precio TOKEN/USD).
interface AggregatorV3Interface {
    /// @notice Devuelve la cantidad de decimales del oráculo.
    function decimals() external view returns (uint8);
    /// @notice Retorna los datos de la última ronda del oráculo.
    /// @dev `answer` representa el precio TOKEN/USD con `decimals()` dígitos.
    /// @return roundId ID de la ronda
    /// @return answer Precio actual (puede ser negativo si el oráculo lo señalara, se valida en el contrato)
    /// @return startedAt Marca temporal de inicio
    /// @return updatedAt Marca temporal de última actualización
    /// @return answeredInRound Ronda en la que se respondió
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

/// @notice Interfaces mínimas de Uniswap V2 en ^0.8 para evitar conflictos de pragma.
interface IUniswapV2Router02 {
    /// @notice Dirección de WETH en la red actual.
    function WETH() external pure returns (address);
    /// @notice Swapea ETH por tokens exactos según un mínimo de salida.
    /// @param amountOutMin Mínimo de tokens a recibir
    /// @param path Ruta de swap (por ejemplo [WETH, USDC])
    /// @param to Destinatario de los tokens
    /// @param deadline Tiempo límite
    /// @return amounts Montos intermedios y final del swap
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    /// @notice Swapea tokens por tokens exactos según un mínimo de salida.
    /// @param amountIn Monto de entrada
    /// @param amountOutMin Mínimo de salida en el token destino
    /// @param path Ruta de swap (por ejemplo [TOKEN, USDC])
    /// @param to Destinatario de los tokens
    /// @param deadline Tiempo límite
    /// @return amounts Montos intermedios y final del swap
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    /// @notice Devuelve la dirección del par para `tokenA` y `tokenB` si existe.
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice Configuración auxiliar por token (compatibilidad V2).
struct TokenConfig {
    bool supported;         // Habilitado (para vistas / límites de retiro)
    bool isNative;          // ETH pseudo-token (address(0))
    uint8 tokenDecimals;    // Decimales
    uint256 withdrawLimit;  // Límite por retiro (en unidades del token)
    address priceFeed;      // Chainlink TOKEN/USD (opcional)
}

/// @title KipuBankV3
/// @notice Acepta ETH/USDC/ERC20; si no es USDC, se swapea a USDC (router V2) y se acredita en USDC.
/// @dev Integra Uniswap V2 para swaps, respeta un tope global en USD(6) (`bankCapUsd6`) y mantiene compatibilidad conceptual con KipuBankV2.
contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTES
    //////////////////////////////////////////////////////////////*/

    /// @notice Rol administrativo para operaciones de configuración.
    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
    /// @notice Pseudo-token para ETH (dirección cero).
    address public constant NATIVE_TOKEN = address(0);
    /// @notice Cantidad de decimales estándar para USD(6) / USDC.
    uint8 public constant USD_DECIMALS = 6; // USDC estándar (6)

    /*//////////////////////////////////////////////////////////////
                                ESTADO
    //////////////////////////////////////////////////////////////*/

    /// @notice Tope global del banco expresado en USD(6) (= USDC 6 dec).
    uint256 public immutable bankCapUsd6;
    /// @notice Total acumulado acreditado en USD(6).
    uint256 public totalDepositedUsd6;

    /// @notice Router/Factory de Uniswap V2 y token USDC.
    IUniswapV2Router02 public immutable router;
    IUniswapV2Factory  public immutable factory;
    address public immutable USDC;

    /// @notice Balances por (token -> usuario). En V3 el saldo significativo es el asociado a USDC.
    mapping(address => mapping(address => uint256)) private balances;

    /// @notice Configuración por token (para vistas, oráculos y límites de retiro; compatibilidad con V2).
    mapping(address => TokenConfig) public tokenConfig;

    /// @notice Contadores de operaciones.
    uint256 public depositCount;
    uint256 public withdrawCount;

    /*//////////////////////////////////////////////////////////////
                                  ERRORES
    //////////////////////////////////////////////////////////////*/

    /// @notice Error: monto cero.
    error ZeroAmount();
    /// @notice Error: token no soportado.
    error UnsupportedToken(address token);
    /// @notice Error: el intento de depósito supera el tope global del banco.
    error CapExceeded(uint256 attempted, uint256 cap);
    /// @notice Error: saldo insuficiente para retirar.
    error InsufficientBalance(uint256 have, uint256 want);
    /// @notice Error: no existe par directo TOKEN/USDC en la factory V2.
    error PairDoesNotExist(address tokenIn, address tokenOut);
    /// @notice Error: no se definió un price feed de Chainlink para el token consultado.
    error PriceFeedNotSet(address token);
    /// @notice Error: el oráculo devolvió un precio negativo o inválido.
    error PriceNegative();

    /*//////////////////////////////////////////////////////////////
                                  EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emite información al acreditar un depósito (en USDC) a un usuario.
    /// @param tokenCredited Token acreditado (USDC en V3 tras el swap)
    /// @param user Usuario que depositó
    /// @param amountIn Cantidad ingresada (en el token de entrada)
    /// @param newBalance Nuevo balance del usuario en el token acreditado
    /// @param usdcCredited Cantidad concreta de USDC acreditada
    event Deposit(address indexed tokenCredited, address indexed user, uint256 amountIn, uint256 newBalance, uint256 usdcCredited);

    /// @notice Emite información al procesar un retiro en USDC.
    /// @param tokenDebited Token debitado (USDC en V3)
    /// @param user Usuario que retira
    /// @param amount Monto retirado
    /// @param newBalance Nuevo balance del usuario tras el retiro
    event Withdraw(address indexed tokenDebited, address indexed user, uint256 amount, uint256 newBalance);

    /// @notice Emite información cuando se configura/actualiza un token soportado.
    /// @param token Dirección del token
    /// @param supported Si está habilitado para vistas/validaciones
    /// @param isNative Si representa al pseudo-token nativo (ETH)
    /// @param decimals Decimales
    /// @param withdrawLimit Límite por retiro
    /// @param priceFeed Dirección del oráculo Chainlink (si aplica)
    event TokenConfigured(address indexed token, bool supported, bool isNative, uint8 decimals, uint256 withdrawLimit, address priceFeed);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Inicializa el contrato con el tope global en USD(6), direcciones base y límites de retiro.
    /// @dev Configura roles de administración, parámetros de ETH y USDC, y dependencias de Uniswap V2.
    /// @param _bankCapUsd6 Tope global del banco en USD(6)
    /// @param ethPriceFeed Oráculo de precio ETH/USD (Chainlink)
    /// @param usdcToken Dirección del token USDC
    /// @param routerV2 Dirección del router de Uniswap V2
    /// @param factoryV2 Dirección de la factory de Uniswap V2
    /// @param ethWithdrawLimit Límite por retiro para ETH (en wei)
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

    /// @notice Exige que el monto sea distinto de cero.
    /// @param amount Monto a validar
    modifier nonZero(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Agrega o actualiza la configuración de un token (para vistas/oráculos/límites de retiro).
    /// @dev En V3 se acredita USDC; otros tokens sólo se aceptan para depósito y se swapean.
    /// @param token Dirección del token a configurar (no puede ser address(0) para esta función)
    /// @param supported Si el token estará habilitado a nivel de vistas o límites
    /// @param tokenDecimals Decimales del token (si es 0 se intenta detectar vía IERC20Metadata)
    /// @param withdrawLimit Límite por retiro en unidades del token
    /// @param priceFeed Dirección del oráculo Chainlink TOKEN/USD (opcional)
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

    /// @notice Devuelve el balance del usuario en un token específico.
    /// @param token Dirección del token a consultar
    /// @param user Dirección del usuario
    /// @return balance Cantidad de `token` asignada al `user`
    function getBalance(address token, address user) external view returns (uint256 balance) {
        return balances[token][user];
    }

    /// @notice Estima el balance del usuario expresado en USD(6).
    /// @dev Para USDC retorna 1:1; para otros tokens se usa el oráculo asociado (si existe).
    /// @param token Dirección del token a consultar
    /// @param user Dirección del usuario
    /// @return usdBalance Balance estimado en USD(6)
    function getUsdBalance(address token, address user) external view returns (uint256 usdBalance) {
        uint256 amt = balances[token][user];
        if (token == USDC) return amt;
        return _toUsd(token, amt);
    }

    /*//////////////////////////////////////////////////////////////
                                  DEPÓSITOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Depósito directo de USDC.
    /// @param amount Monto de USDC a depositar
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
    /// @param amountOutMin Mínimo de USDC a recibir al swappear
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
    /// @param token Dirección del token de entrada (distinto a USDC)
    /// @param amount Cantidad del token de entrada a depositar
    /// @param amountOutMin Mínimo de USDC a recibir al swappear
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

    /// @notice Retira USDC del balance del usuario.
    /// @param amount Cantidad de USDC a retirar
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

    /// @notice Convierte un monto `amount` del `token` dado a USD(6) usando Chainlink.
    /// @dev Requiere `priceFeed` configurado en `tokenConfig[token]`.
    /// @param token Dirección del token a convertir
    /// @param amount Monto del token a convertir
    /// @return usd6 Monto expresado en USD(6)
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
