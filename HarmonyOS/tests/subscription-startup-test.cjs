// Run the actual vault + service against real Node crypto and contract-faithful OS adapters.
// No device keys, production accounts, network requests or payment orders are used.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), crypto = require('node:crypto');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '..');
function harness(legacy = false, transport) {
  const keys = new Map(), disk = new Map(), handles = new Map(), files = new Map();
  const cache = new Map(), timers = new Map(), requests = [], nativeCalls = [], messages = [];
  let next = 1, generationCount = 0, existenceFailure = false, configFailure = false, badConfig = false;
  let registeredID = '', registeredKey, activityCount = 0;
  const server = crypto.generateKeyPairSync('ec', {namedCurve:'prime256v1'});
  const businessError = code => Object.assign(new Error('test keystore error'), {code});
  const tag = name => name;
  const properties = p => Object.fromEntries(p.map(x=>[x.tag, x.value]));
  const huks = {
    HuksTag: Object.fromEntries(['ALGORITHM','KEY_SIZE','PURPOSE','DIGEST','PADDING','BLOCK_MODE','NONCE','ASSOCIATED_DATA','AE_TAG'].map(x=>['HUKS_TAG_'+x,tag(x)])),
    HuksKeyAlg:{HUKS_ALG_ECC:2,HUKS_ALG_AES:1}, HuksKeyPurpose:{HUKS_KEY_PURPOSE_SIGN:1,HUKS_KEY_PURPOSE_VERIFY:2,HUKS_KEY_PURPOSE_ENCRYPT:4,HUKS_KEY_PURPOSE_DECRYPT:8},
    HuksKeyDigest:{HUKS_DIGEST_SHA256:4},HuksKeyPadding:{HUKS_PADDING_NONE:0},HuksCipherMode:{HUKS_MODE_GCM:3},
    async isKeyItemExist(alias) { if (!keys.has(alias)) throw businessError(12000011); return true; },
    async hasKeyItem(alias) { if (existenceFailure) throw businessError(12000005); return keys.has(alias); },
    async generateKeyItem(alias, options) {
      assert(!keys.has(alias),'must not overwrite an existing key'); generationCount++;
      const p=properties(options.properties); assert.equal(p.KEY_SIZE,256);
      keys.set(alias,p.ALGORITHM===2?crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'}):crypto.randomBytes(32));
    },
    async exportKeyItem(alias) { return {outData:new Uint8Array(keys.get(alias).publicKey.export({type:'spki',format:'der'}))}; },
    async initSession(alias, options) { assert(keys.has(alias)); const id=next++; handles.set(id,{alias,p:properties(options.properties)}); return {handle:id}; },
    async finishSession(id, options) {
      const {alias,p}=handles.get(id), key=keys.get(alias), input=Buffer.from(options.inData); handles.delete(id);
      let out;
      if(p.ALGORITHM===2) out=crypto.sign('sha256',input,key.privateKey);
      else {
        const cipher=p.PURPOSE===4?crypto.createCipheriv('aes-256-gcm',key,p.NONCE):crypto.createDecipheriv('aes-256-gcm',key,p.NONCE);
        cipher.setAAD(p.ASSOCIATED_DATA);
        if(p.PURPOSE===8)cipher.setAuthTag(p.AE_TAG);
        out=Buffer.concat([cipher.update(input),cipher.final()]);
        if(p.PURPOSE===4)out=Buffer.concat([out,cipher.getAuthTag()]);
      }
      return {outData:new Uint8Array(out)};
    },
    async abortSession(id) {handles.delete(id);}
  };
  const fileSystem = {
    OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4}, accessSync:p=>disk.has(p),statSync:p=>({size:disk.get(p).length}),readTextSync:p=>disk.get(p),
    openSync:p=>{const fd=next++;files.set(fd,p);return{fd};},writeSync:(fd,text)=>disk.set(files.get(fd),text),fsyncSync(){},closeSync:fd=>files.delete(fd),
    renameSync:(a,b)=>{assert(disk.has(a));disk.set(b,disk.get(a));disk.delete(a);}
  };
  const util = {
    TextEncoder:class{encodeInto(s){return new Uint8Array(Buffer.from(s));}},TextDecoder:{create(){return{decodeWithStream:b=>Buffer.from(b).toString('utf8')};}},
    Base64Helper:class{encodeToStringSync(b){return Buffer.from(b).toString('base64');}decodeSync(s){return new Uint8Array(Buffer.from(s,'base64'));}},
    generateRandomUUID:()=>crypto.randomUUID()
  };
  const crypt = {
    createRandom:()=>({generateRandom:async n=>({data:new Uint8Array(crypto.randomBytes(n))})}),
    createMd:()=>{const h=crypto.createHash('sha256');return{update:async b=>{if(!b.data.length)throw Error('build context fail.');h.update(b.data);},digest:async()=>({data:new Uint8Array(h.digest())})};},
    createAsyKeyGenerator:()=>({convertKey:async b=>({pubKey:crypto.createPublicKey({key:Buffer.from(b.data),type:'spki',format:'der'})})}),
    createVerify:()=>{let key;return{init:async k=>{key=k;},verify:async(a,b)=>crypto.verify('sha256',a.data,key,b.data)};}
  };
  function envelope(value){const payload=Buffer.from(JSON.stringify(value));return JSON.stringify({payload:payload.toString('base64'),signature:crypto.sign('sha256',payload,server.privateKey).toString('base64')});}
  const http = {RequestMethod:{GET:'GET',POST:'POST'},HttpDataType:{STRING:0},createHttp:()=>({destroy(){},async request(url,options){
    const u=new URL(url), body=options.extraData, now=Math.floor(Date.now()/1000), aud='com.mxmall123.app';
    requests.push({path:u.pathname,body});
    if(transport)return transport(u.pathname+u.search,options);
    let value;
    if(u.pathname==='/v1/bootstrap')value={aud,nonce:u.searchParams.get('nonce'),serverTime:now};
    else if(u.pathname==='/v1/register'){
      const data=JSON.parse(body); registeredID=data.deviceID;
      const prefix=Buffer.from([48,89,48,19,6,7,42,134,72,206,61,2,1,6,8,42,134,72,206,61,3,1,7,3,66,0]);
      registeredKey=crypto.createPublicKey({key:Buffer.concat([prefix,Buffer.from(data.publicKey,'base64')]),type:'spki',format:'der'});
      assert(crypto.verify('sha256',Buffer.from('register\n'+registeredID),registeredKey,Buffer.from(data.proof,'base64')));
      value={aud,deviceID:registeredID,issuedAt:now,expiresAt:0,validUntil:now+86400,priceCents:800,days:30,paymentsEnabled:true,subscriptionEnabled:false,paymentChannels:['alipay','wxpay']};
    }else if(u.pathname==='/v1/client-config'){
      if(configFailure)throw Error('offline');
      value={aud,kind:'client-config',nonce:u.searchParams.get('nonce'),issuedAt:now,trackersRevision:3,trackers:['https://tracker.example.test/announce'],heartbeatInterval:60,onlineWindow:180};
    }else if(u.pathname==='/v1/activity'){
      const h=options.header, payload=JSON.parse(body);
      assert.equal(h['X-Device-ID'],registeredID);assert.equal(payload.platform,'harmonyos');assert.equal(payload.version,'1.0.5');
      assert.deepEqual(Object.keys(payload).sort(),['platform','version','foreground','downloading','seeding','metadata','checking','downloadRate','uploadRate'].sort());
      const message='POST\n/v1/activity\n'+h['X-Time']+'\n'+h['X-Nonce']+'\n'+crypto.createHash('sha256').update(body).digest('hex');
      assert(crypto.verify('sha256',Buffer.from(message),registeredKey,Buffer.from(h['X-Signature'],'base64')));
      activityCount++;value={aud,kind:'activity-ack',deviceID:registeredID,nonce:h['X-Nonce'],issuedAt:now,trackersRevision:3};
    }else throw Error('unexpected endpoint: '+u.pathname);
    let result=envelope(value);if(badConfig&&u.pathname==='/v1/client-config'){const bad=JSON.parse(result);bad.payload=Buffer.from('{}').toString('base64');result=JSON.stringify(bad);}
    return{responseCode:200,result};
  }})};
  const native={call:async r=>{nativeCalls.push({...r});return{items:[]};}};
  const mocks={'./Native':native,'@ohos.file.fs':{default:fileSystem},'@ohos.security.huks':{default:huks},'@ohos.util':{default:util},'@ohos.security.cryptoFramework':{default:crypt},'@ohos.net.http':{default:http},'@ohos.hilog':{default:{info:(...v)=>messages.push(v),warn:(...v)=>messages.push(v)}},'@ohos.systemDateTime':{default:{getUptime:()=>1000,TimeType:{STARTUP:0}}}};
  function load(name){
    if(cache.has(name))return cache.get(name);
    let source=fs.readFileSync(path.join(root,'entry/src/main/ets/model',name+'.ets'),'utf8');
    if(legacy&&name==='SubscriptionVault')source=source.replaceAll('huks.hasKeyItem(','huks.isKeyItemExist(');
    const scope={exports:{},Uint8Array,Array,Date,Math,Number,JSON,Error,Promise,Observed:x=>x,setInterval:fn=>{const n=next++;timers.set(n,fn);return n;},clearInterval:n=>timers.delete(n),require:n=>mocks[n]||(n.startsWith('./')?load(n.slice(2)):{default:{}})};
    vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,scope);
    cache.set(name,scope.exports);return scope.exports;
  }
  const policy=load('SubscriptionPolicy');policy.SERVER_PUBLIC_KEY=server.publicKey.export({type:'spki',format:'der'}).subarray(26).toString('base64');
  const vault=load('SubscriptionVault'),service=load('SubscriptionService');
  return{keys,disk,timers,requests,nativeCalls,messages,context:{filesDir:'/test'},vault,policy,
    make:()=>new service.SubscriptionService(new service.SubscriptionState()),
    setExistenceFailure:x=>{existenceFailure=x;},setConfigFailure:x=>{configFailure=x;},setBadConfig:x=>{badConfig=x;},
    get generationCount(){return generationCount;},get activityCount(){return activityCount;}};
}
module.exports={harness};
if(require.main===module)(async()=>{
  const old=harness(true), broken=old.make();await broken.start(old.context);
  assert.equal(broken.state.ready,false);assert.equal(old.generationCount,0);assert.equal(old.requests.length,0);
  assert(broken.state.message.includes('12000011'),'reproduce the old first-install API error');
  assert.equal(old.timers.size,1,'failure must still allow retry');
  const h=harness(),app=h.make();await app.start(h.context);
  assert(app.state.ready);assert.match(app.state.deviceID,/^[0-9A-F-]{36}$/);assert.equal(h.generationCount,2);
  assert(app.state.online);assert.equal(app.state.subscribed,false);assert(app.state.unlimited);
  assert.equal(app.state.trackerRevision,3);assert.equal(h.activityCount,1);assert(app.state.runtimeMessage.includes('在线状态已同步'));
  assert(h.nativeCalls.some(x=>x.op==='setManagedTrackers'&&x.revision===3));
  assert(!h.requests.some(x=>x.path==='/v1/orders'));
  const id=app.state.deviceID, v=new h.vault.SubscriptionVault(h.context),saved=await v.load();
  assert.equal(saved.deviceID,id);saved.used=2;await v.save(saved);app.stop();
  const reopen=h.make();await reopen.start(h.context);assert.equal(reopen.state.deviceID,id);assert.equal(h.generationCount,2);assert.equal(reopen.state.freeRemaining,1);
  assert(!h.disk.get('/test/subscription-v1.enc').includes(id),'ledger is encrypted, not plaintext');
  h.setConfigFailure(true);const count=h.activityCount;await reopen.synchronize(true);
  assert.equal(h.activityCount,count+1);assert(reopen.state.runtimeMessage.includes('Tracker 同步失败'));assert(reopen.state.runtimeMessage.includes('在线状态已同步'));
  h.setConfigFailure(false);h.setBadConfig(true);const updates=h.nativeCalls.filter(x=>x.op==='setManagedTrackers').length;
  await reopen.synchronize(true);assert.equal(h.nativeCalls.filter(x=>x.op==='setManagedTrackers').length,updates);assert.equal(reopen.state.trackerRevision,3);
  h.setBadConfig(false);await reopen.synchronize(true);assert(reopen.state.runtimeMessage.includes('默认 Tracker 已同步'));
  const retry=harness(),retryApp=retry.make();retry.setExistenceFailure(true);await retryApp.start(retry.context);
  assert(!retryApp.state.ready);assert(retryApp.state.identityMessage.includes('重试'));assert(!retryApp.state.busy);assert.equal(retry.generationCount,0);
  retry.setExistenceFailure(false);await Promise.all([retryApp.synchronize(true),retryApp.synchronize(true)]);
  assert(retryApp.state.ready);assert.equal(retry.generationCount,2);assert.equal(retry.activityCount,1);
  const locked=harness();locked.keys.set('btmobile.subscription.device.v1',{});await assert.rejects(new locked.vault.SubscriptionVault(locked.context).load(),/记录丢失/);assert.equal(locked.generationCount,0);
  const encoded=h.disk.get('/test/subscription-v1.enc'),bytes=Buffer.from(encoded,'base64');bytes[bytes.length-1]^=1;h.disk.set('/test/subscription-v1.enc',bytes.toString('base64'));
  await assert.rejects(v.load());assert.equal(h.generationCount,2,'corruption must not recreate identity');
  h.disk.set('/test/subscription-v1.enc',encoded);h.keys.delete('btmobile.subscription.storage.v1');await assert.rejects(v.load(),/安全密钥不可用/);
  assert(!JSON.stringify(h.messages).includes(id),'diagnostics must not log device identity');
  console.log('PASS: old 12000011 reproduced; actual vault fresh install + AES-GCM persistence + P256 registration/activity proofs; offline/cache isolation; retries/concurrency; corruption/key-loss fail closed; no payments or private diagnostic payloads. Real HUKS still needs device acceptance.');
})().catch(error=>{console.error(error);process.exitCode=1;});
