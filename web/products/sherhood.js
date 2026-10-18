import {$,config,state as session,esc,fmt,link,short,button,field,form,details,amount,read,tx,approve,approveNFT,mine,start} from '../core.js';
function controls(){
 $('list-title').textContent='Pools & collectibles';
 $('controls').innerHTML='<h2>Create a Sherd</h2>'+form('instant',field('instant-amount','USDT amount','5','text','inputmode="decimal"'),'Create instant pool',async f=>tx('PotFactoryV2','createInstantPot',[amount(f['instant-amount'],6)]))+'<p class="tiny">5–1,000 USDT. Create first, then deposit into your pool below.</p>'+details('Create a community pool',form('community',field('goal','Funding goal (USDT)','100','text','inputmode="decimal"')+field('hours','Funding window (hours)','24','number','min="1" max="8760"')+field('minimum','Minimum deposit (USDT)','1','text','inputmode="decimal"'),'Create pool',async f=>tx('PotFactoryV2','createCommunityPot',[amount(f.goal,6),BigInt(Number(f.hours)*3600),amount(f.minimum,6),0n,100n])));
 $('rules').innerHTML='<ul><li>This BOT Chain edition buys WBOT with USDT. It does not provide Robinhood stock tokens.</li><li>Your deposit mints a collectible. Once funded, the protocol operator purchases WBOT and requests the reveal.</li><li>The reveal uses fixed future block entropy, not a VRF. Community shares vary with the reveal; a solo pool owns its entire allocation.</li><li>Revealed card holders can claim WBOT or list their card for USDT. A claimed card has no remaining asset entitlement.</li><li>Underfunded pools can be cancelled after their deadline; card holders then claim refunds. Community pools charge a 1% purchase fee; instant pools charge 0%.</li></ul>';
}
async function render(){
 const count=Number(await read('PotFactoryV2','potCount'));let html='';
 for(let id=count-1;id>=Math.max(0,count-20);id--){const addr=await read('PotFactoryV2','pots',[BigInt(id)]),get=(fn,args=[])=>read('PotV2',fn,args,addr);const [state,goal,total,deadline,min,solo]=await Promise.all([get('status'),get('fundingGoal'),get('totalDeposited'),get('deadline'),get('minDeposit'),get('instantMinter')]);
  html+=`<article class="item"><div class="section-head"><h3>Pool #${id+1}</h3><span class="badge">${['Funding','Awaiting purchase','Awaiting reveal','Revealed','Cancelled'][state]}</span></div><div class="amount">${fmt(total,6)} / ${fmt(goal,6)} USDT</div><p class="tiny">${link(addr)} · Deadline ${new Date(Number(deadline)*1000).toLocaleString()}</p>`;
  const restricted=solo!=='0x0000000000000000000000000000000000000000';
  if(state===0&&Date.now()<Number(deadline)*1000&&(!restricted||!session.account||mine(solo)))html+=form(`deposit-${id}`,field(`deposit-amount-${id}`,'Deposit (USDT)',fmt(restricted?goal:min,6),'text','inputmode="decimal"'),'Approve & deposit',async f=>{const n=amount(f[`deposit-amount-${id}`],6);await approve(config.infrastructure.USDT,addr,n);await tx('PotV2','deposit',[n],0n,addr);});
  if(state===0&&Date.now()>=Number(deadline)*1000)html+=button('Cancel underfunded pool',()=>tx('PotV2','cancel',[],0n,addr));
  const ids=await read('PotCard','potTokenIds',[addr]);
  for(const cardId of ids.slice(-30)){const [data,owner]=await Promise.all([read('PotCard','getCard',[cardId]),read('PotCard','ownerOf',[cardId])]);html+=`<div class="row"><span>Sherd #${cardId} · ${esc(short(owner))}</span><strong>${data.claimed?'Claimed':data.revealed?`${fmt(data.ownershipWeight*100n)}% share`:'Unrevealed'}</strong></div>`;
   if(mine(owner)&&!data.claimed){
    if(state===4)html+=button('Claim USDT refund',()=>tx('PotV2','refund',[cardId],0n,addr),true);
    if(state===3)html+=button('Claim WBOT',()=>tx('PotV2','claim',[cardId],0n,addr),true);
    html+=details('List this Sherd for USDT',form(`list-${cardId}`,field(`price-${cardId}`,'Price (USDT)','5','text','inputmode="decimal"'),'Approve & list',async f=>{await approveNFT(config.contracts.PotCard,cardId,config.contracts.CardMarketplace);await tx('CardMarketplace','list',[cardId,amount(f[`price-${cardId}`],6)]);}));
   }
  }html+='</article>';
 }
 const [ids,items]=await read('CardMarketplace','getActiveListings');
 html+='<h3>Collectible market</h3>';
 for(let j=0;j<Math.min(ids.length,30);j++){const id=ids[j],item=items[j];html+=`<div class="item"><h3>Sherd #${id} · ${fmt(item.price,6)} USDT</h3>${mine(item.seller)?button('Cancel listing',()=>tx('CardMarketplace','cancel',[id])):button('Buy Sherd',async()=>{await approve(config.infrastructure.USDT,config.contracts.CardMarketplace,item.price);await tx('CardMarketplace','buy',[id]);},true)}</div>`;}
 if(!count)html='<p class="empty">No pools yet. Create an instant or community pool.</p>'+html;if(!ids.length)html+='<p class="tiny">No collectibles listed.</p>';return html;
}
start({controls,render});
