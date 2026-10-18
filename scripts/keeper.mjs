import fs from 'node:fs';
import {createWalletClient,http,parseAbi,parseEther} from 'viem';
import {privateKeyToAccount} from 'viem/accounts';
import {chain,rpc,local,publicClient as c,artifact,readJournal,infrastructure as i} from './config.mjs';
// One bounded tick. Run manually after inspecting pools; no background spending is enabled.
const journal=readJournal();if(!journal?.ready)throw Error('Deploy contracts first');
if(await c.getChainId()!==677)throw Error('Wrong chain');
if(!local&&!process.env.BOT_KEEPER_MAX_GAS_BOT)throw Error('Provide an explicit per-run BOT_KEEPER_MAX_GAS_BOT');
const limit=parseEther(local?'1':process.env.BOT_KEEPER_MAX_GAS_BOT);let spent=0n;
const key=fs.readFileSync(process.env.BOT_SIGNER_FILE||`${process.env.HOME}/.config/botchain-wave1/deployer.env`,'utf8').match(/^DEPLOYER_PRIVATE_KEY=(.*)$/m)?.[1];
const account=privateKeyToAccount(key),wallet=createWalletClient({account,chain,transport:http(rpc)}),contracts=journal.contracts;
const read=(name,fn,args=[],address=contracts[name])=>c.readContract({address,abi:artifact(name).abi,functionName:fn,args});
async function write(name,fn,args=[]){
 const params={address:contracts[name],abi:artifact(name).abi,functionName:fn,args,account};const {request}=await c.simulateContract(params);
 const gas=await c.estimateContractGas(params),gasPrice=await c.getGasPrice(),maxCost=gas*120n/100n*gasPrice;
 if(spent+maxCost>limit)throw Error('Keeper run gas budget reached');
 const hash=await wallet.writeContract({...request,gas:gas*120n/100n,gasPrice});const receipt=await c.waitForTransactionReceipt({hash});
 spent+=receipt.gasUsed*receipt.effectiveGasPrice;if(receipt.status!=='success')throw Error(`Keeper transaction reverted ${hash}`);console.log(fn,hash);
}
const count=await read('PotFactoryV2','potCount');
const quoterAbi=parseAbi(['function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96) params) returns(uint256 amountOut,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)']);
for(let index=count>20n?count-20n:0n;index<count;index++){
 const pot=await read('PotFactoryV2','pots',[index]);const state=await read('PotV2','status',[],pot);
 if(state===1){
  const commit=await read('AssetManager','purchaseCommitBlock',[pot]),block=await c.getBlockNumber();
  if(commit===0n||block>commit+256n){await write('AssetManager','commitPurchase',[pot]);continue;}
  if(block<=commit+await read('AssetManager','purchaseDelayBlocks'))continue;
  const total=await read('PotV2','totalDeposited',[],pot),fee=await read('PotV2','protocolFeeOwed',[],pot);
  const {result}=await c.simulateContract({address:i.quoter,abi:quoterAbi,functionName:'quoteExactInputSingle',args:[{tokenIn:i.USDT,tokenOut:i.WBOT,amountIn:total-fee,fee:i.fee,sqrtPriceLimitX96:0n}]});
  const minimum=result[0]*99n/100n;if(minimum===0n)throw Error('Zero swap quote');await write('AssetManager','purchase',[pot,1n,[minimum]]);
 }else if(state===2){
  const requested=await read('RevealEngine','revealRequested',[pot]);
  if(!requested){await write('RevealEngine','requestReveal',[pot]);continue;}
  const id=await read('RevealEngine','potRequestId',[pot]),target=await read('BotEntropy','targetBlock',[id]),block=await c.getBlockNumber();
  if(block>target+256n)await write('BotEntropy','reschedule',[id]);else if(block>target)await write('BotEntropy','fulfill',[id]);
 }
}
console.log('Keeper tick complete; gas spent (wei):',spent.toString());
