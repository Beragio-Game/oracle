//todo :Add multicall to this to make the execution of proposals easier.
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

import "../../common/implementation/Lockable.sol";
import "../../common/implementation/MultiRole.sol";
import "../interfaces/FinderInterface.sol";
import "../interfaces/IdentifierWhitelistInterface.sol";
import "../interfaces/OracleGovernanceInterface.sol";
import "../interfaces/SafetyModuleInterface.sol";
import "./Constants.sol";
import "./AdminIdentifierLib.sol";

import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title Takes proposals for certain governance actions and allows UMA token holders to vote on them.
 */
contract GovernorV2 is MultiRole, Lockable {
    using Address for address;

    /****************************************
     *     INTERNAL VARIABLES AND STORAGE   *
     ****************************************/

    enum Roles {
        Owner, // Can set the proposer.
        Proposer, // Address that can make proposals.
        EmergencyProposer // Address that can make emergency admin action proposals.
    }

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
    }

    struct Proposal {
        Transaction[] transactions;
        uint256 requestTime;
        bytes ancillaryData;
    }

    FinderInterface private finder;
    Proposal[] public proposals;
    Proposal[] public emergencyProposals;

    /****************************************
     *                EVENTS                *
     ****************************************/

    event NewProposal(uint256 indexed id, Transaction[] transactions, bytes ancillaryData);

    event NewEmergencyProposal(uint256 indexed id, Transaction[] transactions);

    event ProposalExecuted(uint256 indexed id, uint256 transactionIndex);

    /**
     * @notice Construct the Governor contract.
     * @param _finderAddress keeps track of all contracts within the system based on their interfaceName.
     * @param _startingId the initial proposal id that the contract will begin incrementing from.
     */
    constructor(address _finderAddress, uint256 _startingId) {
        finder = FinderInterface(_finderAddress);
        _createExclusiveRole(uint256(Roles.Owner), uint256(Roles.Owner), msg.sender);
        _createExclusiveRole(uint256(Roles.Proposer), uint256(Roles.Owner), msg.sender);
        _createExclusiveRole(uint256(Roles.EmergencyProposer), uint256(Roles.Owner), msg.sender);

        // Ensure the startingId is not set unreasonably high to avoid it being set such that new proposals overwrite
        // other storage slots in the contract.
        uint256 maxStartingId = 10**18;
        require(_startingId <= maxStartingId, "Cannot set startingId larger than 10^18");

        // Sets the initial length of the array to the startingId. Modifying length directly has been disallowed in solidity 0.6.
        assembly {
            sstore(proposals.slot, _startingId)
        }
    }

    /****************************************
     *          PROPOSAL ACTIONS            *
     ****************************************/

    /**
     * @notice Proposes a new governance action. Can only be called by the holder of the Proposer role.
     * @param transactions list of transactions that are being proposed.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     */
    function propose(Transaction[] memory transactions, bytes memory ancillaryData)
        external
        nonReentrant()
        onlyRoleHolder(uint256(Roles.Proposer))
    {
        uint256 time = getCurrentTime();

        // Add a zero-initialized element to the proposals array.
        uint256 id = proposals.length;
        proposals.push();

        // Initialize the new proposal.
        Proposal storage proposal = proposals[id];
        proposal.requestTime = time;
        proposal.ancillaryData = ancillaryData;

        _appendTransactionsToProposal(transactions, proposal);

        bytes32 identifier = AdminIdentifierLib._constructIdentifier(id);

        // Request a vote on this proposal in the DVM.
        _getOracle().requestGovernanceAction(identifier, time, ancillaryData);

        emit NewProposal(id, transactions, ancillaryData);
    }

    /**
     * @notice Executes a proposed governance action that has been approved by voters.
     * @dev This can be called by any address. Caller is expected to send enough ETH to execute payable transactions.
     * @param id unique id for the executed proposal.
     * @param transactionIndex unique transaction index for the executed proposal.
     */
    function executeProposal(uint256 id, uint256 transactionIndex) external payable nonReentrant() {
        Proposal storage proposal = proposals[id];
        require(
            _getOracle().getPrice(
                AdminIdentifierLib._constructIdentifier(id),
                proposal.requestTime,
                proposal.ancillaryData
            ) != 0,
            "Proposal was rejected"
        );

        _executeProposalTransaction(transactionIndex, proposal);

        emit ProposalExecuted(id, transactionIndex);
    }

    /**
     * @notice Returns the current block timestamp.
     * @dev Can be overridden to control contract time.
     */
    function getCurrentTime() public view virtual returns (uint256) {
        return block.timestamp;
    }

    /****************************************
     *       GOVERNOR STATE GETTERS         *
     ****************************************/

    /**
     * @notice Gets the total number of proposals (includes executed and non-executed).
     * @return uint256 representing the current number of proposals.
     */
    function numProposals() external view returns (uint256) {
        return proposals.length;
    }

    function numEmergencyProposals() external view returns (uint256) {
        return emergencyProposals.length;
    }

    /**
     * @notice Gets the proposal data for a particular id.
     * @dev after a proposal is executed, its data will be zeroed out, except for the request time.
     * @param id uniquely identify the identity of the proposal.
     * @return proposal struct containing transactions[] and requestTime.
     */
    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }

    /****************************************
     *       EMERGENCY ADMIN FUNCTIONS      *
     ****************************************/

    function proposeEmergencyAction(Transaction[] memory transactions)
        external
        nonReentrant()
        onlyRoleHolder(uint256(Roles.EmergencyProposer))
        returns (uint256 id)
    {
        uint256 id = emergencyProposals.length;

        // Add a zero-initialized element to the emergencyProposals array.
        emergencyProposals.push();

        // Initialize the new proposal.
        Proposal storage emergencyProposal = emergencyProposals[id];
        emergencyProposal.requestTime = getCurrentTime();

        _appendTransactionsToProposal(transactions, emergencyProposal);

        emit NewEmergencyProposal(id, transactions);
    }

    function executeEmergencyProposal(uint256 id, uint256 transactionIndex) external payable nonReentrant() {
        Proposal storage emergencyProposal = emergencyProposals[id];
        require(_getSafetyModule().isProposalRatified(id), "Proposal not approved");

        _executeProposalTransaction(transactionIndex, emergencyProposal);

        emit ProposalExecuted(id, transactionIndex);
    }

    /****************************************
     *      PRIVATE GETTERS AND FUNCTIONS   *
     ****************************************/

    // Runs a function call on to, with value eth sent and data payload.
    function _executeCall(
        address to,
        uint256 value,
        bytes memory data
    ) private returns (bool) {
        // Mostly copied from:
        // solhint-disable-next-line max-line-length
        // https://github.com/gnosis/safe-contracts/blob/59cfdaebcd8b87a0a32f87b50fead092c10d3a05/contracts/base/Executor.sol#L23-L31
        // solhint-disable-next-line no-inline-assembly

        bool success;
        assembly {
            let inputData := add(data, 0x20)
            let inputDataSize := mload(data)
            success := call(gas(), to, value, inputData, inputDataSize, 0, 0)
        }
        return success;
    }

    // Returns the Voting contract address, named "Oracle" in the finder.
    function _getOracle() private view returns (OracleGovernanceInterface) {
        return OracleGovernanceInterface(finder.getImplementationAddress(OracleInterfaces.Oracle));
    }

    function _getSafetyModule() private view returns (SafetyModuleInterface) {
        return SafetyModuleInterface(getMember(uint256(Roles.EmergencyProposer)));
    }

    function _getIdentifierWhitelist() private view returns (IdentifierWhitelistInterface) {
        return IdentifierWhitelistInterface(finder.getImplementationAddress(OracleInterfaces.IdentifierWhitelist));
    }

    function _appendTransactionsToProposal(Transaction[] memory transactions, Proposal storage proposal) internal {
        // Note: doing all of this array manipulation manually is necessary because directly setting an array of
        // structs in storage to an array of structs in memory is currently not implemented in solidity :/.

        // Initialize the transaction array.
        for (uint256 i = 0; i < transactions.length; i++) {
            require(transactions[i].to != address(0), "The `to` address cannot be 0x0");
            // If the transaction has any data with it the recipient must be a contract, not an EOA.
            if (transactions[i].data.length > 0) {
                require(transactions[i].to.isContract(), "EOA can't accept tx with data");
            }
            proposal.transactions.push(transactions[i]);
        }
    }

    function _executeProposalTransaction(uint256 transactionIndex, Proposal storage proposal) internal {
        Transaction memory transaction = proposal.transactions[transactionIndex];

        require(
            transactionIndex == 0 || proposal.transactions[transactionIndex - 1].to == address(0),
            "Previous tx not yet executed"
        );
        require(transaction.to != address(0), "Tx already executed");
        require(msg.value == transaction.value, "Must send exact amount of ETH");

        // Delete the transaction before execution to avoid any potential re-entrancy issues.
        delete proposal.transactions[transactionIndex];

        require(_executeCall(transaction.to, transaction.value, transaction.data), "Tx execution failed");
    }
}
