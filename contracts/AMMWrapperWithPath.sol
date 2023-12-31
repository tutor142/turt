// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./AMMWrapper.sol";
import "./interfaces/IAMMWrapperWithPath.sol";
import "./interfaces/IBalancerV2Vault.sol";
import "./interfaces/IPermanentStorage.sol";
import "./interfaces/ISpender.sol";
import "./interfaces/IUniswapRouterV2.sol";
import "./utils/AMMLibEIP712.sol";
import "./utils/LibBytes.sol";
import "./utils/LibConstant.sol";
import "./utils/LibUniswapV3.sol";

contract AMMWrapperWithPath is IAMMWrapperWithPath, AMMWrapper {
    using SafeMath for uint16;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using LibBytes for bytes;

    // Constants do not have storage slot.
    address public immutable UNISWAP_V3_ROUTER_ADDRESS;

    /************************************************************
     *              Constructor and init functions               *
     *************************************************************/
    constructor(
        address _operator,
        uint256 _subsidyFactor,
        address _userProxy,
        ISpender _spender,
        IPermanentStorage _permStorage,
        IWETH _weth,
        address _uniswapV2Router,
        address _sushiwapRouter,
        address _uniswapV3Router
    ) AMMWrapper(_operator, _subsidyFactor, _userProxy, _spender, _permStorage, _weth, _uniswapV2Router, _sushiwapRouter) {
        UNISWAP_V3_ROUTER_ADDRESS = _uniswapV3Router;
    }

    /************************************************************
     *                   External functions                      *
     *************************************************************/

    function trade(
        AMMLibEIP712.Order calldata _order,
        uint256 _feeFactor,
        bytes calldata _sig,
        bytes calldata _makerSpecificData,
        address[] calldata _path
    ) external payable override nonReentrant onlyUserProxy returns (uint256) {
        require(_order.deadline >= block.timestamp, "AMMWrapper: expired order");
        TxMetaData memory txMetaData;
        InternalTxData memory internalTxData;

        // These variables are copied straight from function parameters and
        // used to bypass stack too deep error.
        txMetaData.subsidyFactor = uint16(subsidyFactor);
        txMetaData.feeFactor = uint16(_feeFactor);
        internalTxData.makerSpecificData = _makerSpecificData;
        internalTxData.path = _path;
        if (!permStorage.isRelayerValid(tx.origin)) {
            txMetaData.feeFactor = (txMetaData.subsidyFactor > txMetaData.feeFactor) ? txMetaData.subsidyFactor : txMetaData.feeFactor;
            txMetaData.subsidyFactor = 0;
        }

        // Assign trade vairables
        internalTxData.fromEth = (_order.takerAssetAddr == LibConstant.ZERO_ADDRESS || _order.takerAssetAddr == LibConstant.ETH_ADDRESS);
        internalTxData.toEth = (_order.makerAssetAddr == LibConstant.ZERO_ADDRESS || _order.makerAssetAddr == LibConstant.ETH_ADDRESS);
        if (_isCurve(_order.makerAddr)) {
            // PermanetStorage can recognize `ETH_ADDRESS` but not `ZERO_ADDRESS`.
            // Convert it to `ETH_ADDRESS` as passed in `_order.takerAssetAddr` or `_order.makerAssetAddr` might be `ZERO_ADDRESS`.
            internalTxData.takerAssetInternalAddr = internalTxData.fromEth ? LibConstant.ETH_ADDRESS : _order.takerAssetAddr;
            internalTxData.makerAssetInternalAddr = internalTxData.toEth ? LibConstant.ETH_ADDRESS : _order.makerAssetAddr;
        } else {
            internalTxData.takerAssetInternalAddr = internalTxData.fromEth ? address(weth) : _order.takerAssetAddr;
            internalTxData.makerAssetInternalAddr = internalTxData.toEth ? address(weth) : _order.makerAssetAddr;
        }

        txMetaData.transactionHash = _verify(_order, _sig);

        _prepare(_order, internalTxData);

        // minAmount = makerAssetAmount * (10000 - subsidyFactor) / 10000
        uint256 _minAmount = _order.makerAssetAmount.mul((LibConstant.BPS_MAX.sub(txMetaData.subsidyFactor))).div(LibConstant.BPS_MAX);
        (txMetaData.source, txMetaData.receivedAmount) = _swapWithPath(_order, internalTxData, _minAmount);

        // Settle
        txMetaData.settleAmount = _settle(_order, txMetaData, internalTxData);

        emit Swapped(txMetaData, _order);

        return txMetaData.settleAmount;
    }

    /**
     * @dev internal function of `trade`.
     * Used to tell if maker is Curve.
     */
    function _isCurve(address _makerAddr) internal view override returns (bool) {
        if (_makerAddr == UNISWAP_V2_ROUTER_02_ADDRESS || _makerAddr == UNISWAP_V3_ROUTER_ADDRESS || _makerAddr == SUSHISWAP_ROUTER_ADDRESS) {
            return false;
        }
        return true;
    }

    /**
     * @dev internal function of `trade`.
     * It executes the swap on chosen AMM.
     */
    function _swapWithPath(
        AMMLibEIP712.Order memory _order,
        InternalTxData memory _internalTxData,
        uint256 _minAmount
    )
        internal
        approveTakerAsset(_internalTxData.takerAssetInternalAddr, _order.makerAddr, _order.takerAssetAmount)
        returns (string memory source, uint256 receivedAmount)
    {
        if (_order.makerAddr == UNISWAP_V2_ROUTER_02_ADDRESS || _order.makerAddr == SUSHISWAP_ROUTER_ADDRESS) {
            source = (_order.makerAddr == SUSHISWAP_ROUTER_ADDRESS) ? "SushiSwap" : "Uniswap V2";
            // Sushiswap shares the same interface as Uniswap's
            receivedAmount = _tradeUniswapV2TokenToToken(
                _order.makerAddr,
                _internalTxData.takerAssetInternalAddr,
                _internalTxData.makerAssetInternalAddr,
                _order.takerAssetAmount,
                _minAmount,
                _order.deadline,
                _internalTxData.path
            );
        } else if (_order.makerAddr == UNISWAP_V3_ROUTER_ADDRESS) {
            source = "Uniswap V3";
            receivedAmount = _tradeUniswapV3TokenToToken(
                _internalTxData.takerAssetInternalAddr,
                _internalTxData.makerAssetInternalAddr,
                _order.deadline,
                _order.takerAssetAmount,
                _minAmount,
                _internalTxData.makerSpecificData
            );
        } else {
            // Try to match maker with Curve pool list
            CurveData memory curveData;
            (curveData.fromTokenCurveIndex, curveData.toTokenCurveIndex, curveData.swapMethod, ) = permStorage.getCurvePoolInfo(
                _order.makerAddr,
                _internalTxData.takerAssetInternalAddr,
                _internalTxData.makerAssetInternalAddr
            );

            require(curveData.swapMethod != 0, "AMMWrapper: swap method not registered");
            if (curveData.fromTokenCurveIndex > 0 && curveData.toTokenCurveIndex > 0) {
                source = "Curve";
                // Substract index by 1 because indices stored in `permStorage` starts from 1
                curveData.fromTokenCurveIndex = curveData.fromTokenCurveIndex - 1;
                curveData.toTokenCurveIndex = curveData.toTokenCurveIndex - 1;
                // Curve does not return amount swapped so we need to record balance change instead.
                uint256 balanceBeforeTrade = _getSelfBalance(_internalTxData.makerAssetInternalAddr);
                _tradeCurveTokenToToken(
                    _order.makerAddr,
                    curveData.fromTokenCurveIndex,
                    curveData.toTokenCurveIndex,
                    _order.takerAssetAmount,
                    _minAmount,
                    curveData.swapMethod
                );
                uint256 balanceAfterTrade = _getSelfBalance(_internalTxData.makerAssetInternalAddr);
                receivedAmount = balanceAfterTrade.sub(balanceBeforeTrade);
            } else {
                revert("AMMWrapper: unsupported makerAddr");
            }
        }
    }

    /* Uniswap V2 */

    function _tradeUniswapV2TokenToToken(
        address _makerAddr,
        address _takerAssetAddr,
        address _makerAssetAddr,
        uint256 _takerAssetAmount,
        uint256 _makerAssetAmount,
        uint256 _deadline,
        address[] memory _path
    ) internal returns (uint256) {
        IUniswapRouterV2 router = IUniswapRouterV2(_makerAddr);
        if (_path.length == 0) {
            _path = new address[](2);
            _path[0] = _takerAssetAddr;
            _path[1] = _makerAssetAddr;
        } else {
            _validateAMMPath(_path, _takerAssetAddr, _makerAssetAddr);
        }
        uint256[] memory amounts = router.swapExactTokensForTokens(_takerAssetAmount, _makerAssetAmount, _path, address(this), _deadline);
        return amounts[amounts.length - 1];
    }

    function _validateAMMPath(
        address[] memory _path,
        address _takerAssetAddr,
        address _makerAssetAddr
    ) internal {
        require(_path.length >= 2, "AMMWrapper: path length must be at least two");
        require(_path[0] == _takerAssetAddr, "AMMWrapper: first element of path must match taker asset");
        require(_path[_path.length - 1] == _makerAssetAddr, "AMMWrapper: last element of path must match maker asset");
    }

    /* Uniswap V3 */

    function _tradeUniswapV3TokenToToken(
        address _takerAssetAddr,
        address _makerAssetAddr,
        uint256 _deadline,
        uint256 _takerAssetAmount,
        uint256 _makerAssetAmount,
        bytes memory _makerSpecificData
    ) internal returns (uint256 amountOut) {
        LibUniswapV3.SwapType swapType = LibUniswapV3.SwapType(uint256(_makerSpecificData.readBytes32(0)));

        // exactInputSingle
        if (swapType == LibUniswapV3.SwapType.ExactInputSingle) {
            (, uint24 poolFee) = abi.decode(_makerSpecificData, (uint8, uint24));
            return
                LibUniswapV3.exactInputSingle(
                    UNISWAP_V3_ROUTER_ADDRESS,
                    LibUniswapV3.ExactInputSingleParams({
                        tokenIn: _takerAssetAddr,
                        tokenOut: _makerAssetAddr,
                        fee: poolFee,
                        recipient: address(this),
                        deadline: _deadline,
                        amountIn: _takerAssetAmount,
                        amountOutMinimum: _makerAssetAmount
                    })
                );
        }

        // exactInput
        if (swapType == LibUniswapV3.SwapType.ExactInput) {
            (, bytes memory path) = abi.decode(_makerSpecificData, (uint8, bytes));
            return
                LibUniswapV3.exactInput(
                    UNISWAP_V3_ROUTER_ADDRESS,
                    LibUniswapV3.ExactInputParams({
                        tokenIn: _takerAssetAddr,
                        tokenOut: _makerAssetAddr,
                        path: path,
                        recipient: address(this),
                        deadline: _deadline,
                        amountIn: _takerAssetAmount,
                        amountOutMinimum: _makerAssetAmount
                    })
                );
        }

        revert("AMMWrapper: unsupported UniswapV3 swap type");
    }
}
