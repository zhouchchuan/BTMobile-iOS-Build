// Node 24: actual existing server source, memory-only DB, loopback HTTP.
// Usage: node this-file <SDK typescript.js> <existing subscription server directory>
const assert=require('node:assert/strict'),crypto=require('node:crypto'),http=require('node:http');
const path=require('node:path'),{pathToFileURL}=require('node:url');
const {harness}=require('./subscription-startup-test.cjs');
(async()=>{
 const dir=path.resolve(process.argv[3]);
 const {createApp}=await import(pathToFileURL(path.join(dir,'server.mjs')));
 const {presence}=await import(pathToFileURL(path.join(dir,'client-runtime.mjs')));
 const pair=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'});
 const app=createApp({adminPassword:'memory-only-contract-test-password',gateway:'https://pay.example.test',merchantId:'1000',merchantKey:'memory-only-test',paymentsEnabled:true,baseURL:'https://subscribe.example.test',signingPrivateKey:pair.privateKey.export({format:'pem',type:'pkcs8'})},{dbPath:':memory:'});
 const server=http.createServer(app.handler);await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const base='http://127.0.0.1:'+server.address().port;
 try {
  const h=harness(false,async(endpoint,options)=>{
   const response=await fetch(base+endpoint,{method:options.method,headers:options.header,body:options.method==='GET'?undefined:options.extraData});
   return{responseCode:response.status,result:await response.text()};
  });
  h.policy.SERVER_PUBLIC_KEY=pair.publicKey.export({type:'spki',format:'der'}).subarray(26).toString('base64');
  const client=h.make();await client.start(h.context);
  assert(client.state.ready&&client.state.online,client.state.message);
  assert(client.state.alipay&&client.state.wxpay,'actual array-form payment channels');
  assert(client.state.runtimeMessage.includes('在线状态已同步'),client.state.runtimeMessage);
  const id=client.state.deviceID;
  let device=app.db.prepare('SELECT * FROM devices WHERE id=?').get(id);
  assert.equal(device.client_platform,'harmonyos');assert.equal(device.client_version,'1.0.4');
  assert(presence(device,Math.floor(Date.now()/1000)).online,'management screen sees real heartbeat');
  await client.loadOrders();assert.equal(client.state.orderRows.length,0,'signed empty-body GET succeeds');
  app.db.prepare("UPDATE settings SET value='false' WHERE key='subscriptionEnabled'").run();
  await client.synchronize(true);assert(client.state.unlimited);assert(!client.state.subscribed);
  client.setForeground(false);await client.synchronize(true);
  device=app.db.prepare('SELECT * FROM devices WHERE id=?').get(id);assert.equal(device.client_foreground,0);
  assert.equal(app.db.prepare('SELECT count(*) AS n FROM orders').get().n,0,'no payment/order side effects');
  client.stop();
  console.log('PASS actual subscription server 1.2.4: registration -> verified entitlement -> signed harmonyos/1.0.4 heartbeat -> admin presence; signed empty GET orders; disabled restriction unlimited; no orders created.');
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));app.db.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
