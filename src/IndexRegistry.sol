// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import {IndexRegistryStorage} from "src/IndexRegistryStorage.sol";
import {IRegistryCoordinator} from "src/interfaces/IRegistryCoordinator.sol";

/**
 * @title A `Registry` that keeps track of an ordered list of operators for each quorum
 * @author Layr Labs, Inc.
 */
contract IndexRegistry is IndexRegistryStorage {

    /// @notice when applied to a function, only allows the RegistryCoordinator to call it
    modifier onlyRegistryCoordinator() {
        require(msg.sender == address(registryCoordinator), "IndexRegistry.onlyRegistryCoordinator: caller is not the registry coordinator");
        _;
    }

    /// @notice sets the (immutable) `registryCoordinator` address
    constructor(
        IRegistryCoordinator _registryCoordinator
    ) IndexRegistryStorage(_registryCoordinator) {}

    /*******************************************************************************
                      EXTERNAL FUNCTIONS - REGISTRY COORDINATOR
    *******************************************************************************/

    /**
     * @notice Registers the operator with the specified `operatorId` for the quorums specified by `quorumNumbers`.
     * @param operatorId is the id of the operator that is being registered
     * @param quorumNumbers is the quorum numbers the operator is registered for
     * @return numOperatorsPerQuorum is a list of the number of operators (including the registering operator) in each of the quorums the operator is registered for
     * @dev access restricted to the RegistryCoordinator
     * @dev Preconditions (these are assumed, not validated in this contract):
     *         1) `quorumNumbers` has no duplicates
     *         2) `quorumNumbers.length` != 0
     *         3) `quorumNumbers` is ordered in ascending order
     *         4) the operator is not already registered
     */
    function registerOperator(
        bytes32 operatorId, 
        bytes calldata quorumNumbers
    ) public virtual onlyRegistryCoordinator returns(uint32[] memory) {
        uint32[] memory numOperatorsPerQuorum = new uint32[](quorumNumbers.length);

        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            // Validate quorum exists and get current operator count
            uint8 quorumNumber = uint8(quorumNumbers[i]);
            uint256 historyLength = _operatorCountHistory[quorumNumber].length;
            require(historyLength != 0, "IndexRegistry.registerOperator: quorum does not exist");

            /**
             * Increase the number of operators currently active for this quorum,
             * and assign the operator to the last index available
             */
            uint32 newOperatorCount = _increaseOperatorCount(quorumNumber);
            _assignOperatorToIndex({
                operatorId: operatorId,
                quorumNumber: quorumNumber,
                index: newOperatorCount - 1
            });

            // Record the current operator count for each quorum
            numOperatorsPerQuorum[i] = newOperatorCount;
        }

        return numOperatorsPerQuorum;
    }

    /**
     * @notice Deregisters the operator with the specified `operatorId` for the quorums specified by `quorumNumbers`.
     * @param operatorId is the id of the operator that is being deregistered
     * @param quorumNumbers is the quorum numbers the operator is deregistered for
     * @dev access restricted to the RegistryCoordinator
     * @dev Preconditions (these are assumed, not validated in this contract):
     *         1) `quorumNumbers` has no duplicates
     *         2) `quorumNumbers.length` != 0
     *         3) `quorumNumbers` is ordered in ascending order
     *         4) the operator is not already deregistered
     *         5) `quorumNumbers` is a subset of the quorumNumbers that the operator is registered for
     */
    function deregisterOperator(
        bytes32 operatorId, 
        bytes calldata quorumNumbers
    ) public virtual onlyRegistryCoordinator {
        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            // Validate quorum exists and get the index of the operator being deregistered
            uint8 quorumNumber = uint8(quorumNumbers[i]);
            uint256 historyLength = _operatorCountHistory[quorumNumber].length;
            require(historyLength != 0, "IndexRegistry.registerOperator: quorum does not exist");
            uint32 indexOfOperatorToRemove = currentOperatorIndex[quorumNumber][operatorId];

            /**
             * "Pop" the operator from the registry:
             * 1. Decrease the operator count for the quorum
             * 2. Remove the last operator associated with the count
             * 3. Place the last operator in the deregistered operator's old position
             */
            uint32 newOperatorCount = _decreaseOperatorCount(quorumNumber);
            bytes32 lastOperatorId = _popLastOperator(quorumNumber, newOperatorCount);
            if (operatorId != lastOperatorId) {
                _assignOperatorToIndex({
                    operatorId: lastOperatorId,
                    quorumNumber: quorumNumber,
                    index: indexOfOperatorToRemove
                });
            }
        }
    }

    /**
     * @notice Initialize a quorum by pushing its first quorum update
     * @param quorumNumber The number of the new quorum
     */
    function initializeQuorum(uint8 quorumNumber) public virtual onlyRegistryCoordinator {
        require(_operatorCountHistory[quorumNumber].length == 0, "IndexRegistry.createQuorum: quorum already exists");

        _operatorCountHistory[quorumNumber].push(QuorumUpdate({
            numOperators: 0,
            fromBlockNumber: uint32(block.number)
        }));
    }

    /*******************************************************************************
                                INTERNAL FUNCTIONS
    *******************************************************************************/

    /**
     * @notice Increases the historical operator count by 1 and returns the new count
     */
    function _increaseOperatorCount(uint8 quorumNumber) internal returns (uint32) {
        QuorumUpdate storage lastUpdate = _latestQuorumUpdate(quorumNumber);
        uint32 newOperatorCount = lastUpdate.numOperators + 1;
        
        _updateOperatorCountHistory(quorumNumber, lastUpdate, newOperatorCount);

        // If this is the first time we're using this index, push its first update
        // This maintains an invariant: existing indices have nonzero history
        if (_indexHistory[quorumNumber][newOperatorCount - 1].length == 0) {
            _indexHistory[quorumNumber][newOperatorCount - 1].push(OperatorUpdate({
                operatorId: OPERATOR_DOES_NOT_EXIST_ID,
                fromBlockNumber: uint32(block.number)
            }));
        }

        return newOperatorCount;
    }

    /**
     * @notice Decreases the historical operator count by 1 and returns the new count
     */
    function _decreaseOperatorCount(uint8 quorumNumber) internal returns (uint32) {
        QuorumUpdate storage lastUpdate = _latestQuorumUpdate(quorumNumber);
        uint32 newOperatorCount = lastUpdate.numOperators - 1;
        
        _updateOperatorCountHistory(quorumNumber, lastUpdate, newOperatorCount);
        
        return newOperatorCount;
    }

    /**
     * @notice Update `_operatorCountHistory` with a new operator count
     * @dev If the lastUpdate was made in the this block, update the entry.
     * Otherwise, push a new historical entry.
     */
    function _updateOperatorCountHistory(
        uint8 quorumNumber,
        QuorumUpdate storage lastUpdate,
        uint32 newOperatorCount
    ) internal {
        if (lastUpdate.fromBlockNumber == uint32(block.number)) {
            lastUpdate.numOperators = newOperatorCount;
        } else {
            _operatorCountHistory[quorumNumber].push(QuorumUpdate({
                numOperators: newOperatorCount,
                fromBlockNumber: uint32(block.number)
            }));
        }
    }

    /**
     * @notice For a given quorum and index, pop and return the last operatorId in the history
     * @dev The last entry's operatorId is updated to OPERATOR_DOES_NOT_EXIST_ID
     * @return The removed operatorId
     */
    function _popLastOperator(uint8 quorumNumber, uint32 index) internal returns (bytes32) {
        OperatorUpdate storage lastUpdate = _latestIndexUpdate(quorumNumber, index);
        bytes32 removedOperatorId = lastUpdate.operatorId;

        // Set the current operator id for this quorum/index to 0
        _updateIndexHistory(quorumNumber, index, lastUpdate, OPERATOR_DOES_NOT_EXIST_ID);

        return removedOperatorId;
    }

    /**
     * @notice Assign an operator to an index and update the index history
     * @param operatorId operatorId of the operator to update
     * @param quorumNumber quorumNumber of the operator to update
     * @param index the latest index of that operator in the list of operators registered for this quorum
     */ 
    function _assignOperatorToIndex(bytes32 operatorId, uint8 quorumNumber, uint32 index) internal {
        OperatorUpdate storage lastUpdate = _latestIndexUpdate(quorumNumber, index);

        _updateIndexHistory(quorumNumber, index, lastUpdate, operatorId);

        // Assign the operator to their new current index
        currentOperatorIndex[quorumNumber][operatorId] = index;
        emit QuorumIndexUpdate(operatorId, quorumNumber, index);
    }

    /**
     * @notice Update `_indexHistory` with a new operator id for the current block
     * @dev If the lastUpdate was made in the this block, update the entry.
     * Otherwise, push a new historical entry.
     */
    function _updateIndexHistory(
        uint8 quorumNumber,
        uint32 index,
        OperatorUpdate storage lastUpdate,
        bytes32 newOperatorId
    ) internal {
        if (lastUpdate.fromBlockNumber == uint32(block.number)) {
            lastUpdate.operatorId = newOperatorId;
        } else {
            _indexHistory[quorumNumber][index].push(OperatorUpdate({
                operatorId: newOperatorId,
                fromBlockNumber: uint32(block.number)
            }));
        }
    }

    /// @notice Returns the most recent operator count update for a quorum
    /// @dev Reverts if the quorum does not exist (history length == 0)
    function _latestQuorumUpdate(uint8 quorumNumber) internal view returns (QuorumUpdate storage) {
        uint256 historyLength = _operatorCountHistory[quorumNumber].length;
        return _operatorCountHistory[quorumNumber][historyLength - 1];
    }

    /// @notice Returns the most recent operator id update for an index
    /// @dev Reverts if the index has never been used (history length == 0)
    function _latestIndexUpdate(uint8 quorumNumber, uint32 index) internal view returns (OperatorUpdate storage) {
        uint256 historyLength = _indexHistory[quorumNumber][index].length;
        return _indexHistory[quorumNumber][index][historyLength - 1];
    }

    /**
     * @notice Returns the total number of operators of the service for the given `quorumNumber` at the given `blockNumber`
     * @dev Reverts if the quorum does not exist, or if the blockNumber is from before the quorum existed
     */
    function _operatorCountAtBlockNumber(
        uint8 quorumNumber, 
        uint32 blockNumber
    ) internal view returns (uint32){
        uint256 historyLength = _operatorCountHistory[quorumNumber].length;
        require(historyLength != 0, "IndexRegistry._operatorCountAtBlockNumber: quorum does not exist");

        // Loop backwards through the total operator history
        for (uint256 i = 0; i < historyLength; i++) {
            uint256 listIndex = (historyLength - 1) - i;
            QuorumUpdate memory quorumUpdate = _operatorCountHistory[quorumNumber][listIndex];
            // Look for the first update that began before or at `blockNumber`
            if (quorumUpdate.fromBlockNumber <= blockNumber) {
                return quorumUpdate.numOperators;
            }
        }
        
        revert("IndexRegistry._operatorCountAtBlockNumber: quorum did not exist at given block number");
    }
    
    /**
     * @return operatorId at the given `index` at the given `blockNumber` for the given `quorumNumber`
     * Precondition: requires that the index was used active at the given block number for quorum
     */
    function _operatorIdForIndexAtBlockNumber(
        uint8 quorumNumber, 
        uint32 index, 
        uint32 blockNumber
    ) internal view returns(bytes32) {
        uint256 historyLength = _indexHistory[quorumNumber][index].length;
        // Loop backward through index history
        for (uint256 i = 0; i < historyLength; i++) {
            uint256 listIndex = (historyLength - 1) - i;
            OperatorUpdate memory operatorIndexUpdate = _indexHistory[quorumNumber][index][listIndex];
            // Look for the first update that began before or at `blockNumber`
            if (operatorIndexUpdate.fromBlockNumber <= blockNumber) {
                // Special case: this will be OPERATOR_DOES_NOT_EXIST_ID if this index was not used at the block number
                return operatorIndexUpdate.operatorId;
            }
        }

        // we should only it this if the index was never used before blockNumber
        return OPERATOR_DOES_NOT_EXIST_ID;
    }

    /*******************************************************************************
                                 VIEW FUNCTIONS
    *******************************************************************************/

    /// @notice Returns the _indexHistory entry for the specified `operatorIndex` and `quorumNumber` at the specified `index`
    function getOperatorUpdateAtIndex(uint8 quorumNumber, uint32 operatorIndex, uint32 index) external view returns (OperatorUpdate memory) {
        return _indexHistory[quorumNumber][operatorIndex][index];
    }

    /// @notice Returns the _operatorCountHistory entry for the specified `quorumNumber` at the specified `index`
    function getQuorumUpdateAtIndex(uint8 quorumNumber, uint32 index) external view returns (QuorumUpdate memory) {
        return _operatorCountHistory[quorumNumber][index];
    }

    /// @notice Returns the most recent _operatorCountHistory entry for the specified quorumNumber
    /// @dev Reverts if the quorum does not exist
    function getLatestQuorumUpdate(uint8 quorumNumber) external view returns (QuorumUpdate memory) {
        return _latestQuorumUpdate(quorumNumber);
    }

    /// @notice Returns the most recent _operatorCountHistory entry for the specified quorumNumber
    /// @dev Reverts if there is no update for the given index
    function getLatestOperatorUpdate(uint8 quorumNumber, uint32 index) external view returns (OperatorUpdate memory) {
        return _latestIndexUpdate(quorumNumber, index);
    }

    /// @notice Returns an ordered list of operators of the services for the given `quorumNumber` at the given `blockNumber`
    function getOperatorListAtBlockNumber(
        uint8 quorumNumber, 
        uint32 blockNumber
    ) external view returns (bytes32[] memory){
        uint32 operatorCount = _operatorCountAtBlockNumber(quorumNumber, blockNumber);
        bytes32[] memory operatorList = new bytes32[](operatorCount);
        for (uint256 i = 0; i < operatorCount; i++) {
            operatorList[i] = _operatorIdForIndexAtBlockNumber(quorumNumber, uint32(i), blockNumber);
            require(
                operatorList[i] != OPERATOR_DOES_NOT_EXIST_ID, 
                "IndexRegistry.getOperatorListAtBlockNumber: operator does not exist at the given block number"
            );
        }
        return operatorList;
    }

    /// @notice Returns the total number of operators for a given `quorumNumber`
    /// @dev This will revert if the quorum does not exist
    function totalOperatorsForQuorum(uint8 quorumNumber) external view returns (uint32){
        return _latestQuorumUpdate(quorumNumber).numOperators;
    }
}
