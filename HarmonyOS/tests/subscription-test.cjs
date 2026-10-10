// Exercise actual ArkTS policy/service with deterministic OS adapters; real HUKS stays a device test.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const ts=require(process.argv[2]),root=path.resolve(__dirname,'..'),models=path.join(root,'entry/src/main/ets/model');
const cache=new Map(), nativeRequests=[];
let failAdd=false, duplicate=false, failures=0, networkCalls=0, saved=[];
const native={call:async r=>{nativeRequests.push({...r});if(r.op==='validateAdd'){if(r.uri==='bad')throw Error('bad magnet');return {duplicate};}if(r.op==='add'){if(failAdd)throw Error('disk error');return {id:'fixture',duplicate:false};}return {items:[]};}};
const util={TextEncoder:class{encodeInto(s){return new Uint8Array(Buffer.from(s));}}, TextDecoder:{create(){return{decodeWithStream:b=>Buffer.from(b).toString()};}},
  Base64Helper:class{encodeToStringSync(b){return Buffer.from(b).toString('base64');}decodeSync(s){return new Uint8Array(Buffer.from(s,'base64'));}},generateRandomUUID:()=>crypto.randomUUID()};
const crypt={createMd:()=>{const h=crypto.createHash('sha256');return {update:async b=>h.update(b.data),digest:async()=>({data:new Uint8Array(h.digest())})};},
 createAsyKeyGenerator:()=>({convertKey:async b=>({pubKey:crypto.createPublicKey({key:Buffer.from(b.data),format:'der',type:'spki'})})}),
 createVerify:()=>{let key;return{init:async k=>{key=k;},verify:async (a,b)=>crypto.verify('sha256',a.data,key,b.data)}}};
const http={RequestMethod:{GET:'GET',POST:'POST'},HttpDataType:{STRING:0},createHttp:()=>({request:async()=>{networkCalls++;throw Error('offline');},destroy(){}})};
const mocks={'./Native':native,'@ohos.net.http':{default:http},'@ohos.systemDateTime':{default:{getUptime:()=>1000,TimeType:{STARTUP:0}}},'@ohos.util':{default:util},'@ohos.security.cryptoFramework':{default:crypt}};
function load(name){if(cache.has(name))return cache.get(name);const sandbox={exports:{},Uint8Array,Array,Date,Math,Number,JSON,Error,Promise,Observed:c=>c,setInterval:()=>1,clearInterval(){},require:n=>mocks[n]||(n.startsWith('./')?load(n.slice(2)):{default:{}})};vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(models,name+'.ets'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,sandbox);cache.set(name,sandbox.exports);return sandbox.exports;}
const p=load('SubscriptionPolicy'),v=load('SubscriptionVault'),s=load('SubscriptionService');
const now=Math.floor(Date.now()/1000),id=crypto.randomUUID().toUpperCase();
const ledger=()=>({schema:1,deviceID:id,day:p.shanghaiDay(now),used:0,maxTime:now,receipt:'',config:'',revision:0});
const claim=changes=>({aud:p.SUBSCRIPTION_AUDIENCE,deviceID:id,issuedAt:now,expiresAt:now+86400,validUntil:now+86400,priceCents:800,days:30,paymentsEnabled:true,subscriptionEnabled:true,paymentChannels:{alipay:true,wxpay:true},...changes});
const data=changes=>({aud:p.SUBSCRIPTION_AUDIENCE,kind:'client-config',nonce:'test',issuedAt:now,trackersRevision:2,trackers:['udp://tracker.example.test:80/announce'],heartbeatInterval:60,onlineWindow:180,...changes});
assert.equal(p.shanghaiDay(Date.UTC(2026,9,10,15,59,59)/1000),'2026-10-10');
assert.equal(p.shanghaiDay(Date.UTC(2026,9,10,16)/1000),'2026-10-11');
let l=ledger();for(let i=0;i<3;i++)l=p.reserve(l,now);assert.equal(p.remaining(l,now),0);assert.throws(()=>p.reserve(l,now),/DAILY_LIMIT/);assert.equal(p.remaining(l,now+86400),3);assert.equal(p.refund(l,l.day).used,2);assert.equal(p.refund(l,'1999-01-01').used,3);
p.validateLedger(l);assert.throws(()=>p.validateLedger({...l,used:-1}));
p.validateEntitlement(claim(),id,now);for(const c of [{aud:'wrong'},{deviceID:'wrong'},{issuedAt:now+301},{validUntil:now+86401},{priceCents:1},{days:365},{paymentChannels:null}])assert.throws(()=>p.validateEntitlement(claim(c),id,now));
assert(p.paid(claim(),now));assert(!p.paid(claim({expiresAt:now}),now));assert(!p.unlimited(claim({validUntil:now}),now));assert(p.unlimited(claim({expiresAt:0,subscriptionEnabled:false}),now));
p.validateConfig(data(), 'test', now, 1);for(const c of [{nonce:'old'},{issuedAt:now-300},{trackersRevision:0},{trackersRevision:1},{trackers:['file:///tmp/x']},{trackers:['https://user:pass@test/a']},{trackers:['udp://test/a']},{trackers:['https://test/a#x']},{trackers:['udp://test:65536/a']}])assert.throws(()=>p.validateConfig(data(c),'test',now,2));
assert(p.validTracker('https://tracker.example.test/announce?key=public'));assert(p.validTracker('udp://[::1]:80/announce'));assert(p.validCheckout(p.SUBSCRIPTION_ORIGIN+'/checkout?token='+'a'.repeat(64)));for(const x of ['https://evil.test/checkout?token=','http://sub.linkyou.win:5288/checkout?token='])assert(!p.validCheckout(x+'a'.repeat(64)));
function instance(){const state=new s.SubscriptionState(),service=new s.SubscriptionService(state);service.ledger=ledger();service.vault={save:async value=>{if(failures-->0)throw Error('storage error');saved.push(JSON.parse(JSON.stringify(value)));}};service.state.ready=true;service.lastRefresh=now;return service;}
(async()=>{
 const kp=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'}),message=Buffer.from('sign-format');
 const raw=crypto.sign('sha256',message,{key:kp.privateKey,dsaEncoding:'ieee-p1363'});assert(crypto.verify('sha256',message,kp.publicKey,v.derSignature(raw)));
 const der=crypto.sign('sha256',message,kp.privateKey);assert.deepEqual(Buffer.from(v.derSignature(der)),der);
 await assert.rejects(v.verifyEnvelope(JSON.stringify({payload:Buffer.from('{}').toString('base64'),signature:der.toString('base64')})),/签名无效/);
 assert.equal(await v.sha256(''),crypto.createHash('sha256').update('').digest('hex'));
 const service=instance();const results=await Promise.all([1,2,3,4,5].map(()=>service.addTask('magnet:?valid')));assert.deepEqual(results,[true,true,true,false,false]);assert.equal(service.ledger.used,3);assert.equal(nativeRequests.filter(r=>r.op==='add').length,3);
 duplicate=true;assert.equal(await service.addTask('magnet:?duplicate'),true);assert.equal(service.ledger.used,3);duplicate=false;
 await assert.rejects(service.addTask('bad'));assert.equal(service.ledger.used,3);
 const failed=instance();failAdd=true;await assert.rejects(failed.addTask('magnet:?valid'));assert.equal(failed.ledger.used,0);failAdd=false;
 const cannotSave=instance(),before=nativeRequests.filter(r=>r.op==='add').length;failures=1;await assert.rejects(cannotSave.addTask('magnet:?valid'));assert.equal(nativeRequests.filter(r=>r.op==='add').length,before);assert.equal(cannotSave.ledger.used,0);
 const subscribed=instance();subscribed.entitlement=claim();assert(await subscribed.addTask('magnet:?valid'));assert.equal(subscribed.ledger.used,0);
 const policyOff=instance();policyOff.ledger.used=2;policyOff.entitlement=claim({expiresAt:0,subscriptionEnabled:false});
 for(let i=0;i<5;i++)assert(await policyOff.addTask('magnet:?valid'));
 assert.equal(policyOff.ledger.used,2);assert.equal(policyOff.state.subscribed,false);assert.equal(policyOff.state.unlimited,true);
 policyOff.entitlement=claim({expiresAt:0,subscriptionEnabled:true});assert(await policyOff.addTask('magnet:?valid'));
 assert.equal(policyOff.ledger.used,3);assert.equal(await policyOff.addTask('magnet:?valid'),false);
 const offline=instance();offline.lastRefresh=0;assert(await offline.addTask('magnet:?valid'));assert.equal(offline.ledger.used,1);assert(networkCalls>0);assert(!offline.state.online);
 const expired=instance();expired.entitlement=claim({expiresAt:now-1});assert(await expired.addTask('magnet:?valid'));assert.equal(expired.ledger.used,1);
 const locked=instance();locked.state.ready=false;await assert.rejects(locked.addTask('magnet:?valid'));assert.equal(locked.ledger.used,0);
 const index=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/Index.ets'),'utf8');assert(!index.includes("call({ op: 'add'"));assert.equal((index.match(/subscriptions\.addTask\(/g)||[]).length,2);
 const core=fs.readFileSync(path.join(root,'entry/src/main/cpp/bridge.cpp'),'utf8');const managed=core.slice(core.indexOf('if (op == "setManagedTrackers")'),core.indexOf('if (op == "setListenPort"'));assert(!managed.includes('apply_settings')&&!managed.includes('replace_trackers')&&!managed.includes('customTrackers\"] ='));
 const panel=fs.readFileSync(path.join(root,'entry/src/main/ets/components/SubscriptionPanel.ets'),'utf8');assert(panel.includes('SubscriptionCheckout')&&!panel.includes('startAbility'));
 const web=fs.readFileSync(path.join(root,'entry/src/main/ets/components/SubscriptionCheckout.ets'),'utf8');assert(web.includes('.fileAccess(false).mixedMode(MixedMode.None)')&&!web.includes('javaScriptProxy'));
 const sdkLoader=path.resolve(path.dirname(process.argv[2]),'../../..');const opts=JSON.parse(fs.readFileSync(path.join(sdkLoader,'tsconfig.json'),'utf8')).compilerOptions;opts.ets.components.push('SubscriptionPanel','SubscriptionCheckout','IconButton');
 for(const file of ['model/SubscriptionPolicy.ets','model/SubscriptionVault.ets','model/SubscriptionService.ets','components/SubscriptionPanel.ets','components/SubscriptionCheckout.ets']){const src=fs.readFileSync(path.join(root,'entry/src/main/ets',file),'utf8');const result=ts.createSourceFile(file,src,ts.ScriptTarget.Latest,true,ts.ScriptKind.ETS,opts);assert.equal(result.parseDiagnostics.length,0,file+': '+result.parseDiagnostics.map(d=>ts.flattenDiagnosticMessageText(d.messageText,'\n')).join('\n'));}
 console.log('PASS: daily boundary, quota concurrency/duplicates/refunds/durable reservation, paid/offline policy, signed-envelope rejection, ECDSA format, checkout allowlist, managed-config validation, all add entrypoints, ArkTS syntax. HUKS hardware and real payment require device validation.');
})().catch(e=>{console.error(e);process.exitCode=1;});

