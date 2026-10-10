const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert/strict'),ts=require(process.argv[2]);
const root=path.resolve(__dirname,'..'),read=p=>fs.readFileSync(path.join(root,p),'utf8');
const source=read('entry/src/main/ets/components/SettingsPanel.ets');
const parsed=ts.createSourceFile('Settings.ts',source.replace('export struct SettingsPanel','export class SettingsPanel'),ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
const declaration=parsed.statements.find(ts.isClassDeclaration);
const methods=declaration.members.filter(m=>['number','save','load','refreshDefaults'].includes(m.name?.getText(parsed))).map(m=>m.getText(parsed)).join('\n');
let calls=[],stored={},mismatch=false;
const scope={exports:{},call:async r=>{calls.push(r.op);if(r.op==='setNetworkSettings')stored=JSON.parse(JSON.stringify(r.settings));return{settings:mismatch?{...stored,maxDownloads:999}:stored,defaultTrackers:['https://tracker.example.test/announce']};}};
vm.runInNewContext(ts.transpileModule('class Harness {'+methods+'}\nexports.Harness=Harness;',{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,scope);
function panel(){const p=new scope.exports.Harness();Object.assign(p,{loaded:true,saving:false,port:'6882',download:'1000',upload:'200',queue:true,active:'10',downloads:'8',seeds:'8',seedEnabled:true,dht:true,lsd:true,natPmp:true,upnp:true,utp:true,allowWifi:true,allowCellular:false,completionNotifications:true,onAuthorizeNotifications:async()=>{calls.push('authorize');return true;},autoTrackers:true,custom:'https://custom.example.test/announce',onSaved:()=>calls.push('refresh'),onSync:async()=>{calls.push('sync');return '默认 Tracker 已同步；在线状态已同步';}});return p;}
(async()=>{
 const p=panel();await Promise.all([p.save(),p.save()]);assert.equal(calls.filter(x=>x==='setNetworkSettings').length,1);assert.equal(calls.filter(x=>x==='sync').length,1);
 assert(calls.indexOf('sync')>calls.indexOf('setNetworkSettings'));assert.equal(stored.maxDownloads,8);assert.equal(stored.maxSeeds,8);assert.equal(stored.uploadLimitKiB,200);assert.equal(stored.customTrackers[0],'https://custom.example.test/announce');assert(p.message.includes('在线状态已同步'));assert(!p.saving);
 assert.equal(stored.allowWifi,true);assert.equal(stored.allowCellular,false);assert.equal(stored.completionNotifications,true);assert.equal(calls.filter(x=>x==='authorize').length,1);
 calls=[];const disabled=panel();disabled.completionNotifications=false;await disabled.save();assert(!calls.includes('authorize'));assert.equal(stored.completionNotifications,false);assert(disabled.message.includes('通知已关闭'));
 calls=[];const denied=panel();denied.onAuthorizeNotifications=async()=>{throw Error('denied');};await denied.save();assert(calls.includes('sync'));assert(denied.message.includes('系统尚未授权'));assert(!denied.message.includes('保存失败'));assert.equal(stored.allowCellular,false);
 stored={};const migrated=panel();await migrated.load();assert(migrated.allowWifi&&migrated.allowCellular&&migrated.completionNotifications);
 calls=[];const offline=panel();offline.onSync=async()=>{throw Error('offline');};await offline.save();assert(offline.message.includes('已保存'));assert(offline.message.includes('暂未完成'));assert(!offline.message.includes('保存失败'));
 calls=[];const invalid=panel();invalid.downloads='-1';await invalid.save();assert(!calls.includes('setNetworkSettings'));assert(!calls.includes('sync'));
 calls=[];mismatch=true;await panel().save();assert(!calls.includes('sync'));mismatch=false;
 assert(!source.includes('saveQueue(')&&!source.includes("'保存队列设置'")&&!source.includes("Button('同步默认 Tracker')"));
 const index=read('entry/src/main/ets/pages/Index.ets');const card=index.slice(index.indexOf("Text('下载核心网络状态')"),index.indexOf("Text('后台传输')"));
 assert(!index.includes("Button('检查 / 开启通知')"));assert(source.indexOf("Text('下载完成通知')")<source.indexOf("'保存核心设置'"));
 assert(card.includes('Row({ space: 8 })'));for(const x of ['this.networkPort','this.networkDht','this.networkTrackers'])assert(card.includes(x));
 const icon=fs.readFileSync(path.join(root,'entry/src/main/resources/base/media/start_icon.png'));assert.equal(icon.readUInt32BE(16),192);assert.equal(icon.readUInt32BE(20),192);
 const manifest=JSON.parse(read('entry/src/main/module.json5'));assert.equal(manifest.module.abilities[0].startWindowIcon,'$media:start_icon');assert.equal(manifest.module.abilities[0].icon,'$media:launcher_icon');
 console.log('PASS: one save applies all settings + readback before sync; double-tap/invalid input/offline safety; three live network values in one row; separate 192px startup asset.');
})().catch(e=>{console.error(e);process.exitCode=1;});
