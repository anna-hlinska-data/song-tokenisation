// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/*
    Song Tokenisation Smart Contract
    
    Developed for the Blockchain Fundamentals module (DAS5003).
    The contract tokenises songs by splitting them into shares that people can buy.
    It's like fractional ownership - instead of one person owning a whole song,
    lots of people can own small pieces of it.

    Main features:
    - Create new songs with a set number of shares
    - Let people buy shares using ETH
    - Transfer shares between users
    - Sell shares back to get your money back
    - See who owns the most shares (top 10)
*/

contract SongTokenisationV1 {

    // The account that deployed this contract
    address public owner;

    // These events help us track what's happening in the contract
    // We can see them in Remix or on Etherscan after transactions
    event SongCreated(uint256 songId, string title, string artist, uint256 totalShares, uint256 pricePerShare);
    event SongSharesPurchased(uint256 songId, address buyer, uint256 sharesBought, uint256 valuePaid);
    event SongSharesTransferred(uint256 songId, address from, address to, uint256 shareAmount);
    event SongSharesSold(uint256 songId, address seller, uint256 shareAmount, uint256 valueReturned);
    event SongDeactivated(uint256 songId);

    // This is how we store information about each song
    // Think of it like a container that holds all the song's details
    struct Song {
        uint256 id;                    // unique number for this song (0, 1, 2, etc.)
        string title;                  // name of the song
        string artist;                 // who made it
        uint256 totalShares;           // how many shares exist in total
        uint256 pricePerShare;         // how much each share costs (in wei)
        address payable rightsHolder;  // person who owns the copyright (gets paid)
        bool active;                   // can people still trade this song?
        uint256 createdAt;             // when we created this song (timestamp)
    }

    // NEW: Struct to fix "Stack too deep" error
    // Groups all the return values together
    struct SongDetails {
        string title;
        string artist;
        uint256 totalShares;
        uint256 pricePerShare;
        address rightsHolder;
        bool active;
        uint256 sharesRemaining;
        uint256 totalHolders;
    }

    // Array that stores all our songs
    // songs[0] is the first song we created, songs[1] is the second, etc.
    Song[] public songs;

    // This mapping tracks who owns how many shares of each song
    // Example: sharesOf[0][0x123...] = 50 means address 0x123... owns 50 shares of song 0
    mapping(uint256 => mapping(address => uint256)) public sharesOf;

    // List of everyone who has ever owned shares of a song
    // We use this later to find all owners and calculate top 10
    mapping(uint256 => address[]) public songHolders;

    // Helper mapping to check if someone is already in the holders list
    // Prevents us from adding the same person twice
    mapping(uint256 => mapping(address => bool)) private isHolder;

    // This modifier makes sure only the contract owner can do certain things
    // Like creating new songs - we don't want random people adding songs
    modifier onlyOwner() {
        require(msg.sender == owner, "Only contract owner can do this");
        _;
    }

    // This modifier checks if a song actually exists before we try to use it
    // Prevents errors if someone tries to buy shares of song #999 when we only have 3 songs
    modifier validSong(uint256 _songId) {
        require(_songId < songs.length, "Song doesn't exist");
        _;
    }

    // Constructor runs once when we deploy the contract
    // Sets the deployer as the owner
    constructor() {
        owner = msg.sender;
    }

    // =======================================================================
    // Main functions that users interact with
    // =======================================================================

    // This function creates a new tokenised song
    // Only the contract owner (us) can call this
    function createSong(
        string memory _title,
        string memory _artist,
        uint256 _totalShares,
        uint256 _pricePerShare,
        address payable _rightsHolder
    ) public onlyOwner {

        // Make sure the inputs make sense
        require(_totalShares > 0, "Total shares must be > 0");
        require(_pricePerShare > 0, "Price must be > 0");
        require(_rightsHolder != address(0), "Invalid rights holder");

        // The song ID is just its position in the array
        uint256 id = songs.length;

        // Add the new song to our array
        songs.push(Song({
            id: id,
            title: _title,
            artist: _artist,
            totalShares: _totalShares,
            pricePerShare: _pricePerShare,
            rightsHolder: _rightsHolder,
            active: true,
            createdAt: block.timestamp
        }));

        // Give all the shares to the rights holder at the start
        // They can then sell them to fans
        sharesOf[id][_rightsHolder] = _totalShares;
        
        // Add rights holder to the list of people who own shares
        songHolders[id].push(_rightsHolder);
        isHolder[id][_rightsHolder] = true;

        // Emit event so we can see the song was created
        emit SongCreated(id, _title, _artist, _totalShares, _pricePerShare);
    }

    // This is how people buy shares of a song
    // They send ETH and get shares in return
    function buySongShares(uint256 _songId, uint256 _shareAmount)
        public
        payable
        validSong(_songId)
    {
        Song storage song = songs[_songId];

        // Check that the song is still active
        require(song.active, "Song not active");
        
        // Can't buy zero shares
        require(_shareAmount > 0, "Must buy more than 0 shares");

        // Calculate how much ETH they need to send
        uint256 cost = song.pricePerShare * _shareAmount;
        
        // Make sure they sent exactly the right amount
        // Not more, not less - has to be exact
        require(msg.value == cost, "Wrong amount of ETH");

        // Check if the rights holder has enough shares left to sell
        require(
            sharesOf[_songId][song.rightsHolder] >= _shareAmount,
            "Not enough shares available"
        );

        // Move the shares from rights holder to buyer
        sharesOf[_songId][song.rightsHolder] -= _shareAmount;
        sharesOf[_songId][msg.sender] += _shareAmount;

        // If this is their first time buying this song, add them to holders list
        if (!isHolder[_songId][msg.sender]) {
            songHolders[_songId].push(msg.sender);
            isHolder[_songId][msg.sender] = true;
        }

        // Send the ETH payment to the rights holder
        song.rightsHolder.transfer(cost);

        // Record the purchase in an event
        emit SongSharesPurchased(_songId, msg.sender, _shareAmount, cost);
    }

    // This function lets people transfer shares to someone else
    // Like giving shares to a friend or moving them between your own wallets
    function transferSongShares(uint256 _songId, address _to, uint256 _shareAmount)
        public
        validSong(_songId)
    {
        // Can't send to the zero address (that would destroy the shares)
        require(_to != address(0), "Invalid recipient");
        
        // Can't transfer zero shares
        require(_shareAmount > 0, "Can't transfer 0 shares");
        
        // Make sure the sender actually has enough shares
        require(sharesOf[_songId][msg.sender] >= _shareAmount, "Insufficient shares");

        // Move shares from sender to receiver
        sharesOf[_songId][msg.sender] -= _shareAmount;
        sharesOf[_songId][_to] += _shareAmount;

        // If the receiver is new, add them to holders list
        if (!isHolder[_songId][_to]) {
            songHolders[_songId].push(_to);
            isHolder[_songId][_to] = true;
        }

        // Record the transfer
        emit SongSharesTransferred(_songId, msg.sender, _to, _shareAmount);
    }

    // This function lets people sell their shares back to the contract
    // They get their ETH back at the original price
    // But the contract needs to have enough ETH in it first
    function sellSongShares(uint256 _songId, uint256 _shareAmount)
        public
        validSong(_songId)
    {
        Song storage song = songs[_songId];

        // Can't sell zero shares
        require(_shareAmount > 0, "Can't sell 0 shares");
        
        // Make sure they have enough shares to sell
        require(sharesOf[_songId][msg.sender] >= _shareAmount, "Insufficient shares");

        // Calculate how much ETH to give them back
        uint256 refund = song.pricePerShare * _shareAmount;
        
        // Make sure the contract has enough ETH to pay them
        // The owner needs to fund the contract first using fundContract()
        require(address(this).balance >= refund, "Insufficient contract balance");

        // Move shares back to the rights holder
        sharesOf[_songId][msg.sender] -= _shareAmount;
        sharesOf[_songId][song.rightsHolder] += _shareAmount;

        // Send ETH to the seller
        payable(msg.sender).transfer(refund);

        // Record the sale
        emit SongSharesSold(_songId, msg.sender, _shareAmount, refund);
    }

    // =======================================================================
    // Functions required by our assessment
    // These help us analyze the data and show ownership information
    // =======================================================================

    // Assessment requirement: "determine how many assets have been created"
    // Just returns how many songs we've tokenised
    function getTotalAssetsCreated() public view returns (uint256) {
        return songs.length;
    }

    // Assessment requirement: "determine asset owners"
    // Returns everyone who currently owns shares of a song and how many they have
    function getAssetOwners(uint256 _songId)
        public
        view
        validSong(_songId)
        returns (address[] memory owners, uint256[] memory shareAmounts)
    {
        address[] memory holders = songHolders[_songId];
        uint256[] memory shares = new uint256[](holders.length);
        
        // First, count how many people actually have shares right now
        // (some might have had shares before but sold them all)
        uint256 count = 0;
        for (uint256 i = 0; i < holders.length; i++) {
            if (sharesOf[_songId][holders[i]] > 0) {
                shares[count] = sharesOf[_songId][holders[i]];
                count++;
            }
        }
        
        // Create new arrays with just the current owners
        address[] memory actualOwners = new address[](count);
        uint256[] memory actualShares = new uint256[](count);
        
        uint256 index = 0;
        for (uint256 i = 0; i < holders.length; i++) {
            if (sharesOf[_songId][holders[i]] > 0) {
                actualOwners[index] = holders[i];
                actualShares[index] = sharesOf[_songId][holders[i]];
                index++;
            }
        }
        
        return (actualOwners, actualShares);
    }

    // Assessment requirement: "determine top 10 beneficiaries"
    // Returns the top 10 people who own the most shares
    // Also calculates what percentage of the song they own
    function getTop10Beneficiaries(uint256 _songId)
        public
        view
        validSong(_songId)
        returns (
            address[] memory topAddresses,
            uint256[] memory topShares,
            uint256[] memory topPercentages
        )
    {
        address[] memory holders = songHolders[_songId];
        uint256 holderCount = holders.length;
        
        // Create temporary arrays for sorting
        address[] memory tempAddresses = new address[](holderCount);
        uint256[] memory tempShares = new uint256[](holderCount);
        
        // Collect all current holders and their share counts
        uint256 actualCount = 0;
        for (uint256 i = 0; i < holderCount; i++) {
            if (sharesOf[_songId][holders[i]] > 0) {
                tempAddresses[actualCount] = holders[i];
                tempShares[actualCount] = sharesOf[_songId][holders[i]];
                actualCount++;
            }
        }
        
        // Sort them from highest to lowest using bubble sort
        // We use bubble sort because it's simple and our lists are usually small
        // For bigger lists we could use a faster algorithm but this works fine
        for (uint256 i = 0; i < actualCount; i++) {
            for (uint256 j = i + 1; j < actualCount; j++) {
                if (tempShares[j] > tempShares[i]) {
                    // Swap the share amounts
                    uint256 tempShare = tempShares[i];
                    tempShares[i] = tempShares[j];
                    tempShares[j] = tempShare;
                    
                    // Swap the addresses to match
                    address tempAddr = tempAddresses[i];
                    tempAddresses[i] = tempAddresses[j];
                    tempAddresses[j] = tempAddr;
                }
            }
        }
        
        // Get the top 10 (or less if there aren't 10 holders)
        uint256 top10Count = actualCount > 10 ? 10 : actualCount;
        
        topAddresses = new address[](top10Count);
        topShares = new uint256[](top10Count);
        topPercentages = new uint256[](top10Count);
        
        Song storage song = songs[_songId];
        
        // Fill in the results and calculate percentages
        for (uint256 i = 0; i < top10Count; i++) {
            topAddresses[i] = tempAddresses[i];
            topShares[i] = tempShares[i];
            // Calculate percentage with 2 decimal places
            // We multiply by 10000 to get precision (e.g., 5000 = 50.00%)
            topPercentages[i] = (tempShares[i] * 10000) / song.totalShares;
        }
        
        return (topAddresses, topShares, topPercentages);
    }

    // FIXED: Helper function to get all details about a song at once
    // Now returns a struct instead of 8 separate values to avoid "Stack too deep" error
    function getSongDetails(uint256 _songId)
        public
        view
        validSong(_songId)
        returns (SongDetails memory)
    {
        Song storage song = songs[_songId];
        
        return SongDetails({
            title: song.title,
            artist: song.artist,
            totalShares: song.totalShares,
            pricePerShare: song.pricePerShare,
            rightsHolder: song.rightsHolder,
            active: song.active,
            sharesRemaining: sharesOf[_songId][song.rightsHolder],
            totalHolders: songHolders[_songId].length
        });
    }

    // Check how many shares a specific address owns
    function getSharesOwned(uint256 _songId, address _owner)
        public
        view
        validSong(_songId)
        returns (uint256)
    {
        return sharesOf[_songId][_owner];
    }

    // Owner can turn off trading for a song if needed
    function deactivateSong(uint256 _songId)
        public
        onlyOwner
        validSong(_songId)
    {
        songs[_songId].active = false;
        emit SongDeactivated(_songId);
    }

    // Owner can add ETH to the contract so people can sell shares back
    // Just send ETH to this function
    function fundContract() public payable onlyOwner {}

    // Check how much ETH the contract has
    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    // Get a list of all songs we've created
    function getAllSongs()
        public
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
        
        return (ids, titles, artists, activeStatus);
    }
}