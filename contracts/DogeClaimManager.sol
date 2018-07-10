pragma solidity ^0.4.19;

import {DogeDepositsManager} from './DogeDepositsManager.sol';
import {DogeSuperblocks} from './DogeSuperblocks.sol';
import {DogeBattleManager} from './DogeBattleManager.sol';
import {DogeTx} from './DogeParser/DogeTx.sol';
import {DogeErrorCodes} from "./DogeErrorCodes.sol";
import {IScryptChecker} from "./IScryptChecker.sol";
import {IScryptCheckerListener} from "./IScryptCheckerListener.sol";

// @dev - Manager of superblock claims
//
// Manages superblocks proposal and challenges
contract DogeClaimManager is DogeDepositsManager, DogeBattleManager, IScryptCheckerListener {

    struct SuperblockClaim {
        bytes32 superblockId;                       // Superblock Id
        address claimant;                           // Superblock submitter
        uint createdAt;                             // Superblock creation

        address[] challengers;                      // List of challengers
        mapping (address => uint) bondedDeposits;   // Deposit associated to challengers

        uint currentChallenger;                     // Index of challenger in current session
        mapping (address => bytes32) sessions;      // Challenge sessions

        uint challengeTimeout;                      // Claim timeout

        bool verificationOngoing;                   // Challenge session has started

        bool decided;                               // If the claim was decided
        bool invalid;                               // If superblock is invalid
    }

    uint public minDeposit = 1;

    // Active Superblock claims
    mapping (bytes32 => SuperblockClaim) public claims;

    // Superblocks contract
    DogeSuperblocks public superblocks;

    // ScryptHash checker
    IScryptChecker public scryptChecker;

    event DepositBonded(bytes32 claimId, address account, uint amount);
    event DepositUnbonded(bytes32 claimId, address account, uint amount);
    event SuperblockClaimCreated(bytes32 claimId, address claimant, bytes32 superblockId);
    event SuperblockClaimChallenged(bytes32 claimId, address challenger);
    event SuperblockBattleDecided(bytes32 sessionId, address winner, address loser);
    event SuperblockClaimSuccessful(bytes32 claimId, address claimant, bytes32 superblockId);
    event SuperblockClaimFailed(bytes32 claimId, address claimant, bytes32 superblockId);
    event VerificationGameStarted(bytes32 claimId, address claimant, address challenger, bytes32 sessionId);

    event ErrorClaim(bytes32 claimId, uint err);

    // @dev – Configures the contract storing the superblocks
    // @param _superblocks Contract that manages superblocks
    // @param _superblockDuration Superblock duration (in seconds)
    // @param _superblockDelay Delay to accept a superblock submition (in seconds)
    // @param _superblockTimeout Time to wait for challenges (in seconds)
    constructor(DogeSuperblocks _superblocks, uint _superblockDuration, uint _superblockDelay, uint _superblockTimeout)
        DogeBattleManager(_superblockDuration, _superblockDelay, _superblockTimeout) public {
        superblocks = _superblocks;
    }

    // @dev - sets ScryptChecker instance associated with this DogeClaimManager contract.
    // Once scryptChecker has been set, it cannot be changed.
    // An address of 0x0 means scryptChecker hasn't been set yet.
    //
    // @param _scryptChecker - address of the ScryptChecker contract to be associated with DogeRelay
    function setScryptChecker(address _scryptChecker) public {
        require(address(scryptChecker) == 0x0 && _scryptChecker != 0x0);
        scryptChecker = IScryptChecker(_scryptChecker);
    }

    // @dev – locks up part of the a user's deposit into a claim.
    // @param claimId – the claim id.
    // @param account – the user's address.
    // @param amount – the amount of deposit to lock up.
    // @return – the user's deposit bonded for the claim.
    function bondDeposit(bytes32 claimId, address account, uint amount) private returns (uint) {
        SuperblockClaim storage claim = claims[claimId];

        require(claimExists(claim));
        require(deposits[account] >= amount);
        deposits[account] -= amount;

        claim.bondedDeposits[account] += amount;
        emit DepositBonded(claimId, account, amount);
        return claim.bondedDeposits[account];
    }

    // @dev – accessor for a claims bonded deposits.
    // @param claimId – the claim id.
    // @param account – the user's address.
    // @return – the user's deposit bonded for the claim.
    function getBondedDeposit(bytes32 claimId, address account) public view returns (uint) {
        SuperblockClaim storage claim = claims[claimId];
        require(claimExists(claim));
        return claim.bondedDeposits[account];
    }

    // @dev – unlocks a user's bonded deposits from a claim.
    // @param claimId – the claim id.
    // @param account – the user's address.
    // @return – the user's deposit which was unbonded from the claim.
    function unbondDeposit(bytes32 claimId, address account) public returns (uint) {
        SuperblockClaim storage claim = claims[claimId];
        require(claimExists(claim));
        require(claim.decided == true);

        uint bondedDeposit = claim.bondedDeposits[account];

        delete claim.bondedDeposits[account];
        deposits[account] += bondedDeposit;

        emit DepositUnbonded(claimId, account, bondedDeposit);

        return bondedDeposit;
    }

    // @dev – Propose a new superblock.
    //
    // @param _blocksMerkleRoot Root of the merkle tree of blocks contained in a superblock
    // @param _accumulatedWork Accumulated proof of work of the last block in the superblock
    // @param _timestamp Timestamp of the last block in the superblock
    // @param _lastHash Hash of the last block in the superblock
    // @param _parentId Id of the parent superblock
    // @return Error code and superblockId
    function proposeSuperblock(bytes32 _blocksMerkleRoot, uint _accumulatedWork, uint _timestamp, bytes32 _lastHash, bytes32 _parentHash) public returns (uint, bytes32) {
        require(address(superblocks) != 0);

        if (deposits[msg.sender] < minDeposit) {
            emit ErrorClaim(0, ERR_SUPERBLOCK_MIN_DEPOSIT);
            return (ERR_SUPERBLOCK_MIN_DEPOSIT, 0);
        }

        if (_timestamp + superblockDelay > block.timestamp) {
            emit ErrorClaim(0, ERR_SUPERBLOCK_BAD_TIMESTAMP);
            return (ERR_SUPERBLOCK_BAD_TIMESTAMP, 0);
        }

        uint err;
        bytes32 superblockId;
        (err, superblockId) = superblocks.propose(_blocksMerkleRoot, _accumulatedWork, _timestamp, _lastHash, _parentHash, msg.sender);
        if (err != 0) {
            emit ErrorClaim(superblockId, err);
            return (err, superblockId);
        }

        bytes32 claimId = superblockId;
        SuperblockClaim storage claim = claims[claimId];
        if (claimExists(claim)) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_BAD_CLAIM);
            return (ERR_SUPERBLOCK_BAD_CLAIM, claimId);
        }

        claim.claimant = msg.sender;
        claim.currentChallenger = 0;
        claim.decided = false;
        claim.invalid = false;
        claim.verificationOngoing = false;
        claim.createdAt = block.number;
        claim.challengeTimeout = block.timestamp + superblockTimeout;
        claim.superblockId = superblockId;

        bondDeposit(claimId, msg.sender, minDeposit);

        emit SuperblockClaimCreated(claimId, msg.sender, superblockId);

        return (ERR_SUPERBLOCK_OK, superblockId);
    }

    // @dev – challenge a superblock claim.
    // @param superblockId – Id of the superblock to challenge.
    // @return Error code an claim Id
    function challengeSuperblock(bytes32 superblockId) public returns (uint, bytes32) {
        require(address(superblocks) != 0);

        bytes32 claimId = superblockId;
        SuperblockClaim storage claim = claims[claimId];

        if (!claimExists(claim)) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_BAD_CLAIM);
            return (ERR_SUPERBLOCK_BAD_CLAIM, claimId);
        }
        if (claim.decided) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_CLAIM_DECIDED);
            return (ERR_SUPERBLOCK_CLAIM_DECIDED, claimId);
        }
        if (deposits[msg.sender] < minDeposit) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_MIN_DEPOSIT);
            return (ERR_SUPERBLOCK_MIN_DEPOSIT, claimId);
        }

        uint err;
        (err, ) = superblocks.challenge(superblockId, msg.sender);
        if (err != 0) {
            emit ErrorClaim(claimId, err);
            return (err, 0);
        }

        bondDeposit(claimId, msg.sender, minDeposit);

        claim.challengeTimeout += superblockTimeout;
        claim.challengers.push(msg.sender);
        emit SuperblockClaimChallenged(claimId, msg.sender);

        return (ERR_SUPERBLOCK_OK, claimId);
    }

    // @dev – runs the battle session to verify a superblock for the next challenger
    // @param claimId – the claim id.
    function runNextBattleSession(bytes32 claimId) public returns (bool) {
        SuperblockClaim storage claim = claims[claimId];

        if (!claimExists(claim)) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_BAD_CLAIM);
            return false;
        }

        if (claim.decided) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_CLAIM_DECIDED);
            return false;
        }

        if (claim.verificationOngoing) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_VERIFICATION_PENDING);
            return false;
        }

        if (claim.currentChallenger < claim.challengers.length) {

            bytes32 sessionId = beginBattleSession(claimId, claim.claimant, claim.challengers[claim.currentChallenger]);

            claim.sessions[claim.challengers[claim.currentChallenger]] = sessionId;
            emit VerificationGameStarted(claimId, claim.claimant, claim.challengers[claim.currentChallenger], sessionId);

            claim.verificationOngoing = true;
            claim.currentChallenger += 1;
        }

        return true;
    }

    // @dev – check whether a claim has successfully withstood all challenges.
    // if successful, it will trigger a callback to the DogeRelay contract,
    // notifying it that the Scrypt blockhash was correctly calculated.
    //
    // @param claimId – the claim ID.
    function checkClaimFinished(bytes32 claimId) public returns (bool) {
        SuperblockClaim storage claim = claims[claimId];

        if (!claimExists(claim)) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_BAD_CLAIM);
            return false;
        }

        // check that there is no ongoing verification game.
        if (claim.verificationOngoing) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_VERIFICATION_PENDING);
            return false;
        }

        //check that the claim has exceeded the claim's specific challenge timeout.
        if (block.timestamp <= claim.challengeTimeout) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_NO_TIMEOUT);
            return false;
        }

        // check that all verification games have been played.
        if (claim.currentChallenger < claim.challengers.length) {
            emit ErrorClaim(claimId, ERR_SUPERBLOCK_VERIFICATION_PENDING);
            return false;
        }

        claim.decided = true;

        // If the claim is invalid superblock data didn't match provided input
        if (claim.invalid) {
            superblocks.invalidate(claim.superblockId, msg.sender);
            emit SuperblockClaimFailed(claimId, claim.claimant, claim.superblockId);
        } else {
            // If no challengers confirm immediately
            if (claim.challengers.length == 0) {
                superblocks.confirm(claim.superblockId, msg.sender);
            } else {
                superblocks.semiApprove(claim.superblockId, msg.sender);
            }
            unbondDeposit(claimId, claim.claimant);
            emit SuperblockClaimSuccessful(claimId, claim.claimant, claim.superblockId);
        }

        return true;
    }

    // @dev – called when a battle session has ended.
    //
    // @param sessionId – the sessionId.
    // @param claimId - Id of the superblock claim
    // @param winner – winner of the verification game.
    // @param loser – loser of the verification game.
    function sessionDecided(bytes32 sessionId, bytes32 claimId, address winner, address loser) internal {
        SuperblockClaim storage claim = claims[claimId];

        require(claimExists(claim));

        claim.verificationOngoing = false;

        //TODO Fix reward splitting
        // reward the winner, with the loser's bonded deposit.
        //uint depositToTransfer = claim.bondedDeposits[loser];
        //claim.bondedDeposits[winner] += depositToTransfer;
        //delete claim.bondedDeposits[loser];

        if (claim.claimant == loser) {
            // the claim is over.
            // note: no callback needed to the DogeRelay contract,
            // because it by default does not save blocks.

            //Trigger end of verification game
            claim.invalid = true;

            // It should not fail when called from sessionDecided
            // the data should be verified and a out of gas will cause
            // the whole transaction to revert
            runNextBattleSession(claimId);
        } else if (claim.claimant == winner) {
            // the claim continues.
            // It should not fail when called from sessionDecided
            runNextBattleSession(claimId);
        } else {
            revert();
        }

        emit SuperblockBattleDecided(sessionId, winner, loser);
    }

    // @dev – Check if a claim exists
    function claimExists(SuperblockClaim claim) pure private returns(bool) {
        return (claim.claimant != 0x0);
    }

    // @dev – Return session by challenger
    function getSession(bytes32 claimId, address challenger) public view returns(bytes32) {
        return claims[claimId].sessions[challenger];
    }

    function doVerifyScryptHash(bytes32 sessionId, bytes32 blockSha256Hash, bytes32 blockScryptHash, bytes blockHeader, bool isMergeMined, address submitter) internal returns (bytes32) {
        numScryptHashVerifications += 1;
        bytes32 challengeId = keccak256(abi.encodePacked(blockScryptHash, submitter, numScryptHashVerifications));
        if (isMergeMined) {
            // Merge mined block
            scryptChecker.checkScrypt(DogeTx.sliceArray(blockHeader, blockHeader.length - 80, blockHeader.length), blockScryptHash, challengeId, submitter, IScryptCheckerListener(this));
        } else {
            // Non merge mined block
            scryptChecker.checkScrypt(DogeTx.sliceArray(blockHeader, 0, 80), blockScryptHash, challengeId, submitter, IScryptCheckerListener(this));
        }
        scryptHashVerifications[challengeId] = ScryptHashVerification({
            sessionId: sessionId,
            blockSha256Hash: blockSha256Hash
        }); sessionId;

        return challengeId;
    }

    // @dev Scrypt verification succeeded
    function scryptVerified(bytes32 scryptChallengeId) external onlyFrom(scryptChecker) returns (uint) {
        ScryptHashVerification storage verification = scryptHashVerifications[scryptChallengeId];
        require(verification.sessionId != 0x0);
        notifyScryptHashSucceeded(verification.sessionId, verification.blockSha256Hash);
        delete scryptHashVerifications[scryptChallengeId];
        return 0;
    }

    // @dev Scrypt verification failed
    function scryptFailed(bytes32 scryptChallengeId) external onlyFrom(scryptChecker) returns (uint) {
        ScryptHashVerification storage verification = scryptHashVerifications[scryptChallengeId];
        require(verification.sessionId != 0x0);
        notifyScryptHashFailed(verification.sessionId, verification.blockSha256Hash);
        delete scryptHashVerifications[scryptChallengeId];
        return 0;
    }

    function getSuperblockInfo(bytes32 superblockId) internal view returns (
        bytes32 _blocksMerkleRoot,
        uint _accumulatedWork,
        uint _timestamp,
        bytes32 _lastHash,
        bytes32 _parentId,
        address _submitter,
        DogeSuperblocks.Status _status
    ) {
        return superblocks.getSuperblock(superblockId);
    }
}
