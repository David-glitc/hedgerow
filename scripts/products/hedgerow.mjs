import assert from 'node:assert/strict';
import {parseAbi,encodePacked,toHex,parseEther} from 'viem';
const quoter=parseAbi(['function quoteExactInput(bytes path,uint256 amountIn) returns(uint256 amountOut,uint160[],uint32[],uint256)']);
// Tokens with live BDEX routes from USDT, per network (October 2026). `mid` routes through WBOT.
const WBOT='0xD5452816194a3784dBa983426cCe7c122F4abd30';
export const tokenLists={
 mainnet:[
  {symbol:'USDT',name:'Tether USD (cash)',address:'0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C',decimals:6,cash:true},
  {symbol:'WBOT',name:'Wrapped BOT',address:WBOT,decimals:18,fee1:3000},
  {symbol:'CA',name:'CaryPact',address:'0x546307af427902A75771434Df831d88219784E19',decimals:18,mid:WBOT,fee1:3000,fee2:10000},
  {symbol:'FLOW',name:'FlowBridge',address:'0xcaaB50F36252a57529AFeF651fa6B9f9281917fF',decimals:18,fee1:10000},
 ],
 testnet:[
  {symbol:'USDT',name:'Tether USD (cash)',address:'0x75edC9335175Fc0552D51D48439F229c10420fe3',decimals:6,cash:true},
  {symbol:'WBOT',name:'Wrapped BOT',address:WBOT,decimals:18,fee1:3000},
  {symbol:'TESTBOT1',name:'Test BOT 1 (testnet)',address:'0x62eCC4FfdE61f454EfFefA95f42296276F922888',decimals:18,mid:WBOT,fee1:3000,fee2:3000},
  {symbol:'TESTBOT3',name:'Test BOT 3 (testnet)',address:'0x037Fe8163A86235B9889f848F740fBd2224A4888',decimals:18,fee1:3000},
 ],
};
const ZERO='0x0000000000000000000000000000000000000000';
export const component=(t,weightBps)=>({token:t.address,weightBps,mid:t.mid||ZERO,fee1:t.fee1||0,fee2:t.fee2||0});
export const path=(usdt,c)=>c.mid===ZERO?encodePacked(['address','uint24','address'],[usdt,c.fee1,c.token]):encodePacked(['address','uint24','address','uint24','address'],[usdt,c.fee1,c.mid,c.fee2,c.token]);
export default {
 slug:'hedgerow',vercel:'hedgerowbot',assets:['TOKENS','BDEX','QUOTER'],name:'Hedgerow',repo:'hedgerow',contract:'HedgeFactory',color:'#ccff00',eyebrow:'HEDGE DAO',symbol:'H',
 line:'Pick a basket. Fund it together.',
 app:{title:'Basket factsheets',line:'Back a raise, join a live basket, or design your own.',layout:'sheet'},
 description:'Creators design a token basket, the community funds it in USDT, and holders steer it onchain. A hedge DAO on BOT Chain.',
 abis:['HedgeFactory','HedgeVault'],
 contracts:['src/hedge/HedgeFactory.sol','src/hedge/HedgeVault.sol','src/interfaces/IBotV3Router.sol'],tests:['test/Hedgerow.t.sol'],
 landing:{
  steps:[['Design a basket','Pick up to five BDEX-traded tokens and their weights, a USDT goal, a raise window, fees and how the basket is governed.'],['Raise, then trade','Backers deposit USDT. When the goal is met the creator buys the whole basket in one go; a missed goal refunds everyone.'],['Hold, steer, exit','Shares track your slice of every token. Late joiners pay a higher fee, holders vote on changes, and anyone redeems after the lockup.']],
  features:[['Three governance modes','Fixed baskets never change, managed baskets rebalance behind a 24-hour timelock, DAO baskets change only by holder vote.'],['Manipulation-resistant shares','Shares are priced from the vault\'s own holdings, never from DEX prices, so pumping a pool cannot mint extra shares.'],['Refunds built in','Missed goals and unfinalized raises return every USDT. Raise fees are only charged when the basket launches.'],['Exit your way','Redeem in kind for your slice of each token, or sell it back to USDT with your own minimum output.']],
  faq:[['Which tokens can a basket hold?','Any token with a BDEX route from USDT, directly or through WBOT. Today that means USDT, WBOT, CaryPact (CA) and FlowBridge (FLOW). New BDEX listings become available automatically.'],['What do creators earn?','A raise fee of up to 2% when the basket launches, and a late-entry fee of up to 5% that is never lower than the raise fee.'],['How does DAO voting work?','Holders vote with their shares as of the proposal. A change passes with a majority and at least 20% of all shares voting for it, then the creator executes it within seven days.'],['What are the risks?','Basket tokens can lose value, thin pools move on large trades, and the creator sets minimum outputs when buying. The contracts are unaudited; start small.']],
 },
 tokens:tokenLists,
 async deploy({deploy,i}){await deploy('HedgeFactory',[i.USDT,i.router]);},
 async fork({c,abi,i,tx,write,read,contract,owner,fundUSDT,artifact,net}){
  const tokens=tokenLists[net];
  const vaultAbi=artifact('HedgeVault').abi;const v=(fn,args=[],value=0n,address)=>tx(vaultAbi,address,fn,args,value);
  const quote=async(cmp,n)=>cmp.token.toLowerCase()===i.USDT.toLowerCase()?0n:(await c.simulateContract({address:i.quoter,abi:quoter,functionName:'quoteExactInput',args:[path(i.USDT,cmp),n]})).result[0]*97n/100n;
  const basket=[component(tokens[1],5000),component(tokens[2],1500),component(tokens[3],1000),component(tokens[0],2500)];
  const mins=async net=>Promise.all(basket.map(cmp=>quote(cmp,net*BigInt(cmp.weightBps)/10000n)));
  await fundUSDT(200000000n);const now=BigInt((await c.getBlock()).timestamp);
  await write('HedgeFactory','createVault',[{creator:owner.address,name:'Fork Basket',symbol:'FORK',mode:2,goal:50000000n,raiseEnd:now+7200n,lockup:0n,raiseFeeBps:100,lateFeeBps:300,components:basket}]);
  const vault=await read('HedgeFactory','vaults',[await read('HedgeFactory','vaultCount')-1n]);
  await tx(abi,i.USDT,'approve',[vault,200000000n]);await v('deposit',[60000000n],0n,vault);
  await v('finalize',[await mins(59400000n),now+3600n],0n,vault);await v('claimShares',[],0n,vault);
  const held=await c.readContract({address:vault,abi:vaultAbi,functionName:'holdings'});
  for(const [n,t] of held[0].entries())if(t.toLowerCase()!==i.USDT.toLowerCase())assert(held[1][n]>0n,`no ${t}`);
  await v('join',[20000000n,await mins(19400000n),now+3600n],0n,vault);
  const shares=await c.readContract({address:vault,abi:vaultAbi,functionName:'balanceOf',args:[owner.address]});
  // DAO: move the basket to WBOT + USDT by vote.
  const next=[component(tokens[1],7000),component(tokens[0],3000)];
  await c.request({method:'anvil_mine',params:['0x1']});await v('propose',[next],0n,vault);await v('vote',[0n,true],0n,vault);
  await c.request({method:'evm_increaseTime',params:[48*3600+1]});await c.request({method:'evm_mine',params:[]});
  const after=BigInt((await c.getBlock()).timestamp);
  const sellMins=held[0].slice(0,basket.length).map((t,n)=>t.toLowerCase()===i.USDT.toLowerCase()?0n:1n);
  await v('execute',[0n,sellMins,[1n,0n],after+3600n],0n,vault);
  await v('redeem',[shares/2n],0n,vault);
  const before=await c.readContract({address:i.USDT,abi,functionName:'balanceOf',args:[owner.address]});
  await v('redeemToUSDT',[shares-shares/2n,[1n,0n],1n,after+3600n],0n,vault);
  const got=await c.readContract({address:i.USDT,abi,functionName:'balanceOf',args:[owner.address]})-before;assert(got>0n);
  return {vault,shares:String(shares),usdtFromRedeem:String(got),flow:'create → raise → finalize (WBOT, CA via WBOT, FLOW, USDT) → claim → late join → DAO vote → rebalance → redeem in kind → redeem to USDT'};
 },
};
