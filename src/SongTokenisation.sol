// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title SongTokenisation
/// @author Anna Hlinska
/// @notice Fractional ownership of songs. Each song is split into a fixed number of shares
///         that fans buy with ETH. Developed for the Blockchain Fundamentals module (DAS5003).
/// @dev Money flows:
///      - Primary sales pay the rights holder (credited, withdrawn via `withdraw`).
///      - The owner can fund a per-song buy-back reserve. Fans sell shares back into a
///        contract-held pool and are paid from that reserve.
///      - Pool shares are sold first on later purchases; their proceeds refill the reserve,
///        so the same shares are never paid to the rights holder twice.
///      Invariant: address(this).balance == sum(buybackReserve) + sum(pendingWithdrawals).
contract SongTokenisation {
    struct Song {
        uint256 id;
        string title;
        string artist;
        uint256 totalShares;
        uint256 pricePerShare;
        address rightsHolder;
        bool active;
        uint256 createdAt;
    }

    struct SongDetails {
        string title;
        string artist;
        uint256 totalShares;
        uint256 pricePerShare;
        address rightsHolder;
        bool active;
        uint256 sharesWithRightsHolder;
        uint256 sharesInBuybackPool;
        uint256 buybackReserve;
        uint256 totalHolders;
    }

    address public owner;

    Song[] public songs;

    /// songId => holder => shares. Shares held by address(this) form the buy-back pool.
    mapping(uint256 => mapping(address => uint256)) public sharesOf;

    /// Everyone who has ever held shares of a song (the buy-back pool is not listed).
    mapping(uint256 => address[]) public songHolders;
    mapping(uint256 => mapping(address => bool)) private isHolder;

    /// songId => ETH available to buy shares back from fans.
    mapping(uint256 => uint256) public buybackReserve;

    /// ETH owed to rights holders from primary sales (pull payments).
    mapping(address => uint256) public pendingWithdrawals;

    uint256 private locked = 1;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SongCreated(uint256 indexed songId, string title, string artist, uint256 totalShares, uint256 pricePerShare);
    event SongSharesPurchased(uint256 indexed songId, address indexed buyer, uint256 sharesBought, uint256 valuePaid);
    event SongSharesTransferred(uint256 indexed songId, address indexed from, address indexed to, uint256 shareAmount);
    event SongSharesSold(uint256 indexed songId, address indexed seller, uint256 shareAmount, uint256 valueReturned);
    event SongDeactivated(uint256 indexed songId);
    event BuybackFunded(uint256 indexed songId, uint256 amount);
    event BuybackReserveWithdrawn(uint256 indexed songId, address indexed to, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only contract owner can do this");
        _;
    }

    modifier validSong(uint256 _songId) {
        require(_songId < songs.length, "Song doesn't exist");
        _;
    }

    modifier nonReentrant() {
        require(locked == 1, "Reentrant call");
        locked = 2;
        _;
        locked = 1;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid owner");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    /// @notice Registers a song. All shares start with the rights holder.
    function createSong(
        string memory _title,
        string memory _artist,
        uint256 _totalShares,
        uint256 _pricePerShare,
        address _rightsHolder
    ) external onlyOwner {
        require(_totalShares > 0, "Total shares must be > 0");
        require(_pricePerShare > 0, "Price must be > 0");
        require(_rightsHolder != address(0) && _rightsHolder != address(this), "Invalid rights holder");

        uint256 id = songs.length;
        songs.push(
            Song({
                id: id,
                title: _title,
                artist: _artist,
                totalShares: _totalShares,
                pricePerShare: _pricePerShare,
                rightsHolder: _rightsHolder,
                active: true,
                createdAt: block.timestamp
            })
        );

        sharesOf[id][_rightsHolder] = _totalShares;
        _addHolder(id, _rightsHolder);

        emit SongCreated(id, _title, _artist, _totalShares, _pricePerShare);
    }

    function deactivateSong(uint256 _songId) external onlyOwner validSong(_songId) {
        songs[_songId].active = false;
        emit SongDeactivated(_songId);
    }

    /// @notice Adds ETH to a song's buy-back reserve.
    function fundBuyback(uint256 _songId) external payable onlyOwner validSong(_songId) {
        require(msg.value > 0, "No ETH sent");
        buybackReserve[_songId] += msg.value;
        emit BuybackFunded(_songId, msg.value);
    }

    /// @notice Withdraws unused buy-back reserve. Cannot touch rights holders' earnings.
    function withdrawBuybackReserve(uint256 _songId, uint256 _amount, address payable _to)
        external
        onlyOwner
        validSong(_songId)
        nonReentrant
    {
        require(_to != address(0), "Invalid recipient");
        require(_amount <= buybackReserve[_songId], "Insufficient reserve");

        buybackReserve[_songId] -= _amount;
        emit BuybackReserveWithdrawn(_songId, _to, _amount);

        _sendValue(_to, _amount);
    }

    // ---------------------------------------------------------------------
    // Trading
    // ---------------------------------------------------------------------

    /// @notice Buys shares for exactly `pricePerShare * _shareAmount` wei.
    /// @dev Shares come from the buy-back pool first, then from the rights holder.
    function buySongShares(uint256 _songId, uint256 _shareAmount) external payable validSong(_songId) {
        Song storage song = songs[_songId];
        require(song.active, "Song not active");
        require(_shareAmount > 0, "Must buy more than 0 shares");
        require(msg.value == song.pricePerShare * _shareAmount, "Wrong amount of ETH");

        uint256 poolShares = sharesOf[_songId][address(this)];
        uint256 fromPool = _shareAmount < poolShares ? _shareAmount : poolShares;
        uint256 fromRightsHolder = _shareAmount - fromPool;

        require(sharesOf[_songId][song.rightsHolder] >= fromRightsHolder, "Not enough shares available");

        sharesOf[_songId][address(this)] -= fromPool;
        sharesOf[_songId][song.rightsHolder] -= fromRightsHolder;
        sharesOf[_songId][msg.sender] += _shareAmount;
        _addHolder(_songId, msg.sender);

        buybackReserve[_songId] += fromPool * song.pricePerShare;
        pendingWithdrawals[song.rightsHolder] += fromRightsHolder * song.pricePerShare;

        emit SongSharesPurchased(_songId, msg.sender, _shareAmount, msg.value);
    }

    function transferSongShares(uint256 _songId, address _to, uint256 _shareAmount) external validSong(_songId) {
        require(_to != address(0) && _to != address(this), "Invalid recipient");
        require(_shareAmount > 0, "Can't transfer 0 shares");
        require(sharesOf[_songId][msg.sender] >= _shareAmount, "Insufficient shares");

        sharesOf[_songId][msg.sender] -= _shareAmount;
        sharesOf[_songId][_to] += _shareAmount;
        _addHolder(_songId, _to);

        emit SongSharesTransferred(_songId, msg.sender, _to, _shareAmount);
    }

    /// @notice Sells shares back into the pool at the original price, paid from the
    ///         song's buy-back reserve. Not available to the rights holder.
    function sellSongShares(uint256 _songId, uint256 _shareAmount) external validSong(_songId) nonReentrant {
        Song storage song = songs[_songId];
        require(song.active, "Song not active");
        require(msg.sender != song.rightsHolder, "Rights holder can't sell back");
        require(_shareAmount > 0, "Can't sell 0 shares");
        require(sharesOf[_songId][msg.sender] >= _shareAmount, "Insufficient shares");

        uint256 refund = song.pricePerShare * _shareAmount;
        require(buybackReserve[_songId] >= refund, "Insufficient buyback reserve");

        sharesOf[_songId][msg.sender] -= _shareAmount;
        sharesOf[_songId][address(this)] += _shareAmount;
        buybackReserve[_songId] -= refund;

        emit SongSharesSold(_songId, msg.sender, _shareAmount, refund);

        _sendValue(payable(msg.sender), refund);
    }

    /// @notice Withdraws ETH earned from primary sales.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        pendingWithdrawals[msg.sender] = 0;
        emit Withdrawal(msg.sender, amount);

        _sendValue(payable(msg.sender), amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getTotalAssetsCreated() external view returns (uint256) {
        return songs.length;
    }

    /// @notice Current holders of a song and their share counts (buy-back pool excluded).
    function getAssetOwners(uint256 _songId)
        external
        view
        validSong(_songId)
        returns (address[] memory owners, uint256[] memory shareAmounts)
    {
        address[] storage holders = songHolders[_songId];

        uint256 count;
        for (uint256 i = 0; i < holders.length; i++) {
            if (sharesOf[_songId][holders[i]] > 0) count++;
        }

        owners = new address[](count);
        shareAmounts = new uint256[](count);

        uint256 index;
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 balance = sharesOf[_songId][holders[i]];
            if (balance > 0) {
                owners[index] = holders[i];
                shareAmounts[index] = balance;
                index++;
            }
        }
    }

    /// @notice Top 10 holders by share count, with ownership in basis points (5000 = 50.00%).
    /// @dev Partial selection sort: O(10 * n) instead of a full O(n^2) sort.
    function getTop10Beneficiaries(uint256 _songId)
        external
        view
        validSong(_songId)
        returns (address[] memory topAddresses, uint256[] memory topShares, uint256[] memory topPercentages)
    {
        address[] storage holders = songHolders[_songId];

        address[] memory addrs = new address[](holders.length);
        uint256[] memory shares = new uint256[](holders.length);
        uint256 count;
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 balance = sharesOf[_songId][holders[i]];
            if (balance > 0) {
                addrs[count] = holders[i];
                shares[count] = balance;
                count++;
            }
        }

        uint256 topCount = count > 10 ? 10 : count;
        for (uint256 i = 0; i < topCount; i++) {
            uint256 maxIndex = i;
            for (uint256 j = i + 1; j < count; j++) {
                if (shares[j] > shares[maxIndex]) maxIndex = j;
            }
            (shares[i], shares[maxIndex]) = (shares[maxIndex], shares[i]);
            (addrs[i], addrs[maxIndex]) = (addrs[maxIndex], addrs[i]);
        }

        uint256 total = songs[_songId].totalShares;
        topAddresses = new address[](topCount);
        topShares = new uint256[](topCount);
        topPercentages = new uint256[](topCount);
        for (uint256 i = 0; i < topCount; i++) {
            topAddresses[i] = addrs[i];
            topShares[i] = shares[i];
            topPercentages[i] = (shares[i] * 10_000) / total;
        }
    }

    function getSongDetails(uint256 _songId) external view validSong(_songId) returns (SongDetails memory) {
        Song storage song = songs[_songId];
        return SongDetails({
            title: song.title,
            artist: song.artist,
            totalShares: song.totalShares,
            pricePerShare: song.pricePerShare,
            rightsHolder: song.rightsHolder,
            active: song.active,
            sharesWithRightsHolder: sharesOf[_songId][song.rightsHolder],
            sharesInBuybackPool: sharesOf[_songId][address(this)],
            buybackReserve: buybackReserve[_songId],
            totalHolders: songHolders[_songId].length
        });
    }

    function getSharesOwned(uint256 _songId, address _owner) external view validSong(_songId) returns (uint256) {
        return sharesOf[_songId][_owner];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getAllSongs()
        external
        view
        returns (uint256[] memory ids, string[] memory titles, string[] memory artists, bool[] memory activeStatus)
    {
        uint256 length = songs.length;
        ids = new uint256[](length);
        titles = new string[](length);
        artists = new string[](length);
        activeStatus = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            ids[i] = songs[i].id;
            titles[i] = songs[i].title;
            artists[i] = songs[i].artist;
            activeStatus[i] = songs[i].active;
        }
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _addHolder(uint256 _songId, address _account) private {
        if (!isHolder[_songId][_account]) {
            isHolder[_songId][_account] = true;
            songHolders[_songId].push(_account);
        }
    }

    function _sendValue(address payable _to, uint256 _amount) private {
        (bool ok,) = _to.call{value: _amount}("");
        require(ok, "ETH transfer failed");
    }
}
