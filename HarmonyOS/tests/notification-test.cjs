const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert/strict'),ts=require(process.argv[2]);
const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/model/CompletionNotifications.ets'),'utf8');
function harness(preference=true,permission=true,disableWhilePreparing=false){
 const calls=[];let pending=[{id:'1234567890abcdef',name:'local fixture'}];
 const notifications={isNotificationEnabled:async()=>permission,requestEnableNotification:async()=>{calls.push('authorize');permission=true;},publish:async()=>calls.push('publish'),SlotType:{SERVICE_INFORMATION:1},ContentType:{NOTIFICATION_CONTENT_BASIC_TEXT:1}};
 const agent={getWantAgent:async()=>{if(disableWhilePreparing)preference=false;return{};},OperationType:{START_ABILITY:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:1}};
 const native={call:async r=>{calls.push(r.op);if(r.op==='completionEvents')return{events:pending};if(r.op==='getNetworkSettings')return{settings:{completionNotifications:preference}};if(r.op==='ackCompletion')pending=[];return{};}};
 const scope={exports:{},Date,require:n=>n.includes('notificationManager')?{default:notifications}:n.includes('wantAgent')?{default:agent}:native};
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,scope);
 return {instance:new scope.exports.CompletionNotifications(),calls};
}
(async()=>{
 for(const args of [[false,true],[true,false],[true,true,true]]){const h=harness(...args);await h.instance.deliver({});assert(!h.calls.includes('publish'));assert(!h.calls.includes('authorize'));}
 const h=harness();await h.instance.deliver({});assert(h.calls.includes('publish')&&h.calls.includes('ackCompletion'));await h.instance.deliver({});assert.equal(h.calls.filter(x=>x==='publish').length,1);
 const p=harness(true,false);await p.instance.authorize({});await p.instance.authorize({});assert.equal(p.calls.filter(x=>x==='authorize').length,1);
 console.log('PASS notification preference + OS permission + in-flight disabling + deduplicated delivery; consent requested only by explicit save.');
})().catch(e=>{console.error(e);process.exitCode=1;});
