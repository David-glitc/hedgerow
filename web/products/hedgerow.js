import {parseAbi,encodePacked} from 'viem';
import {$,config,state,client,esc,fmt,link,short,button,field,form,details,amount,read,tx,approve,mine,wallet,connect,asset,start} from '../core.js';
const ZERO='0x0000000000000000000000000000000000000000',USDT=config.infrastructure.USDT;
const quoterAbi=parseAbi(['function quoteExactInput(bytes path,uint256 amountIn) returns(uint256 amountOut,uint160[],uint32[],uint256)']);
const symAbi=parseAbi(['function symbol() view returns(string)','function decimals() view returns(uint8)']);
const MODES=['Fixed','Managed','DAO'],PHASES=['Raising','Active','Refunding'];
const known=Object.fromEntries(config.tokens.map(t=>[t.address.toLowerCase(),t]));
const meta={};
async function tokenMeta(a){const k=a.toLowerCase();if(known[k])return known[k];if(meta[k])return meta[k];
 try{const [symbol,decimals]=await Promise.all([client.readContract({address:a,abi:symAbi,functionName:'symbol'}),client.readContract({address:a,abi:symAbi,functionName:'decimals'})]);meta[k]={symbol,decimals};}catch{meta[k]={symbol:short(a),decimals:18};}return meta[k];}
const trim=v=>{const [a,b='']=v.split('.');return b?`${a}.${b.slice(0,6).replace(/0+$/,'')||'0'}`.replace(/\.$/,''):a;};
const pct=bps=>`${(Number(bps)/100).toFixed(Number(bps)%100?2:0)}%`;
const isCash=a=>a.toLowerCase()===USDT.toLowerCase();
const path=(c,sell)=>{const p=c.mid===ZERO?[[c.token],[c.fee1]]:[[c.mid,c.token],[c.fee1,c.fee2]];
 const hops=[USDT,...p[0]],fees=p[1];if(sell){hops.reverse();fees.reverse();}
 const types=[],values=[];hops.forEach((h,n)=>{types.push('address');values.push(h);if(n<fees.length){types.push('uint24');values.push(fees[n]);}});return encodePacked(types,values);};
async function quote(c,n,sell=false){if(isCash(c.token)||n===0n)return 0n;const {result}=await client.simulateContract({address:config.infrastructure.quoter,abi:quoterAbi,functionName:'quoteExactInput',args:[path(c,sell),n]});return result[0];}
function slippage(v){if(!/^\d+(\.\d{1,2})?$/.test(v)||Number(v)<0.1||Number(v)>10)throw Error('Use a slippage between 0.1% and 10%.');return BigInt(Math.round(Number(v)*100));}
const floor=(q,slip)=>q*(10000n-slip)/10000n;
async function buyMins(comps,net,slip){return Promise.all(comps.map(async c=>{if(isCash(c.token))return 0n;const q=floor(await quote(c,net*BigInt(c.weightBps)/10000n),slip);if(q===0n)throw Error('A basket leg quotes to zero. Increase the amount.');return q;}));}
// Chain time, not the device clock: a skewed clock must not break deadlines or phase checks.
let chainNow=Math.floor(Date.now()/1000);
async function syncClock(){chainNow=Number((await client.getBlock()).timestamp);return chainNow;}
const deadline=()=>BigInt(chainNow+900);
const vaultTx=(addr,fn,args=[])=>tx('HedgeVault',fn,args,0n,addr);
const vread=(addr,fn,args=[])=>read('HedgeVault',fn,args,addr);
// 50/15/10 across the first three non-cash tokens and 25% cash, whatever this network lists.
function defaultWeights(){const w={},split=[50,15,10];let n=0;for(const t of config.tokens)w[t.symbol]=t.cash?25:(split[n++]??0);return w;}
function weightFields(prefix,defaults={}){return '<fieldset class="weights"><legend>Basket weights (%) · must total 100</legend><div class="weight-grid">'+config.tokens.map(t=>`<div>${field(`${prefix}-w-${t.symbol}`,`${t.symbol}${t.cash?' · cash':''}`,String(defaults[t.symbol]??0),'text','inputmode="decimal"')}</div>`).join('')+`</div><div class="alloc" id="${prefix}-bar" aria-hidden="true"></div><p class="tiny" id="${prefix}-total" aria-live="polite"></p></fieldset>`;}
function basketFrom(f,prefix){const comps=[];let total=0;
 for(const t of config.tokens){const raw=f[`${prefix}-w-${t.symbol}`]||'0';if(!/^\d+(\.\d{1,2})?$/.test(raw))throw Error(`Use a number for the ${t.symbol} weight.`);const bps=Math.round(Number(raw)*100);if(!bps)continue;if(bps<500)throw Error(`${t.symbol}: each token needs at least 5%.`);total+=bps;comps.push({token:t.address,weightBps:bps,mid:t.mid||ZERO,fee1:t.fee1||0,fee2:t.fee2||0});}
 if(!comps.length||comps.length>5)throw Error('Pick between one and five tokens.');if(total!==10000)throw Error(`Weights total ${total/100}%. They must total exactly 100%.`);return comps;}
function watchTotal(formId,prefix){const f=document.querySelector(`[data-form="${formId}"]`);if(!f)return;const upd=()=>{let t=0;for(const x of config.tokens)t+=Number(f.querySelector(`[name="${prefix}-w-${x.symbol}"]`)?.value||0);const el=$(`${prefix}-total`);if(el){el.textContent=Math.abs(t-100)>1e-9?`Total ${t}%: adjust to exactly 100%.`:'Total 100%.';el.classList.toggle('error',Math.abs(t-100)>1e-9);}
  const bar=$(`${prefix}-bar`);if(bar)bar.innerHTML=config.tokens.map(x=>Number(f.querySelector(`[name="${prefix}-w-${x.symbol}"]`)?.value||0)).filter(v=>v>0).map(v=>`<i style="flex:${v}"></i>`).join('');};f.addEventListener('input',upd);upd();}

function controls(){
 $('list-title').textContent='Baskets';
 $('controls').innerHTML='<h2>Design a basket</h2><p>Pick up to five tokens and weights. Backers fund it in USDT; if the goal is missed, everyone refunds.</p>'+form('create',`<div class="two"><div>${field('name','Basket name','BOT Chain Core','text','maxlength="48"')}</div><div>${field('symbol','Share symbol','CORE','text','maxlength="12"')}</div></div>`+weightFields('c',defaultWeights())
  +`<label for="mode">Governance</label><select id="mode" name="mode"><option value="2">DAO — holders vote on changes</option><option value="1">Managed — you rebalance after a 24h timelock</option><option value="0">Fixed — the basket never changes</option></select>`
  +field('goal','Raise goal (USDT)','100','text','inputmode="decimal"')+`<div class="two"><div>${field('days','Raise window (days)','7','number','min="1" max="30"')}</div><div>${field('lockup','Lockup (days)','7','number','min="0" max="90"')}</div></div><div class="two"><div>${field('raise-fee','Raise fee (%, ≤ 2)','0.5','text','inputmode="decimal"')}</div><div>${field('late-fee','Late fee (%, ≤ 5)','2','text','inputmode="decimal"')}</div></div>`,'Create basket',async f=>{
   const comps=basketFrom(f,'c'),bps=v=>{if(!/^\d+(\.\d{1,2})?$/.test(v))throw Error('Fees must be percentages.');return Math.round(Number(v)*100);};
   const days=Number(f.days),lock=Number(f.lockup);if(!(days>=1&&days<=30))throw Error('Raise window must be 1–30 days.');if(!(lock>=0&&lock<=90))throw Error('Lockup must be 0–90 days.');
   const raiseFee=bps(f['raise-fee']),lateFee=bps(f['late-fee']);if(raiseFee>200||lateFee>500||lateFee<raiseFee)throw Error('Raise fee ≤ 2%, late fee ≤ 5% and at least the raise fee.');
   await wallet();await tx('HedgeFactory','createVault',[{creator:state.account,name:f.name.trim(),symbol:f.symbol.trim().toUpperCase(),mode:Number(f.mode),goal:amount(f.goal,6),raiseEnd:BigInt(await syncClock()+days*86400),lockup:BigInt(lock*86400),raiseFeeBps:raiseFee,lateFeeBps:lateFee,components:comps}]);
  })+'<p class="tiny">Tokens listed have live BDEX routes from USDT. CA routes through WBOT. Thin pools move on large trades: check quotes before you finalize.</p>';
 watchTotal('create','c');
 $('rules').innerHTML='<ul><li>Backers deposit USDT during the raise. If the goal is missed, or the creator does not finalize within 3 days after the raise ends, everyone refunds in full.</li><li>When the creator finalizes, the raise fee goes to the creator and the rest buys the basket at its weights through BDEX.</li><li>After launch anyone can join at the late-entry fee. Shares are minted from the smallest relative increase in any holding, so pool manipulation cannot mint extra shares.</li><li>After the lockup, redeem in kind or sell your slice back to USDT with a minimum output.</li><li>Managed baskets change after a 24h timelock; DAO baskets need a majority and 20% of all shares voting for. The creator executes approved changes and sets the minimum outputs.</li><li>Contracts are unaudited. Basket tokens can lose value.</li></ul>';
}

async function card(id){
 const addr=await read('HedgeFactory','vaults',[BigInt(id)]),g=fn=>vread(addr,fn);
 const [name,symbol,mode,phase,goal,raiseEnd,raised,comps,holdings,supply,creator,lockupEnd,raiseFee,lateFee,refundable,canRedeem,count]=await Promise.all(['name','symbol','mode','phase','goal','raiseEnd','raised','components','holdings','effectiveSupply','creator','lockupEnd','raiseFeeBps','lateFeeBps','refundable','canRedeem','proposalCount'].map(g));
 const metas=await Promise.all(comps.map(c=>tokenMeta(c.token)));const own=mine(creator),now=chainNow,f=`v${id}`;
 const shownPhase=refundable?2:phase;
 const pctRaised=goal>0n?Math.min(100,Number(raised*1000n/goal)/10):0,when=t=>new Date(Number(t)*1000).toLocaleDateString(undefined,{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'});
 tally.count++;if(shownPhase===0)tally.raising++;if(shownPhase===1)tally.live++;tally.raised+=raised;
 let html=`<article class="sheet"><div class="sheet-head"><div><h3>${esc(name)}</h3><span class="tiny">${esc(symbol)} · by ${link(creator)} · ${link(addr,'vault')}</span></div><div class="badges"><span class="badge${shownPhase===1?' live':''}">${PHASES[shownPhase]}</span><span class="badge">${MODES[mode]}</span></div></div>`;
 html+=`<div class="alloc" aria-hidden="true">${comps.map(c=>`<i style="flex:${c.weightBps}"></i>`).join('')}</div><ul class="legend" aria-label="Allocation">${comps.map((c,n)=>`<li>${asset(metas[n].symbol,c.token)} <b>${pct(c.weightBps)}</b></li>`).join('')}</ul>`;
 const figs=phase===0?[['Raised',`${trim(fmt(raised,6))} USDT`],['Goal',`${trim(fmt(goal,6))} USDT`],['Raise ends',when(raiseEnd)],['Fees',`${pct(raiseFee)} raise · ${pct(lateFee)} late`]]
  :[['Shares',trim(fmt(supply,6))],['Late-entry fee',pct(lateFee)],['Redeem',Number(lockupEnd)>now?`from ${when(lockupEnd)}`:'Open now'],['Raised',`${trim(fmt(raised,6))} USDT`]];
 html+=`<dl class="figs">${figs.map(([k,v])=>`<div><dt>${k}</dt><dd>${v}</dd></div>`).join('')}</dl>`;
 if(phase===0)html+=`<div class="meter" role="progressbar" aria-label="Raise progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pctRaised}"><i style="width:${pctRaised}%"></i></div><p class="tiny">${pctRaised}% of goal${refundable?' · goal missed: backers can refund':''}</p>`;
 if(phase===1){const hm=await Promise.all(holdings[0].map(tokenMeta));html+='<h4 class="sub">Holdings</h4><div class="holdings">'+holdings[0].map((t,n)=>`<div class="row"><span>${asset(hm[n].symbol,t)}</span><strong class="mono">${trim(fmt(holdings[1][n],hm[n].decimals))}</strong></div>`).join('')+'</div>';}
 const slipField=k=>field(`${f}-${k}-slip`,'Max slippage (%)','2','text','inputmode="decimal"');
 if(!state.account&&(phase===1||(phase===0&&!refundable&&now<Number(raiseEnd))))html+=`<div class="actions">${button(phase===0?'Connect to back this basket':'Connect to join this basket',connect,true)}</div>`;
 if(state.account){
  const [dep,claim,shares,votes]=await Promise.all([vread(addr,'deposits',[state.account]),vread(addr,'claimable',[state.account]),vread(addr,'balanceOf',[state.account]),vread(addr,'getVotes',[state.account])]);
  if(dep>0n||shares>0n)html+=`<p class="you">You: ${dep>0n?`${trim(fmt(dep,6))} USDT deposited`:''}${dep>0n&&shares>0n?' · ':''}${shares>0n?`${trim(fmt(shares,6))} shares (${supply>0n?(Number(shares*10000n/supply)/100).toFixed(2):0}%) · ${trim(fmt(votes,6))} votes`:''}</p>`;
  const acts=[];
  if(phase===0&&!refundable&&now<Number(raiseEnd))html+=details('Back this basket',form(`${f}-dep`,field(`${f}-dep-amt`,'Deposit (USDT)','10','text','inputmode="decimal"'),'Approve & deposit',async x=>{const n=amount(x[`${f}-dep-amt`],6);await approve(USDT,addr,n);await vaultTx(addr,'deposit',[n]);}));
  if(refundable&&dep>0n)acts.push(button(`Refund ${trim(fmt(dep,6))} USDT`,()=>vaultTx(addr,'refund'),true));
  if(phase===0&&own&&raised>=goal&&!refundable)html+=details('Finalize: buy the basket',form(`${f}-fin`,slipField('fin'),'Finalize raise',async x=>{const net=raised-raised*BigInt(raiseFee)/10000n;await syncClock();await vaultTx(addr,'finalize',[await buyMins(comps,net,slippage(x[`${f}-fin-slip`])),deadline()]);}));
  if(claim>0n)acts.push(button(`Claim ${trim(fmt(claim,6))} shares`,()=>vaultTx(addr,'claimShares'),true));
  if(phase===1)html+=details(`Join at the ${pct(lateFee)} late fee`,form(`${f}-join`,field(`${f}-join-amt`,'Join with (USDT)','10','text','inputmode="decimal"')+slipField('join'),'Approve & join',async x=>{const n=amount(x[`${f}-join-amt`],6);const mins=await buyMins(comps,n-n*BigInt(lateFee)/10000n,slippage(x[`${f}-join-slip`]));await approve(USDT,addr,n);await syncClock();await vaultTx(addr,'join',[n,mins,deadline()]);}));
  if(canRedeem&&shares>0n){
   html+=details('Redeem',form(`${f}-red`,field(`${f}-red-amt`,'Shares',trim(fmt(shares,6)),'text','inputmode="decimal"'),'Redeem in kind',async x=>vaultTx(addr,'redeem',[amount(x[`${f}-red-amt`],6)]))
    +form(`${f}-redu`,field(`${f}-redu-amt`,'Shares',trim(fmt(shares,6)),'text','inputmode="decimal"')+slipField('redu'),'Sell slice for USDT',async x=>{const s=amount(x[`${f}-redu-amt`],6),slip=slippage(x[`${f}-redu-slip`]);let total=0n;
     const mins=await Promise.all(comps.map(async(c,n)=>{const part=holdings[1][n]*s/supply;if(isCash(c.token)){total+=part;return 0n;}const q=floor(await quote(c,part,true),slip);total+=q;return q>0n?q:1n;}));
     if(holdings[0].length>comps.length)total+=holdings[1][comps.length]*s/supply;await syncClock();await vaultTx(addr,'redeemToUSDT',[s,mins,total,deadline()]);}));
  }
  if(phase===1&&mode>0&&(own||(mode===2&&votes*100n>=supply))&&(mode===2||Number(lockupEnd)<=now))html+=details(mode===2?'Propose a new basket':'Schedule a rebalance',form(`${f}-prop`,weightFields(`${f}p`),mode===2?'Submit proposal':'Schedule (24h timelock)',async x=>vaultTx(addr,'propose',[basketFrom(x,`${f}p`)])));
  if(acts.length)html+=`<div class="actions">${acts.join('')}</div>`;
 }
 if(count>0n){html+='<h4 class="sub">Proposals</h4>';
  for(let p=Number(count)-1;p>=Math.max(0,Number(count)-5);p--){const [[pr,next],ok,voted]=await Promise.all([vread(addr,'proposal',[BigInt(p)]),vread(addr,'passed',[BigInt(p)]),state.account?vread(addr,'hasVoted',[BigInt(p),state.account]):false]);
   const nm=await Promise.all(next.map(c=>tokenMeta(c.token))),open=now<Number(pr.end);
   html+=`<div class="item"><div class="row"><span>#${p} · ${next.map((c,n)=>`${asset(nm[n].symbol,c.token)} ${pct(c.weightBps)}`).join(' · ')}</span><strong>${pr.executed?'Executed':open?(mode===2?'Voting':'Timelocked'):ok?'Ready':'Closed'}</strong></div>`;
   if(mode===2)html+=`<p class="tiny">For ${trim(fmt(pr.forVotes,6))} · Against ${trim(fmt(pr.againstVotes,6))} · Quorum ${trim(fmt(pr.quorumBase*2000n/10000n,6))} · ${open?`ends ${new Date(Number(pr.end)*1000).toLocaleString()}`:'ended'}</p>`;
   const pa=[];if(mode===2&&open&&state.account&&!voted)pa.push(button('Vote for',()=>vaultTx(addr,'vote',[BigInt(p),true]),true),button('Vote against',()=>vaultTx(addr,'vote',[BigInt(p),false])));
   if(ok&&own)html+=details('Execute this change',form(`${f}-ex${p}`,slipField(`ex${p}`),'Rebalance now',async x=>{const slip=slippage(x[`${f}-ex${p}-slip`]);let cash=holdings[0].length>comps.length?holdings[1][comps.length]:0n;
    const sells=await Promise.all(comps.map(async(c,n)=>{if(isCash(c.token)){cash+=holdings[1][n];return 0n;}const q=floor(await quote(c,holdings[1][n],true),slip);cash+=q;return q>0n?q:1n;}));
    await syncClock();await vaultTx(addr,'execute',[BigInt(p),sells,await buyMins(next,floor(cash,slip),slip),deadline()]);}));
   if(pa.length)html+=`<div class="actions">${pa.join('')}</div>`;html+='</div>';}
 }
 return html+'</article>';
}
const tally={count:0,raising:0,live:0,raised:0n};
async function render(){
 await syncClock();const count=Number(await read('HedgeFactory','vaultCount'));Object.assign(tally,{count:0,raising:0,live:0,raised:0n});
 const ids=[];for(let id=count-1;id>=Math.max(0,count-12);id--)ids.push(id);
 let html=(await Promise.all(ids.map(card))).join('');html=html&&`<div class="sheets">${html}</div>`;
 setTimeout(()=>{for(let id=count-1;id>=Math.max(0,count-12);id--)watchTotal(`v${id}-prop`,`v${id}p`);},0);
 return html||'<p class="empty">No baskets yet. Design the first one.</p>';
}
function stats(empty){return [['Baskets',empty?'—':String(tally.count)],['Raising',empty?'—':String(tally.raising)],['Raised',empty?'—':`$${Number(fmt(tally.raised,6)).toLocaleString(undefined,{maximumFractionDigits:2})}`]];}
start({controls,render,stats});
