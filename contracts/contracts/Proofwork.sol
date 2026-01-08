// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Proofwork is AccessControl, ReentrancyGuard {
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CLIENT_ROLE = keccak256("CLIENT_ROLE");
    bytes32 public constant FREELANCER_ROLE = keccak256("FREELANCER_ROLE");
    
    enum JobStatus { 
        Open, 
        Submitted,
        In_Review, 
        Completed,
        Cancelled
    }
    
    struct Job {
        address client;
        address freelancer;
        JobStatus status;
        string title;
        string description;
        uint256 amount;
        // address _tokenAddress;
        uint256 deadline;
        string proofHash;
    }
    
    uint256 public jobCounter;
    mapping(uint256 => Job) public jobs;
    
    event JobPosted(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobUpdated(uint256 indexed jobId);
    event JobCancelled(uint256 indexed jobId, uint256 refundAmount);
    event WorkSubmitted(uint256 indexed jobId, address indexed freelancer, string proofHash);
    event PaymentReleased(uint256 indexed jobId, uint256 amount);
    event WorkRejected(uint256 indexed jobId);

    error Unauthorized();
    error NoValueDeposited();
    error JobNotOpen();
    error JobNotFound();
    error NoWorkSubmitted();
    error EmptyField();
    error InvalidDeadline();
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    function registerClient() external {
        grantRole(CLIENT_ROLE, msg.sender);
    }
    
    function registerFreelancer() external {
        grantRole(FREELANCER_ROLE, msg.sender);
    }
    
    // Client posts job with deposited crypto
    function postJob(
        string calldata _title,
        string calldata _description,
        uint256 _deadline
        // address tokenAddress
    ) 
        external 
        payable 
        onlyRole(CLIENT_ROLE)
        returns (uint256) 
    {
        if (
            bytes(_title).length == 0 ||
            // _tokenAddress == address(0) ||
            _deadline == 0 
        ) revert EmptyField();
        if(_deadline <= block.timestamp) revert InvalidDeadline();
        if(!(msg.value > 0)) revert NoValueDeposited();
        
        jobCounter++;
        jobs[jobCounter] = Job({
            client: msg.sender,
            freelancer: address(0),
            status: JobStatus.Open,
            title: _title,
            description: _description,
            amount: msg.value,
            // tokenAddress: _tokenAddress,
            deadline: _deadline,
            proofHash: ""
        });
        
        emit JobPosted(jobCounter, msg.sender, msg.value);
        
        return jobCounter;
    }

    // Client updates job description and can add more funds (only for Open jobs)
    function updateJob(
        uint256 _jobId, 
        string calldata _newTitle,
        string calldata _newDescription,
        uint256 _newDeadline
        // address _newTokenAddress,
    ) 
        external 
        payable
        onlyRole(CLIENT_ROLE)
        nonReentrant
    {

        if (
            bytes(_newTitle).length == 0 ||
            // _newTokenAddress == address(0) ||
            _newDeadline == 0 
        ) revert EmptyField();
        if(_newDeadline <= block.timestamp) revert InvalidDeadline();
        if(jobs[_jobId].client != msg.sender) revert Unauthorized();
        if(jobs[_jobId].client == address(0)) revert JobNotFound();
        if(jobs[_jobId].status != JobStatus.Open) revert JobNotOpen();
        
        Job storage job = jobs[_jobId];
        job.title = _newTitle;
        job.description = _newDescription;
        job.deadline = _newDeadline;
        // job.tokenAddress = _newTokenAddress;
        
        uint256 additionalAmount = msg.value;
        if(additionalAmount > 0) {
            job.amount += additionalAmount;
        }
        
        emit JobUpdated(_jobId);
    }
    
    // Client cancels job and receives refund (only for Open jobs)
    function cancelJob(uint256 _jobId) 
        external 
        onlyRole(CLIENT_ROLE)
        nonReentrant
    {
        if(jobs[_jobId].client != msg.sender) revert Unauthorized();
        if(jobs[_jobId].client == address(0)) revert JobNotFound();
        if(jobs[_jobId].status != JobStatus.Open) revert JobNotOpen();
        
        Job storage job = jobs[_jobId];
        
        address clientToRefund = job.client;
        uint256 refundAmount = job.amount;
        
        job.status = JobStatus.Cancelled;
        job.amount = 0;

        emit JobCancelled(_jobId, refundAmount);
        
        if(refundAmount > 0) {
            (bool success, ) = payable(clientToRefund).call{value: refundAmount}("");
            require(success, "Refund failed");
        }
    }

    // Client approves work and releases payment 
    function approveWork(uint256 _jobId) 
        external 
        onlyRole(CLIENT_ROLE)
        nonReentrant
    {
        if(jobs[_jobId].client == address(0)) revert JobNotFound();
        if(!(jobs[_jobId].client == msg.sender)) revert Unauthorized();
        if (!(jobs[_jobId].status == JobStatus.Submitted)) revert NoWorkSubmitted();
        
        Job storage job = jobs[_jobId];
        
        address freelancerToPay = job.freelancer;
        uint256 amountToPay = job.amount;
        
        job.status = JobStatus.Completed;
        job.amount = 0; 
        
        (bool success, ) = payable(freelancerToPay).call{value: amountToPay}("");
        require(success, "Transfer failed");
        
        emit PaymentReleased(_jobId, amountToPay);
    }

    // Client rejects work and reopens job
    function rejectWork(uint256 _jobId) 
        external 
        onlyRole(CLIENT_ROLE) 
    {
        if(!(jobs[_jobId].client == msg.sender)) revert Unauthorized();
        if (!(jobs[_jobId].status == JobStatus.Submitted)) revert NoWorkSubmitted();
        
        jobs[_jobId].freelancer = address(0);
        jobs[_jobId].proofHash = "";
        jobs[_jobId].status = JobStatus.Open;
        
        emit WorkRejected(_jobId);
    }
    
    // Freelancer submits work
    function submitWork(
        uint256 _jobId, 
        string calldata _proofHash
    ) 
        external 
        onlyRole(FREELANCER_ROLE) 
    {
        if(!(jobs[_jobId].status == JobStatus.Open)) revert JobNotOpen();
        if(block.timestamp > jobs[_jobId].deadline) revert InvalidDeadline();
        if(bytes(_proofHash).length == 0) revert EmptyField();
        
        jobs[_jobId].freelancer = msg.sender;
        jobs[_jobId].proofHash = _proofHash;
        jobs[_jobId].status = JobStatus.Submitted;
        
        emit WorkSubmitted(_jobId, msg.sender, _proofHash);
    }
}