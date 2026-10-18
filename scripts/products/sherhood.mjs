import fs from 'node:fs';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
export default {
 slug:'sherhood',name:'Sherhood',repo:'sherhood-botchain',contract:'PotFactoryV2',color:'#ccff00',eyebrow:'COLLECTIBLE POOLS',symbol:'S',
 line:'Pool USDT. Collect your share of BOT.',
 description:'The Sherhood pool and collectible protocol, adapted to USDT and wrapped BOT on BOT Chain.',
 abis:['PotFactoryV2','PotV2','PotCard','CardMarketplace'],
 contracts:['src/SherhoodImports.sol','src/BotSwapAdapter.sol','src/BotEntropy.sol','src/interfaces/IBotV3Router.sol','sherhood-src'],tests:['test/Sherhood.t.sol'],
 scripts:['keeper.mjs'],
 landing:{
  steps:[['Join a pool','Deposit USDT into an instant solo pool or a community pool with a funding goal.'],['Mint a Sherd','Every deposit mints a collectible card. When the pool fills, its USDT buys WBOT on BDEX.'],['Reveal and claim','Block entropy reveals each card\'s share. Claim your WBOT or sell the card for USDT.']],
  features:[['Real onchain assets','Pools buy WBOT through the live BDEX USDT/WBOT pool.'],['Collectible cards','Each Sherd is an NFT that carries its share of the pool until claimed.'],['Built-in market','List or buy revealed Sherds for USDT in the card marketplace.'],['Protected principal','Underfunded pools can be cancelled after their deadline for a full USDT refund.']],
  faq:[['What do I actually own?','A Sherd card whose revealed share entitles you to part of the pool\'s WBOT until you claim it.'],['How are shares decided?','In community pools a reveal using future block entropy sets each share. Solo pools own the entire allocation.'],['What are the fees?','Instant pools charge 0%. Community pools charge a 1% purchase fee.'],['Is this the Robinhood Chain Sherhood?','It is the same protocol, adapted to BOT Chain: USDT in, WBOT out, no stock tokens.']],
 },
 async deploy({deploy,configure,account,i}){
  const swap=await deploy('BotSwapAdapter',[i.router]);const entropy=await deploy('BotEntropy');
  const treasury=await deploy('TreasuryDirect',[i.USDT,account.address,account.address]);const card=await deploy('PotCard',[account.address]);
  const factory=await deploy('PotFactoryV2',[account.address,i.USDT,card]);const reveal=await deploy('RevealEngine',[account.address,card,entropy]);
  const assets=await deploy('AssetManager',[account.address,i.USDT,swap]);const registry=await deploy('StockTokenRegistry',[account.address]);
  const market=await deploy('CardMarketplace',[account.address,card,i.USDT,treasury]);
  for(const [fn,args] of [['setMinter',[factory]],['setRevealer',[reveal]],['setCardMarketplace',[market]]])await configure('PotCard',fn,args);
  for(const [fn,args] of [['setAssetManager',[assets]],['setRevealEngine',[reveal]],['setTreasury',[treasury]],['setStockRegistry',[registry]],['setCreationFee',[0n]]])await configure('PotFactoryV2',fn,args);
  await configure('AssetManager','setStockRegistry',[registry]);await configure('AssetManager','setPickBounds',[1n,1n,1n]);await configure('AssetManager','setSeededPurchaseEnabled',[false]);
  await configure('StockTokenRegistry','setToken',[i.WBOT,true,'WBOT',i.fee]);
  await configure('RevealEngine','setVRFConfig',['0x'+('1'.padStart(64,'0')),1n,2500000]);
 },
 async fork({c,abi,i,tx,write,read,owner,fundUSDT,rpc}){
  await fundUSDT(10000000n);
  await write('PotFactoryV2','createInstantPot',[5000000n]);const pot=await read('PotFactoryV2','pots',[await read('PotFactoryV2','potCount')-1n]);
  await tx(abi,i.USDT,'approve',[pot,5000000n]);await write('PotV2','deposit',[5000000n],0n,pot);assert.equal(await read('PotV2','status',[],pot),1);
  const keeper=fileURLToPath(new URL('../keeper.mjs',import.meta.url));
  const tick=()=>{const r=spawnSync('node',[keeper],{env:{...process.env,BOT_RPC_URL:rpc},encoding:'utf8'});if(r.status!==0)throw Error(r.stderr||r.stdout);console.log(r.stdout.trim());};
  tick();await c.request({method:'anvil_mine',params:['0x4']});tick();assert.equal(await read('PotV2','status',[],pot),2);
  tick();await c.request({method:'anvil_mine',params:['0x7']});tick();assert.equal(await read('PotV2','status',[],pot),3);
  const ids=await read('PotCard','potTokenIds',[pot]),before=await c.readContract({address:i.WBOT,abi,functionName:'balanceOf',args:[owner.address]});
  await write('PotV2','claim',[ids[0]],0n,pot);const after=await c.readContract({address:i.WBOT,abi,functionName:'balanceOf',args:[owner.address]});assert(after>before);
  return {pool:pot,card:String(ids[0]),claimedWBOT:String(after-before),flow:'create → USDT deposit → real BDEX swap → reveal → WBOT claim'};
 },
};
