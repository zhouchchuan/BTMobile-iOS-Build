const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert/strict');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root,p),'utf8');
const source = read('entry/src/main/ets/model/BackgroundTransfer.ets');
function harness(api = 20) {
  let now = 100000, rows = [], current = null, startGate, publishGate, failStart = false, failPublish = false, failPoll = false;
  const calls = [], listeners = new Map(), timers = new Map(), messages = [];
  const context = {marker:'UIAbility context'};
  const manager = {
    on: (event, cb) => listeners.set(event, cb), off: event => listeners.delete(event),
    getAllContinuousTasks: async c => { assert.equal(c, context); return current ? [current] : []; },
    startBackgroundRunning: async (c, modes) => {
      assert.equal(c, context); assert.equal(JSON.stringify(modes), '["dataTransfer"]'); calls.push('start');
      if (startGate) await startGate;
      if (failStart) throw Error('9800006 denied');
      current={abilityName:'EntryAbility', notificationId:42, continuousTaskId:77, suspendState:false};
      return {notificationId:42, continuousTaskId:77};
    },
    stopBackgroundRunning: async c => { assert.equal(c,context); calls.push('stop'); listeners.get('continuousTaskCancel')?.({id:77,reason:1}); current=null; }
  };
  const notification = {
    publish: async request => { calls.push(request); if(publishGate)await publishGate;if(failPublish)throw Error('notification denied'); },
    SlotType:{LIVE_VIEW:6},ContentType:{NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW:8}
  };
  const native = { call: async request => { assert.equal(request.op,'tasks');calls.push('tasks');if(failPoll)throw Error('temporary native failure');return{items:rows}; }, bytes:n=>n+' B' };
  const mocks = {
    '@ohos.resourceschedule.backgroundTaskManager': {default:manager},
    '@ohos.notificationManager':{default:notification},
    '@ohos.app.ability.wantAgent':{default:{getWantAgent:async()=>({}),OperationType:{START_ABILITY:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:1}}},
    '@ohos.deviceInfo':{default:{sdkApiVersion:api}}, '@ohos.hilog':{default:{info(){}}},
    './Native':native, './CompletionNotifications':{CompletionNotifications:class{deliver(){return new Promise(()=>{});}}}
  };
  // Execute the actual compatibility bridge too, not a mock of its behavior.
  if (api < 15) { delete manager.on; delete manager.off; }
  if (api < 20) delete manager.getAllContinuousTasks;
  const bridgeScope={exports:{},require:name=>mocks[name]??{}};
  vm.runInNewContext(ts.transpileModule(read('entry/src/main/ets/model/BackgroundTaskCompat.js'),
    {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,bridgeScope);
  mocks['./BackgroundTaskCompat']=bridgeScope.exports;
  const scope={exports:{},require:name=>mocks[name]??{},Date:{now:()=>now},AppStorage:{setOrCreate:(key,value)=>messages.push(value)},
    setInterval:cb=>{timers.set(1,cb);return 1;},clearInterval:id=>timers.delete(id)};
  vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,scope);
  const service=new scope.exports.BackgroundTransfer();service.attach(context);service.setForeground(true);
  return {service,calls,listeners,messages,timers,
    rows:value=>{rows=value;},time:delta=>{now+=delta;},tick:()=>timers.get(1)?.(),
    startGate:value=>{startGate=value;},publishGate:value=>{publishGate=value;},
    failStart:value=>{failStart=value;},failPublish:value=>{failPublish=value;},failPoll:value=>{failPoll=value;},
    cancel:()=>{current=null;listeners.get('continuousTaskCancel')?.({id:77,reason:2});},
    suspend:()=>{current.suspendState=true;listeners.get('continuousTaskSuspend')?.({continuousTaskId:77,suspendReason:1});},
    activate:()=>{current.suspendState=false;listeners.get('continuousTaskActive')?.({id:77});}
  };
}
const row = extra => ({id:'fixture',name:'must not enter notification',active:true,paused:false,complete:false,done:200,total:1000,downloaded:200,uploaded:20,download:100,upload:10,...extra});
const settle = async () => { for(let i=0;i<35;i++)await Promise.resolve(); };
const count=(h,x)=>h.calls.filter(c=>c===x).length;
const notices=h=>h.calls.filter(c=>typeof c==='object');
(async()=>{
  const h=harness();h.rows([row()]);h.service.start(true);await settle();
  assert.equal(count(h,'start'),1);assert.equal(notices(h)[0].id,42);
  assert.equal(notices(h)[0].template.data.progressValue,20);
  assert(!JSON.stringify(notices(h)).includes('must not enter notification'));
  h.service.setForeground(false);await settle();
  assert.equal(count(h,'stop'),0,'background transition must not release runtime');
  h.time(6000);h.rows([row({done:500,downloaded:500})]);h.tick();await settle();
  assert.equal(notices(h).at(-1).template.data.progressValue,50,'page-independent background progress');
  h.time(610000);h.tick();await settle();assert.equal(notices(h).length,2,'do not fabricate idle traffic');
  h.rows([row({done:800,downloaded:800})]);h.tick();await settle();assert.equal(notices(h).length,3);
  h.failPoll(true);h.time(7000);h.tick();await settle();assert.equal(count(h,'stop'),0,'failed snapshot does not clear tasks');h.failPoll(false);
  h.suspend();h.rows([row({done:900,downloaded:900})]);h.time(7000);h.tick();await settle();
  assert.equal(notices(h).length,3);assert(h.messages.at(-1).includes('挂起'));assert.equal(count(h,'start'),1);
  h.activate();await settle();assert.equal(notices(h).length,4);
  h.cancel();h.tick();await settle();assert.equal(count(h,'start'),1,'do not fight system/user cancellation');
  h.service.setForeground(true);await settle();assert.equal(count(h,'start'),2,'foreground recovery');
  h.rows([]);h.service.observe([]);h.time(6000);h.tick();await settle();assert.equal(count(h,'stop'),1);
  h.rows([row()]);h.tick();await settle();assert.equal(count(h,'start'),3,'intentional stop is not external cancellation');
  h.service.setEnabled(false);await settle();assert.equal(count(h,'stop'),2);assert(!h.messages.at(-1).includes('已启用'));
  await h.service.detach();assert.equal(h.timers.size,0);assert.equal(h.listeners.size,0);

  const disabled=harness();disabled.rows([row()]);disabled.service.start(false);await settle();assert.equal(count(disabled,'start'),0);
  const old=harness(12);old.rows([row()]);old.service.start(true);await settle();assert.equal(count(old,'start'),1);assert.equal(old.listeners.size,0);
  const race=harness();let release;race.startGate(new Promise(r=>release=r));race.rows([row()]);race.service.start(true);await settle();
  race.service.setEnabled(false);release();await settle();assert.equal(count(race,'stop'),1,'disable while start is pending');
  const wait=harness();let finish;wait.startGate(new Promise(r=>finish=r));wait.rows([row()]);wait.service.start(true);await settle();
  let prepared=false;const pending=wait.service.prepareTransfer().then(()=>prepared=true);await settle();assert(!prepared);finish();await pending;assert(prepared);
  const denied=harness();denied.failStart(true);denied.rows([row()]);denied.service.start(true);await settle();assert(denied.messages.at(-1).includes('失败'));
  denied.tick();await settle();assert.equal(count(denied,'start'),1);denied.time(16000);denied.failStart(false);denied.tick();await settle();assert.equal(count(denied,'start'),2);
  const publish=harness();publish.failPublish(true);publish.rows([row()]);publish.service.start(true);await settle();assert(publish.messages.at(-1).includes('失败'));
  publish.time(16000);publish.failPublish(false);publish.tick();await settle();assert.equal(count(publish,'start'),1,'retry notification without restarting task');

  const page=read('entry/src/main/ets/pages/Index.ets'),ability=read('entry/src/main/ets/entryability/EntryAbility.ets');
  assert(!page.includes('startBackgroundRunning')&&!page.includes('backgroundActive'));
  assert(ability.includes('backgroundTransfer.attach(this.context)')&&ability.includes('backgroundTransfer.setForeground(false)'));
  assert(read('entry/src/main/ets/components/TaskDetails.ets').includes("app.media.action_refresh'), preserveSvgStroke: true"));
  assert(read('entry/src/main/ets/components/IconButton.ets').includes('if (this.preserveSvgStroke) { Image(this.icon).width(24).height(24) }'));
  assert(page.includes("op: 'refreshTask', id: task.id"));
  console.log('PASS V104: foreground acquisition, background/lock lifecycle, real live-view progress, no fake idle updates, pending races, API12 fallback, cancellation/suspend/recovery, notification failure, independent completion, refresh outline+action');
})().catch(e=>{console.error(e);process.exitCode=1;});
