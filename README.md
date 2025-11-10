# KipuBankV3

# KipuBankV3

KipuBankV3 es una extensión de KipuBankV2 orientada a una aplicación DeFi más realista.  
El objetivo principal de esta versión es permitir depósitos en cualquier token soportado por Uniswap V2, convertir esos depósitos automáticamente a USDC, y mantener el balance interno del usuario siempre en USDC.  
Además, se conserva la lógica original de KipuBankV2 respecto al manejo de balances, retiros y control administrativo.


## Mejoras principales implementadas

### 1. Depósitos generalizados
En KipuBankV2 solo se podían manejar algunos tokens específicos.  
En KipuBankV3, ahora los usuarios pueden depositar:

- ETH
- USDC directamente
- Cualquier token ERC-20 que tenga un par directo con USDC en Uniswap V2

Si el token no es USDC, el contrato:
1. Recibe el token.
2. Hace el swap automático a USDC usando el router de Uniswap V2.
3. Acredita el resultado final en el balance del usuario.

Esto permite que el banco pueda recibir depósitos más variados sin que el usuario tenga que hacer el swap manualmente.

-

### 2. Integración con Uniswap V2
Se utiliza el contrato "IUniswapV2Router02" para:

- Swappear ETH por USDC
- Swappear ERC-20 → USDC
- Consultar precios estimados (`getAmountsOut`) antes del swap

Esto permite calcular cuánto USDC debería recibir el usuario y también aplicar límites de slippage.

-

### 3. Respeto del "bankCap"
El banco tiene un límite máximo de USDC que puede mantener.  
Antes de acreditar el depósito, se verifica que el nuevo total no supere el límite.  
Si se superaría, la transacción simplemente revierte.

Esto protege a la aplicación de una acumulación de fondos mayor a la que el banco está preparado para manejar.



### 4. Lógica de KipuBankV2 preservada
Se mantuvieron:
- Los mecanismos de retiro en USDC
- El conteo de depósitos/retiros
- El sistema de roles administrativos usando "AccessControl"
- Protección contra reentradas ("ReentrancyGuard")



## Instrucciones de despliegue

### Requisitos
- Foundry o Hardhat
- RPC de la red donde se quiera desplegar (mainnet, testnet, etc.)
- Direcciones del router, factory, USDC y WETH de la red elegida

### Ejemplo con Foundry
```bash
forge create --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  src/KipuBankV3.sol:KipuBankV3 \
  --constructor-args <router> <factory> <usdc> <weth> <bank
