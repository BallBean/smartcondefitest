// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RPSLS_Improved {
    // ----- CONFIG & STATE -----
    IERC20 public token;               // Token ที่จะใช้แทน AVAX (เช่น WAVAX หรือโทเคนทดสอบ)
    uint256 public constant STAKE = 1e12; // 0.000001 * 1e18 (สมมติ token มี 18 decimals)
    
    address public player1;
    address public player2;

    bytes32 public p1Commit;           // Commit ของ player1
    bytes32 public p2Commit;           // Commit ของ player2

    bool public p1Revealed;
    bool public p2Revealed;

    uint256 public p1Choice;           // move ที่เปิดเผยแล้ว (0=Rock,1=Paper,2=Scissors,3=Lizard,4=Spock)
    uint256 public p2Choice;

    bool public gameActive;
    uint256 public commitDeadline;     // เวลา deadline ให้ทั้งสอง commit
    uint256 public revealDeadline;     // เวลา deadline ให้ทั้งสอง reveal

    // ----- EVENTS -----
    event GameStarted(address indexed p1, address indexed p2);
    event PlayerCommitted(address indexed player);
    event PlayerRevealed(address indexed player, uint256 choice);
    event GameResult(address indexed winner, uint256 reward);
    event GameReset();

    // ----- CONSTRUCTOR -----
    constructor(address _token) {
        token = IERC20(_token);
        gameActive = false;
    }

    // ----- MODIFIERS -----
    modifier onlyPlayers() {
        require(
            msg.sender == player1 || msg.sender == player2,
            "Only players can call this"
        );
        _;
    }

    // ----- CORE FUNCTIONS -----

    // 1) เริ่มเกม / commit
    function addPlayer(bytes32 _commitment) external {
        require(!gameActive, "Game is already active");
        
        // ถ้ายังไม่มี player1
        if (player1 == address(0)) {
            player1 = msg.sender;
            p1Commit = _commitment;
            emit PlayerCommitted(msg.sender);
        } 
        // มี player1 แล้ว -> เป็น player2
        else {
            require(player2 == address(0), "Game is full");
            player2 = msg.sender;
            p2Commit = _commitment;
            emit PlayerCommitted(msg.sender);

            // ตอนนี้ผู้เล่นครบ 2 คน -> ตรวจสอบ allowance ทั้งสอง
            require(
                token.allowance(player1, address(this)) >= STAKE,
                "Player1 did not approve enough token"
            );
            require(
                token.allowance(player2, address(this)) >= STAKE,
                "Player2 did not approve enough token"
            );

            // ดึง token จาก player1 และ player2
            token.transferFrom(player1, address(this), STAKE);
            token.transferFrom(player2, address(this), STAKE);

            // ตั้งสถานะเกม
            gameActive = true;
            // กำหนดเวลา (ตัวอย่าง 5 นาทีให้ commit, 10 นาทีให้ reveal - ปรับได้ตามต้องการ)
            commitDeadline = block.timestamp + 5 minutes; 
            revealDeadline = commitDeadline + 5 minutes;

            emit GameStarted(player1, player2);
        }
    }

    // 2) Reveal move (ภายในเวลา)
    function revealMove(string calldata _salt, uint256 _choice) external onlyPlayers {
        require(gameActive, "No active game");
        require(block.timestamp <= revealDeadline, "Reveal period has ended");
        require(_choice <= 4, "Invalid choice");

        bytes32 checkHash = keccak256(abi.encodePacked(_salt, _choice));

        // ใครเรียก ก็ตรวจ commit ของคนนั้น
        if (msg.sender == player1) {
            require(!p1Revealed, "Player1 already revealed");
            require(checkHash == p1Commit, "Hash mismatch for player1");
            p1Revealed = true;
            p1Choice = _choice;
        } else {
            require(!p2Revealed, "Player2 already revealed");
            require(checkHash == p2Commit, "Hash mismatch for player2");
            p2Revealed = true;
            p2Choice = _choice;
        }

        emit PlayerRevealed(msg.sender, _choice);

        // ถ้าทั้งสองเผยแล้ว -> เช็คผู้ชนะทันที
        if (p1Revealed && p2Revealed) {
            _checkWinnerAndPayout();
        }
    }

    // 3) ฟังก์ชันตัดสินผู้ชนะ RPSLS
    //    0=Rock,1=Paper,2=Scissors,3=Lizard,4=Spock
    function _getResult(uint256 moveA, uint256 moveB) private pure returns (uint256) {
        if (moveA == moveB) return 0; // เสมอ
        if (
            (moveA == 0 && (moveB == 2 || moveB == 3)) || // Rock crushes Scissors/Lizard
            (moveA == 1 && (moveB == 0 || moveB == 4)) || // Paper covers Rock, disproves Spock
            (moveA == 2 && (moveB == 1 || moveB == 3)) || // Scissors cuts Paper, decapitates Lizard
            (moveA == 3 && (moveB == 4 || moveB == 1)) || // Lizard poisons Spock, eats Paper
            (moveA == 4 && (moveB == 0 || moveB == 2))    // Spock smashes Rock, vaporizes Scissors
        ) {
            return 1; // A ชนะ
        }
        return 2; // B ชนะ
    }

    // 4) ตัดสินผู้ชนะและโอนเงิน
    function _checkWinnerAndPayout() private {
        require(p1Revealed && p2Revealed, "Not all revealed");
        
        uint256 result = _getResult(p1Choice, p2Choice);
        uint256 totalStake = STAKE * 2; // เงินทั้งหมดในเกม

        if (result == 1) {
            // player1 ชนะ
            token.transfer(player1, totalStake);
            emit GameResult(player1, totalStake);
        } else if (result == 2) {
            // player2 ชนะ
            token.transfer(player2, totalStake);
            emit GameResult(player2, totalStake);
        } else {
            // เสมอ
            token.transfer(player1, STAKE);
            token.transfer(player2, STAKE);
            emit GameResult(address(0), 0); // หรือจะแจ้งว่าผลเสมอก็ได้
        }

        _resetGame();
    }

    // 5) กรณีหมดเวลา reveal / forceWithdraw
    function forceWithdrawIfTimeout() external {
        require(gameActive, "No active game");
        require(block.timestamp > revealDeadline, "Reveal not timed out yet");

        // เงื่อนไข: 
        // - ถ้า player1 ไม่ reveal แต่ player2 reveal -> player2 เอาเงินทั้งหมด
        // - ถ้า player2 ไม่ reveal แต่ player1 reveal -> player1 เอาเงินทั้งหมด
        // - ถ้าทั้งสองไม่ reveal -> ใครเรียกก็เอาเงินทั้งหมดไป
        uint256 totalStake = STAKE * 2;

        if (p1Revealed && !p2Revealed) {
            // player1 ได้ทั้งหมด
            token.transfer(player1, totalStake);
            emit GameResult(player1, totalStake);
        } else if (!p1Revealed && p2Revealed) {
            // player2 ได้ทั้งหมด
            token.transfer(player2, totalStake);
            emit GameResult(player2, totalStake);
        } else {
            // ไม่มีใคร reveal
            // ให้คนใดกดก็ได้ -> โอนเงินทั้งหมดให้คนกด
            token.transfer(msg.sender, totalStake);
            emit GameResult(msg.sender, totalStake);
        }

        _resetGame();
    }

    // ----- INTERNAL -----
    function _resetGame() internal {
        player1 = address(0);
        player2 = address(0);

        p1Commit = bytes32(0);
        p2Commit = bytes32(0);

        p1Choice = 0;
        p2Choice = 0;

        p1Revealed = false;
        p2Revealed = false;

        gameActive = false;
        commitDeadline = 0;
        revealDeadline = 0;

        emit GameReset();
    }
}