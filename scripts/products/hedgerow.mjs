import assert from 'node:assert/strict';
import {parseAbi,encodePacked,toHex,parseEther} from 'viem';
const quoter=parseAbi(['function quoteExactInput(bytes path,uint256 amountIn) returns(uint256 amountOut,uint160[],uint32[],uint256)']);
// Baskets are funded in WBOT (the app wraps native BOT). Tokens with live BDEX routes from WBOT, per network (October 2026).
// `mid` is the hop token for two-hop routes (WBOT -fee1-> mid -fee2-> token).
const WBOT='0xD5452816194a3784dBa983426cCe7c122F4abd30';
export const tokenLists={
 mainnet:[
  {symbol:'WBOT',name:'Wrapped BOT (cash)',address:WBOT,decimals:18,cash:true},
  {symbol:'USDT',name:'Tether USD',address:'0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C',decimals:6,fee1:3000},
  {symbol:'CA',name:'CaryPact',address:'0x546307af427902A75771434Df831d88219784E19',decimals:18,fee1:10000},
  {symbol:'FLOW',name:'FlowBridge',address:'0xcaaB50F36252a57529AFeF651fa6B9f9281917fF',decimals:18,mid:'0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C',fee1:3000,fee2:10000},
 ],
 testnet:[
  {symbol:'WBOT',name:'Wrapped BOT (cash)',address:WBOT,decimals:18,cash:true},
  {symbol:'USDT',name:'Tether USD',address:'0x75edC9335175Fc0552D51D48439F229c10420fe3',decimals:6,fee1:3000},
  {symbol:'TESTBOT1',name:'Test BOT 1 (testnet)',address:'0x62eCC4FfdE61f454EfFefA95f42296276F922888',decimals:18,fee1:3000},
  {symbol:'TESTBOT3',name:'Test BOT 3 (testnet)',address:'0x037Fe8163A86235B9889f848F740fBd2224A4888',decimals:18,mid:'0x75edC9335175Fc0552D51D48439F229c10420fe3',fee1:3000,fee2:3000},
 ],
};
const ZERO='0x0000000000000000000000000000000000000000';
export const component=(t,weightBps)=>({token:t.address,weightBps,mid:t.mid||ZERO,fee1:t.fee1||0,fee2:t.fee2||0});
export const path=(cash,c)=>c.mid===ZERO?encodePacked(['address','uint24','address'],[cash,c.fee1,c.token]):encodePacked(['address','uint24','address','uint24','address'],[cash,c.fee1,c.mid,c.fee2,c.token]);
export default {
 slug:'hedgerow',vercel:'hedgerowbot',assets:['TOKENS','BDEX','QUOTER'],name:'Hedgerow',repo:'hedgerow',contract:'HedgeFactory',color:'#ccff00',eyebrow:'HEDGE DAO',symbol:'H',
 line:'Pick a basket. Fund it together.',
 app:{title:'Basket factsheets',line:'Back a raise, join a live basket, or design your own.',layout:'sheet'},
 description:'Creators design a token basket, the community funds it in BOT, and holders steer it onchain. A hedge DAO on BOT Chain.',
 abis:['HedgeFactory','HedgeVault'],
 contracts:['src/hedge/HedgeFactory.sol','src/hedge/HedgeVault.sol','src/interfaces/IBotV3Router.sol'],tests:['test/Hedgerow.t.sol'],
 landing:{
  steps:[['Design a basket','Pick up to five BDEX-traded tokens and their weights, a BOT goal, a raise window, fees and how the basket is governed.'],['Raise, then trade','Backers deposit BOT. When the goal is met the creator buys the whole basket in one go; a missed goal refunds everyone.'],['Hold, steer, exit','Shares track your slice of every token. Late joiners pay a higher fee, holders vote on changes, and anyone redeems after the lockup.']],
  features:[['Three governance modes','Fixed baskets never change, managed baskets rebalance behind a 24-hour timelock, DAO baskets change only by holder vote.'],['Manipulation-resistant shares','Shares are priced from the vault\'s own holdings, never from DEX prices, so pumping a pool cannot mint extra shares.'],['Refunds built in','Missed goals and unfinalized raises return every BOT. Raise fees are only charged when the basket launches.'],['Exit your way','Redeem in kind for your slice of each token, or sell it back to WBOT with your own minimum output.']],
  faq:[['Why BOT, not USDT?','Baskets raise in BOT so anyone holding BOT can join without swapping first. The app wraps native BOT to WBOT for you; redemptions pay out in WBOT, which you can unwrap in one click. Basket values move with BOT\'s price.'],['Which tokens can a basket hold?','Any token with a BDEX route from WBOT, directly or through one hop. Today that means WBOT, USDT, CaryPact (CA) and FlowBridge (FLOW). New BDEX listings become available automatically.'],['What do creators earn?','A raise fee of up to 2% when the basket launches, and a late-entry fee of up to 5% that is never lower than the raise fee.'],['How does DAO voting work?','Holders vote with their shares as of the proposal. A change passes with a majority and at least 20% of all shares voting for it, then the creator executes it within seven days.'],['What are the risks?','Basket tokens can lose value, thin pools move on large trades, and the creator sets minimum outputs when buying. The contracts are unaudited; start small.']],
 },
 tokens:tokenLists,
 async deploy({deploy,i}){await deploy('HedgeFactory',[i.WBOT,i.router]);},
 async fork({c,abi,i,tx,write,read,owner,artifact,net}){
  const tokens=tokenLists[net],cash=i.WBOT,isCash=t=>t.toLowerCase()===cash.toLowerCase();
  const vaultAbi=artifact('HedgeVault').abi;const v=(fn,args=[],value=0n,address)=>tx(vaultAbi,address,fn,args,value);
  const quote=async(cmp,n)=>isCash(cmp.token)?0n:(await c.simulateContract({address:i.quoter,abi:quoter,functionName:'quoteExactInput',args:[path(cash,cmp),n]})).result[0]*97n/100n;
  const basket=[component(tokens[0],5000),component(tokens[1],2500),component(tokens[2],1500),component(tokens[3],1000)];
  const mins=async net=>Promise.all(basket.map(cmp=>quote(cmp,net*BigInt(cmp.weightBps)/10000n)));
  await tx(abi,cash,'deposit',[],parseEther('20'));const now=BigInt((await c.getBlock()).timestamp);
  await write('HedgeFactory','createVault',[{creator:owner.address,name:'Fork Basket',symbol:'FORK',mode:2,goal:parseEther('4'),raiseEnd:now+7200n,lockup:0n,raiseFeeBps:100,lateFeeBps:300,components:basket}]);
  const vault=await read('HedgeFactory','vaults',[await read('HedgeFactory','vaultCount')-1n]);
  assert.equal(await c.readContract({address:vault,abi:vaultAbi,functionName:'decimals'}),18);
  await tx(abi,cash,'approve',[vault,parseEther('20')]);await v('deposit',[parseEther('5')],0n,vault);
  await v('finalize',[await mins(parseEther('4.95')),now+3600n],0n,vault);await v('claimShares',[],0n,vault);
  const held=await c.readContract({address:vault,abi:vaultAbi,functionName:'holdings'});
  for(const [n,t] of held[0].entries())assert(held[1][n]>0n,`no ${t}`);
  await v('join',[parseEther('2'),await mins(parseEther('1.94')),now+3600n],0n,vault);
  const shares=await c.readContract({address:vault,abi:vaultAbi,functionName:'balanceOf',args:[owner.address]});
  // DAO: move the basket to WBOT + USDT by vote.
  const next=[component(tokens[0],7000),component(tokens[1],3000)];
  await c.request({method:'anvil_mine',params:['0x1']});await v('propose',[next],0n,vault);await v('vote',[0n,true],0n,vault);
  await c.request({method:'evm_increaseTime',params:[48*3600+1]});await c.request({method:'evm_mine',params:[]});
  const after=BigInt((await c.getBlock()).timestamp);
  const sellMins=basket.map(cmp=>isCash(cmp.token)?0n:1n);
  await v('execute',[0n,sellMins,[0n,1n],after+3600n],0n,vault);
  await v('redeem',[shares/2n],0n,vault);
  const before=await c.readContract({address:cash,abi,functionName:'balanceOf',args:[owner.address]});
  await v('redeemToCash',[shares-shares/2n,[0n,1n],1n,after+3600n],0n,vault);
  const got=await c.readContract({address:cash,abi,functionName:'balanceOf',args:[owner.address]})-before;assert(got>0n);
  return {vault,shares:String(shares),wbotFromRedeem:String(got),flow:'create → raise in WBOT → finalize (USDT, CA, FLOW via USDT) → claim → late join → DAO vote → rebalance → redeem in kind → redeem to WBOT'};
 },
};
