// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Generation registry: persistent contracts ask moduleOf(role)/isModule(addr) rather than naming
/// mechanics contracts. Upgrades are generational deploys, never proxies on money paths.
contract GameControllerV2 {
    uint256 public constant TIMELOCK = 2 days;
    uint256 public constant MAX_ROLES = 24;

    struct RoleSpec {
        bytes32 role;
        bool moneyPower;
    }

    address public admin;
    address public pendingAdmin;
    /// One-way: after sealing, module re-points require the timelock.
    bool public sealed_;
    /// Gates NEW exposure only.
    bool public closed;

    mapping(bytes32 => bool) public isRole;
    mapping(bytes32 => bool) public hasMoneyPower;
    mapping(bytes32 => address) public moduleOf;

    struct Pending {
        address module;
        uint64 eta;
    }

    mapping(bytes32 => Pending) public pendingModule;

    bytes32[] private _roles;

    event ModuleSet(bytes32 indexed role, address indexed module);
    event ModuleQueued(bytes32 indexed role, address indexed module, uint64 eta);
    event RoleDeclared(bytes32 indexed role, bool moneyPower);
    event Sealed();
    event Closed();
    event AdminProposed(address indexed pending);
    event AdminAccepted(address indexed admin);

    error NotAdmin();
    error UnknownRole();
    error AlreadySealed();
    error NotSealed();
    error NothingQueued();
    error TimelockActive();
    error NotPendingAdmin();
    error BadConfig();
    error DuplicateRole();
    error TooManyRoles();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address admin_, RoleSpec[] memory specs) {
        if (admin_ == address(0)) revert BadConfig();
        if (specs.length == 0) revert BadConfig();
        if (specs.length > MAX_ROLES) revert TooManyRoles();
        admin = admin_;

        for (uint256 i = 0; i < specs.length; i++) {
            bytes32 r = specs[i].role;
            if (r == bytes32(0)) revert BadConfig();
            if (isRole[r]) revert DuplicateRole();
            isRole[r] = true;
            hasMoneyPower[r] = specs[i].moneyPower;
            _roles.push(r);
            emit RoleDeclared(r, specs[i].moneyPower);
        }
    }

    function setModule(bytes32 role, address module) external onlyAdmin {
        if (!isRole[role]) revert UnknownRole();
        if (sealed_) revert AlreadySealed();
        moduleOf[role] = module;
        emit ModuleSet(role, module);
    }

    function queueModule(bytes32 role, address module) external onlyAdmin {
        if (!isRole[role]) revert UnknownRole();
        if (!sealed_) revert NotSealed();
        uint64 eta = uint64(block.timestamp + TIMELOCK);
        pendingModule[role] = Pending(module, eta);
        emit ModuleQueued(role, module, eta);
    }

    function executeModule(bytes32 role) external onlyAdmin {
        Pending memory p = pendingModule[role];
        if (p.eta == 0) revert NothingQueued();
        if (block.timestamp < p.eta) revert TimelockActive();
        delete pendingModule[role];
        moduleOf[role] = p.module;
        emit ModuleSet(role, p.module);
    }

    function seal() external onlyAdmin {
        if (sealed_) revert AlreadySealed();
        sealed_ = true;
        emit Sealed();
    }

    /// Exits, resolves, reclaims and bank() never consult this — closing stops new play, never an exit.
    function close() external onlyAdmin {
        closed = true;
        emit Closed();
    }

    function proposeAdmin(address next) external onlyAdmin {
        pendingAdmin = next;
        emit AdminProposed(next);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminAccepted(msg.sender);
    }

    /// KEEPER is declared without money power: it is a hot operator key and a whole-array scan would let
    /// a compromised keeper mint or drain. Do not widen this to "any registered role".
    function isModule(address account) external view returns (bool) {
        if (account == address(0)) return false;
        uint256 n = _roles.length;
        for (uint256 i = 0; i < n; i++) {
            bytes32 r = _roles[i];
            if (hasMoneyPower[r] && moduleOf[r] == account) return true;
        }
        return false;
    }

    function roleCount() external view returns (uint256) {
        return _roles.length;
    }

    function roleAt(uint256 i) external view returns (bytes32 role, bool moneyPower, address module) {
        role = _roles[i];
        moneyPower = hasMoneyPower[role];
        module = moduleOf[role];
    }
}
