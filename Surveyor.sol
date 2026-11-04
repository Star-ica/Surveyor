// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @title Surveyor - survey campaigns with equal, claim-based respondent rewards.
/// @notice ALL data stored here is PUBLIC. Never put passwords, ID documents or private
///         personal data in `questions` or response `data`. Store an encrypted blob or a
///         hash commitment ("h:" + keccak256) instead.
/// @dev token address(0) = native BOT. Remainder rule: pool after fee = per * valid + rem;
///      the first `rem` approved respondents (by approval order, idx < rem) get +1 unit.
contract Surveyor {
    enum Status { None, Submitted, Approved, Rejected, Appealed }
    enum SState { Open, Closed, Finalized }

    struct Survey {
        address creator; string title; string questions; uint64 deadline; uint32 maxResponses;
        address token; uint256 pool; bool refundIfNone; SState state; uint32 valid; uint256 per; uint256 rem;
    }
    struct Resp { string data; uint64 at; Status status; string reason; uint32 idx; bool claimed; }

    address public admin;
    address public usdt;
    uint16 public feeBps = 250; // 2.5%, max 10%
    uint256 public count;
    mapping(address => uint256) public minWithdraw; // per token; address(0) = BOT
    mapping(uint256 => Survey) public surveys;
    mapping(uint256 => mapping(address => Resp)) public resps;
    mapping(uint256 => address[]) private responders;
    mapping(address => mapping(address => uint256)) public balance; // user => token => amount
    mapping(address => uint256) public fees;
    mapping(address => string) public orgName;
    mapping(address => bool) public banned;

    event Created(uint256 indexed id, address indexed creator);
    event Submitted(uint256 indexed id, address indexed user);
    event Reviewed(uint256 indexed id, address indexed user, bool approved);
    event Finalized(uint256 indexed id, uint32 valid, uint256 per, uint256 rem);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

    modifier onlyAdmin() { require(msg.sender == admin, "admin"); _; }

    constructor(address _usdt) { admin = msg.sender; usdt = _usdt; }

    function registerOrg(string calldata n) external { orgName[msg.sender] = n; }

    function createSurvey(
        string calldata t, string calldata q, uint64 dl, uint32 max,
        address token, uint256 amount, bool refund
    ) external payable returns (uint256 id) {
        require(bytes(orgName[msg.sender]).length > 0 && !banned[msg.sender], "org");
        require(token == address(0) || token == usdt, "token");
        require(dl > block.timestamp && amount > 0, "params");
        _pull(token, amount);
        id = count++;
        surveys[id] = Survey(msg.sender, t, q, dl, max, token, amount, refund, SState.Open, 0, 0, 0);
        emit Created(id, msg.sender);
    }

    function fund(uint256 id, uint256 amount) external payable {
        Survey storage s = surveys[id];
        require(s.state == SState.Open && amount > 0, "state");
        _pull(s.token, amount);
        s.pool += amount;
    }

    function _pull(address token, uint256 amount) internal {
        if (token == address(0)) require(msg.value == amount, "value");
        else { require(msg.value == 0, "value"); require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull"); }
    }

    function submit(uint256 id, string calldata data) external {
        Survey storage s = surveys[id];
        require(s.state == SState.Open && block.timestamp <= s.deadline, "closed");
        require(!banned[msg.sender] && msg.sender != s.creator, "ineligible");
        require(resps[id][msg.sender].status == Status.None, "duplicate");
        require(s.maxResponses == 0 || responders[id].length < s.maxResponses, "full");
        resps[id][msg.sender] = Resp(data, uint64(block.timestamp), Status.Submitted, "", 0, false);
        responders[id].push(msg.sender);
        emit Submitted(id, msg.sender);
    }

    /// Creator reviews Submitted responses; only admin resolves Appealed ones.
    function review(uint256 id, address u, bool ok, string calldata why) external {
        Survey storage s = surveys[id];
        require(msg.sender == s.creator || msg.sender == admin, "auth");
        require(s.state != SState.Finalized, "final");
        Resp storage r = resps[id][u];
        require(r.status == Status.Submitted || (r.status == Status.Appealed && msg.sender == admin), "state");
        if (ok) { r.status = Status.Approved; r.idx = s.valid++; }
        else { r.status = Status.Rejected; r.reason = why; }
        emit Reviewed(id, u, ok);
    }

    function appeal(uint256 id) external {
        Resp storage r = resps[id][msg.sender];
        require(surveys[id].state != SState.Finalized && r.status == Status.Rejected, "state");
        r.status = Status.Appealed;
    }

    function close(uint256 id) external {
        Survey storage s = surveys[id];
        require(s.state == SState.Open, "state");
        require(msg.sender == s.creator || msg.sender == admin || block.timestamp > s.deadline, "auth");
        s.state = SState.Closed;
    }

    /// Locks validation and fixes the per-respondent reward. No rewards move before this.
    function finalize(uint256 id) external {
        Survey storage s = surveys[id];
        require(s.state == SState.Closed && (msg.sender == s.creator || msg.sender == admin), "state");
        s.state = SState.Finalized;
        if (s.valid == 0) {
            if (s.refundIfNone) balance[s.creator][s.token] += s.pool; else fees[s.token] += s.pool;
            emit Finalized(id, 0, 0, 0);
            return;
        }
        uint256 fee = s.pool * feeBps / 10000;
        fees[s.token] += fee;
        uint256 d = s.pool - fee;
        s.per = d / s.valid;
        s.rem = d % s.valid;
        emit Finalized(id, s.valid, s.per, s.rem);
    }

    function claim(uint256 id) external {
        Survey storage s = surveys[id];
        Resp storage r = resps[id][msg.sender];
        require(s.state == SState.Finalized && r.status == Status.Approved && !r.claimed, "none");
        r.claimed = true;
        balance[msg.sender][s.token] += s.per + (r.idx < s.rem ? 1 : 0);
    }

    function withdraw(address token, uint256 amt) external {
        require(!banned[msg.sender] && amt > 0 && amt >= minWithdraw[token], "min");
        require(balance[msg.sender][token] >= amt, "balance");
        balance[msg.sender][token] -= amt; // effects before interaction
        if (token == address(0)) { (bool ok, ) = msg.sender.call{value: amt}(""); require(ok, "send"); }
        else require(IERC20(token).transfer(msg.sender, amt), "xfer");
        emit Withdrawn(msg.sender, token, amt);
    }

    function getResponders(uint256 id) external view returns (address[] memory) { return responders[id]; }

    // ---- administration ----
    function setFee(uint16 bps) external onlyAdmin { require(bps <= 1000, "max 10%"); feeBps = bps; }
    function setMin(address token, uint256 v) external onlyAdmin { minWithdraw[token] = v; }
    function ban(address u, bool b) external onlyAdmin { banned[u] = b; }
    function setAdmin(address a) external onlyAdmin { admin = a; }
    function withdrawFees(address token) external onlyAdmin {
        uint256 a = fees[token]; fees[token] = 0;
        if (token == address(0)) { (bool ok, ) = msg.sender.call{value: a}(""); require(ok, "send"); }
        else require(IERC20(token).transfer(msg.sender, a), "xfer");
    }
}
