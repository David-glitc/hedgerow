// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Fixed future block entropy, NOT a VRF. Block producers can influence it.
/// Anyone may fulfill after the target block. Expired requests can be rescheduled.
contract BotEntropy {
    uint256 public nextRequestId = 1;
    mapping(uint256=>address) public consumers;
    mapping(uint256=>uint256) public targetBlock;
    mapping(uint256=>bool) public fulfilled;
    event Requested(uint256 indexed id,address indexed consumer,uint256 target);
    function requestRandomWords(bytes32,uint64,uint16,uint32,uint32 words) external returns(uint256 id) {
        require(words==1,"one word"); id=nextRequestId++; consumers[id]=msg.sender; targetBlock[id]=block.number+5;
        emit Requested(id,msg.sender,targetBlock[id]);
    }
    function fulfill(uint256 id) external {
        require(consumers[id]!=address(0)&&!fulfilled[id],"unknown or fulfilled");
        uint256 target=targetBlock[id];
        require(block.number>target && block.number<=target+256,"outside window");
        bytes32 entropy=blockhash(target); require(entropy!=bytes32(0),"missing block");
        fulfilled[id]=true;
        uint256[] memory words=new uint256[](1); words[0]=uint256(keccak256(abi.encode(entropy,id,consumers[id])));
        (bool ok,)=consumers[id].call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])",id,words));
        require(ok,"fulfill failed");
    }
    function reschedule(uint256 id) external {
        require(consumers[id]!=address(0)&&!fulfilled[id]&&block.number>targetBlock[id]+256,"not expired");
        targetBlock[id]=block.number+5; emit Requested(id,consumers[id],targetBlock[id]);
    }
}
