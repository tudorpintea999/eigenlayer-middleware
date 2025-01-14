// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "src/interfaces/IServiceManager.sol";
import "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import "eigenlayer-contracts/src/contracts/interfaces/ISlasher.sol";

contract MiddlewareRegistryMock{
    IServiceManager public serviceManager;
    IStrategyManager public strategyManager;
    ISlasher public slasher;


    constructor(
        IServiceManager _serviceManager,
        IStrategyManager _strategyManager
    ) {
        serviceManager = _serviceManager;
        strategyManager = _strategyManager;
        slasher = _strategyManager.slasher();
    }

    function registerOperator(address operator, uint32 serveUntil) public {        
        require(slasher.canSlash(operator, address(serviceManager)), "Not opted into slashing");

    }

    function deregisterOperator(address operator) public {
    }

    function isActiveOperator(address operator) external pure returns (bool) {
        if (operator != address(0)) {
            return true;
        } else {
            return false;
        }
    }

}
