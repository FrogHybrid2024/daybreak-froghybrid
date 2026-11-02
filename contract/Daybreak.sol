// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Daybreak by FrogHybrid: one NFT whose artwork lives entirely onchain.
// The finished page (index.html, the live code of the three surfaces) and its preview picture are stored as base64
// text in pieces of at most 24,575 bytes, each in its own storage contract (SSTORE2), the way Leap of Faith stores its
// picture. tokenURI joins them into the metadata (name, description, image = the picture, animation_url = the page,
// both as data: links), so no outside server is needed and the read stays cheap. The owner uploads the pieces, mints the
// one token, and then freezes the art for good, giving the fingerprints of the files so a partial or wrong upload can
// never be frozen; the description and the website link can be frozen separately once the site exists.

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {LibString} from "solady/src/utils/LibString.sol";

contract Daybreak is ERC721, Ownable2Step, IERC4906 {
    uint256 public constant TOKEN_ID = 1;
    uint256 private constant DATA_OFFSET = 1; // SSTORE2 keeps a 0x00 byte in front of the data

    address[] private _pagePieces;    // the page, in order
    address[] private _picturePieces; // the preview picture, in order

    string public description;
    string public websiteUrl;
    string public pictureType = "image/png";

    bool public artFrozen;
    bool public detailsFrozen;
    bool public minted;

    event PiecesAdded(bool isPage, uint256 index, address pointer, uint256 size);
    event PiecesCleared(bool isPage);
    event ArtFrozen(bytes32 pageKeccak, bytes32 pictureKeccak);
    event DetailsFrozen();

    error ArtIsFrozen();
    error DetailsAreFrozen();
    error AlreadyMinted();
    error NothingUploaded();
    error PieceTooBig();
    error NoSuchToken();
    error WrongFingerprint();
    error NotAllowedChar();
    error NotUntilFrozen();

    constructor(string memory name_, string memory symbol_, string memory description_)
        ERC721(name_, symbol_)
        Ownable(msg.sender)
    {
        _checkText(description_);
        description = description_;
    }

    // ---- uploading (owner only, until the art is frozen) ----

    function addPagePiece(bytes calldata data) external onlyOwner {
        _addPiece(_pagePieces, data, true);
    }

    /// Several page pieces in one transaction, in order (3 a time keeps a transaction near 74 KB and 16M gas: 24 pieces in 8
    /// signatures instead of 24).
    function addPagePieces(bytes[] calldata pieces) external onlyOwner {
        for (uint256 i; i < pieces.length; ++i) _addPiece(_pagePieces, pieces[i], true);
    }

    function addPicturePiece(bytes calldata data) external onlyOwner {
        _addPiece(_picturePieces, data, false);
    }

    /// Starts the page upload again (for an upload that went wrong part-way). Not possible once frozen.
    function clearPage() external onlyOwner {
        if (artFrozen) revert ArtIsFrozen();
        delete _pagePieces;
        emit PiecesCleared(true);
        _refresh();
    }

    /// Takes off the last page piece (to fix one bad or doubled piece without starting again). Not possible once frozen.
    function removeLastPagePiece() external onlyOwner {
        if (artFrozen) revert ArtIsFrozen();
        if (_pagePieces.length == 0) revert NothingUploaded();
        _pagePieces.pop();
        emit PiecesCleared(true);
        _refresh();
    }

    function clearPicture() external onlyOwner {
        if (artFrozen) revert ArtIsFrozen();
        delete _picturePieces;
        emit PiecesCleared(false);
        _refresh();
    }

    function setPictureType(string calldata mime) external onlyOwner {
        if (artFrozen) revert ArtIsFrozen();
        _checkText(mime);
        pictureType = mime;
        _refresh();
    }

    function _addPiece(address[] storage list, bytes calldata data, bool isPage) private {
        if (artFrozen) revert ArtIsFrozen();
        if (data.length == 0 || data.length > 24575) revert PieceTooBig();
        address pointer = SSTORE2.write(data);
        list.push(pointer);
        emit PiecesAdded(isPage, list.length - 1, pointer, data.length);
        _refresh();
    }

    // ---- the one token ----

    function mint(address to) external onlyOwner {
        if (minted) revert AlreadyMinted();
        minted = true;
        _safeMint(to, TOKEN_ID);
    }

    // ---- details (owner only, until frozen) ----

    function setDescription(string calldata text) external onlyOwner {
        if (detailsFrozen) revert DetailsAreFrozen();
        _checkText(text);
        description = text;
        _refresh();
    }

    function setWebsiteUrl(string calldata url) external onlyOwner {
        if (detailsFrozen) revert DetailsAreFrozen();
        _checkText(url);
        websiteUrl = url;
        _refresh();
    }

    // ---- freezing (for good; cannot be undone) ----

    /// Freezes the page and picture for good, only if what is stored matches the files exactly: the caller gives the
    /// keccak-256 fingerprints of the base64 text of index.html and of the picture (the signing page works them out).
    function freezeArt(bytes32 expectedPageHash, bytes32 expectedPictureHash) external onlyOwner {
        if (artFrozen) revert ArtIsFrozen();
        if (_pagePieces.length == 0 || _picturePieces.length == 0) revert NothingUploaded();
        bytes32 pageKeccak = keccak256(bytes(pageBase64()));
        bytes32 pictureKeccak = keccak256(bytes(pictureBase64()));
        if (pageKeccak != expectedPageHash || pictureKeccak != expectedPictureHash) revert WrongFingerprint();
        artFrozen = true;
        emit ArtFrozen(pageKeccak, pictureKeccak);
        _refresh();
    }

    function freezeDetails() external onlyOwner {
        if (detailsFrozen) revert DetailsAreFrozen();
        detailsFrozen = true;
        emit DetailsFrozen();
        _refresh();
    }

    // ---- ownership ----

    /// Giving up ownership is refused until the token exists and both freezes are done: before that it would leave the
    /// upload or the mint unfinished for good. Handing over uses two steps (transferOwnership, then acceptOwnership by
    /// the new owner), so a mistyped address cannot take it.
    function renounceOwnership() public override onlyOwner {
        if (!(minted && artFrozen && detailsFrozen)) revert NotUntilFrozen();
        super.renounceOwnership();
    }

    // ---- reading ----

    /// The page as uploaded: base64 text of index.html (the website reads this and decodes it).
    function pageBase64() public view returns (string memory) {
        return string(_readAll(_pagePieces));
    }

    /// The preview picture as uploaded: base64 text of the PNG.
    function pictureBase64() public view returns (string memory) {
        return string(_readAll(_picturePieces));
    }

    function pagePieceCount() external view returns (uint256) {
        return _pagePieces.length;
    }

    function picturePieceCount() external view returns (uint256) {
        return _picturePieces.length;
    }

    function pagePiece(uint256 i) external view returns (address) {
        return _pagePieces[i];
    }

    function picturePiece(uint256 i) external view returns (address) {
        return _picturePieces[i];
    }

    /// Fingerprints (keccak-256) of the stored base64 text, for checking a copy against the chain.
    function pageHash() external view returns (bytes32) {
        return keccak256(bytes(pageBase64()));
    }

    function pictureHash() external view returns (bytes32) {
        return keccak256(bytes(pictureBase64()));
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (tokenId != TOKEN_ID || !minted) revert NoSuchToken();
        // Plain JSON after "data:application/json;utf8," (the form Leap of Faith uses, shown by Robinhood's Blockscout),
        // built in one buffer and returned as it is.
        bytes memory pic = bytes(pictureBase64());
        bytes memory pg = bytes(pageBase64());
        bytes memory head = bytes(string.concat(
            'data:application/json;utf8,{"name":"', LibString.escapeJSON(name()),
            '","description":"', LibString.escapeJSON(description),
            '","image":"data:', LibString.escapeJSON(pictureType), ";base64,"
        ));
        bytes memory mid = bytes('","animation_url":"data:text/html;charset=utf-8;base64,');
        bytes memory tail = bytes(string.concat(
            '"',
            bytes(websiteUrl).length > 0 ? string.concat(',"external_url":"', LibString.escapeJSON(websiteUrl), '"') : "",
            "}"
        ));
        bytes memory out = new bytes(head.length + pic.length + mid.length + pg.length + tail.length);
        uint256 p;
        assembly { p := add(out, 0x20) }
        p = _copyInto(head, p);
        p = _copyInto(pic, p);
        p = _copyInto(mid, p);
        p = _copyInto(pg, p);
        _copyInto(tail, p);
        // Return `out` in place (ABI: offset 0x20, then the length and the text, zero-padded to a whole word) instead
        // of letting Solidity copy 600 KB once more. Nothing is allocated after `out`, so the words used are free.
        assembly {
            let len := mload(out)
            mstore(add(add(out, 0x20), len), 0)
            mstore(sub(out, 0x20), 0x20)
            return(sub(out, 0x20), add(0x40, and(add(len, 31), not(31))))
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // ---- internals ----

    /// Joins the pieces in one pass: one allocation, each piece copied straight into place.
    function _readAll(address[] storage list) private view returns (bytes memory out) {
        uint256 n = list.length;
        uint256 total;
        for (uint256 i; i < n; ++i) total += list[i].code.length - DATA_OFFSET;
        out = new bytes(total);
        uint256 dest;
        assembly { dest := add(out, 0x20) }
        for (uint256 i; i < n; ++i) {
            address p = list[i];
            uint256 len = p.code.length - DATA_OFFSET;
            assembly { extcodecopy(p, dest, DATA_OFFSET, len) }
            dest += len;
        }
    }

    /// Copies `src` to memory address `dest` and returns the address just after it. It writes whole 32-byte words, so
    /// up to 31 bytes past the end may be overwritten; tokenURI writes its parts in order into `out`, the last thing it
    /// allocates, so the overrun lands in the next part (written over after) or in free memory past `out`.
    function _copyInto(bytes memory src, uint256 dest) private pure returns (uint256) {
        uint256 len = src.length;
        assembly {
            let s := add(src, 0x20)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } { mstore(add(dest, i), mload(add(s, i))) }
        }
        return dest + len;
    }

    /// The description, website link and picture type go into a "data:" link as plain text; '#' and '%' would cut it short or change
    /// it for readers that treat it as a web address, so they are refused.
    function _checkText(string memory t) private pure {
        bytes memory b = bytes(t);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == "#" || b[i] == "%") revert NotAllowedChar();
        }
    }

    /// Tells explorers and marketplaces to read the metadata again (ERC-4906), once the token exists.
    function _refresh() private {
        if (minted) emit MetadataUpdate(TOKEN_ID);
    }
}
