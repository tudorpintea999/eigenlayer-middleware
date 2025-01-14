// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "src/BLSRegistryCoordinatorWithIndices.sol";

// wrapper around the BLSRegistryCoordinatorWithIndices contract that exposes the internal functions for unit testing.
contract BLSRegistryCoordinatorWithIndicesHarness is BLSRegistryCoordinatorWithIndices {
    constructor(
        ISlasher _slasher,
        IServiceManager _serviceManager,
        IStakeRegistry _stakeRegistry,
        IBLSPubkeyRegistry _blsPubkeyRegistry,
        IIndexRegistry _indexRegistry
    ) BLSRegistryCoordinatorWithIndices(_slasher, _serviceManager, _stakeRegistry, _blsPubkeyRegistry, _indexRegistry) {
    }

    function setQuorumCount(uint8 count) external {
        quorumCount = count;
    }

    function setOperatorId(address operator, bytes32 operatorId) external {
        _operatorInfo[operator].operatorId = operatorId;
    }

    function recordOperatorQuorumBitmapUpdate(bytes32 operatorId, uint192 quorumBitmap) external {
        uint256 operatorQuorumBitmapHistoryLength = _operatorBitmapHistory[operatorId].length;
        if (operatorQuorumBitmapHistoryLength != 0) {
            _operatorBitmapHistory[operatorId][operatorQuorumBitmapHistoryLength - 1].nextUpdateBlockNumber = uint32(block.number);
        }

        _operatorBitmapHistory[operatorId].push(QuorumBitmapUpdate({
            updateBlockNumber: uint32(block.number),
            nextUpdateBlockNumber: 0,
            quorumBitmap: quorumBitmap
        }));
    }
}
