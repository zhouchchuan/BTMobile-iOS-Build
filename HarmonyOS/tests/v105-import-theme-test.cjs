const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert/strict');
const ts=require(process.argv[2]),root=path.resolve(__dirname,'../entry/src/main');
function load(relative,dependencies={},extra={}){
 const source=fs.readFileSync(path.join(root,'ets',relative),'utf8');
 const context={exports:{},ArrayBuffer,Uint8Array,Set,Promise,require:name=>dependencies[name]??{},...extra};
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,context);
 return context.exports;
}
const source=fs.readFileSync(path.join(root,'ets/pages/Index.ets'),'utf8');
function method(name,next,deps){
 const begin=source.indexOf('  async '+name+'('),end=source.indexOf('  '+next,begin);
 assert(begin>=0&&end>begin);
 const code=source.slice(begin,end).replace('async '+name+'(','async function '+name+'(');
 const context={...deps};vm.runInNewContext(ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,context);return context[name];
}
(async()=>{
 const bytes=Uint8Array.from(Buffer.from('d4:infodee')).buffer,storage=new Map([['picked',bytes]]),handles=new Map();let id=0,closed=0,destroyed=0,requests=0,response=bytes,code=200;
 const filesystem={OpenMode:{CREATE:1,READ_WRITE:2,READ_ONLY:4},accessSync:p=>storage.has(p),openSync:(p,mode)=>{handles.set(++id,p);if(mode&1)storage.set(p,new ArrayBuffer(0));return{fd:id}},closeSync:()=>closed++,statSync:fd=>({size:storage.get(handles.get(fd)).byteLength}),readSync:(fd,b)=>{new Uint8Array(b).set(new Uint8Array(storage.get(handles.get(fd))));return b.byteLength},writeSync:(fd,b,o)=>{const n=Math.min(3,b.byteLength),p=handles.get(fd),out=new Uint8Array(o.offset+n);out.set(new Uint8Array(storage.get(p)));out.set(new Uint8Array(b,0,n),o.offset);storage.set(p,out.buffer);return n},unlinkSync:p=>storage.delete(p)};
 const api={RequestMethod:{GET:'GET'},HttpDataType:{ARRAY_BUFFER:2},createHttp:()=>({request:async(url,o)=>{requests++;assert(o.maxLimit===16777216&&o.readTimeout===20000);return{responseCode:code,result:response}},destroy:()=>destroyed++})};
 let uuid=0;const imports=load('model/TorrentImport.ets',{'@ohos.file.fs':{default:filesystem},'@ohos.net.http':{default:api},'@ohos.util':{default:{generateRandomUUID:()=>String(++uuid)}}});
 for(const u of ['file:///x','ftp://host/a','https://u:p@host/a','https://host/\na','magnet:?xt=x','https:///x'])assert.throws(()=>imports.torrentUrl(u));
 assert.equal(imports.torrentUrl(' https://example.test/download?id=7 '),'https://example.test/download?id=7');
 assert.throws(()=>imports.checkTorrentBytes(new ArrayBuffer(0)));assert.throws(()=>imports.checkTorrentBytes(new ArrayBuffer(imports.MAX_TORRENT_BYTES+1)));assert.throws(()=>imports.checkTorrentBytes(Uint8Array.from(Buffer.from('<html>')).buffer));
 const service=new imports.TorrentImport('/download');const picked=service.fromFile('picked');assert.deepEqual(Buffer.from(storage.get('/download/'+picked)),Buffer.from(bytes));
 service.release('picked');assert(storage.has('picked'));service.release(picked);assert(!storage.has('/download/'+picked));assert(storage.has('picked'));
 const imported=await service.fromUrl('https://example.test/a.torrent');service.release(imported);assert.equal(destroyed,1);
 code=404;await assert.rejects(service.fromUrl('https://example.test/missing'));assert.equal(destroyed,2);
 code=200;response=Uint8Array.from(Buffer.from('<html>')).buffer;await assert.rejects(service.fromUrl('http://example.test/login'));assert.equal(destroyed,3);
 await assert.rejects(service.fromUrl('file:///no'));assert.equal(requests,3);assert(closed>=2);
 const state=new Map(),saved=new Map([['themeMode','dark']]),modes=[];let failFlush=false;
 const theme=load('model/ThemeService.ets',{'@ohos.app.ability.ConfigurationConstant':{default:{ColorMode:{COLOR_MODE_DARK:0,COLOR_MODE_LIGHT:1,COLOR_MODE_NOT_SET:-1}}},'@ohos.data.preferences':{default:{getPreferences:async()=>({get:async(k,d)=>saved.get(k)??d,put:async(k,v)=>saved.set(k,v),flush:async()=>{if(failFlush)throw Error('disk')}})}}},{AppStorage:{setOrCreate:(k,v)=>state.set(k,v),get:k=>state.get(k)}});
 await theme.themeService.initialize({getApplicationContext:()=>({setColorMode:m=>modes.push(m)})});assert.equal(state.get('btmobileTheme'),'dark');
 await Promise.all([theme.themeService.set('light'),theme.themeService.set('system')]);assert.equal(saved.get('themeMode'),'system');assert.equal(modes.at(-1),-1);
 failFlush=true;await assert.rejects(theme.themeService.set('dark'));assert.equal(state.get('btmobileTheme'),'system');assert.equal(saved.get('themeMode'),'system');failFlush=false;
 assert.equal(theme.validTheme('unexpected'),'system');
 let reject;const stale=new Promise((_,no)=>{reject=no}),errors=[];
 const details=method('refreshDetails','setAllowBackground(',{files:()=>stale,call:async()=>({}),peers:async()=>[]});
 const page={selectedTask:'old',detailPolling:false,extracting:false,lastDetailError:'',fail:e=>errors.push(e)};
 const reading=details.call(page);page.selectedTask='';reject(Error('torrent handle was removed'));await reading;assert.equal(errors.length,0);assert.equal(page.detailPolling,false);
 let selectedAtRemoval='';const removal=method('removeTask','confirmDeleteTask(',{call:async()=>{selectedAtRemoval=page.selectedTask},promptAction:{showToast:()=>{}}});
 Object.assign(page,{selectedTask:'old',removeTaskId:'old',refresh:async()=>{},list:()=>{}});await removal.call(page,true);assert.equal(selectedAtRemoval,'');
 assert(source.includes('if (!this.ready && this.status)'));assert(!source.includes('this.status = (e as Error).message'));
 assert(source.includes('await this.subscriptions.addTask(source)'));assert(!source.includes("op: 'add'"));
 assert(source.includes("fileSuffixFilters: ['Torrent 种子文件|.torrent']"));
 assert(source.includes("this.beginAdd('magnet')")&&source.includes("this.beginAdd('url')")&&source.includes("this.beginAdd('file')"));
 const settings=fs.readFileSync(path.join(root,'ets/components/SettingsPanel.ets'),'utf8');assert(settings.indexOf('ThemeSettings()')<settings.indexOf("Text('下载完成通知')"));
 const base=JSON.parse(fs.readFileSync(path.join(root,'resources/base/element/color.json'))).color,dark=JSON.parse(fs.readFileSync(path.join(root,'resources/dark/element/color.json'))).color;assert.deepEqual(base.map(x=>x.name).sort(),dark.map(x=>x.name).sort());
 assert(source.includes("part.link ? $r('app.color.link') : $r('app.color.text_primary')"));
 const back=fs.readFileSync(path.join(root,'resources/base/media/nav_back.svg'),'utf8');assert(back.includes('0Z')&&!back.includes('stroke='));
 const prior=path.resolve(__dirname,'../../harmony-v104/entry/src/main');
 if(fs.existsSync(prior)){
  for(const f of ['ets/components/Player.ets','ets/components/ImageViewer.ets','ets/model/BackgroundTransfer.ets','ets/model/SubscriptionService.ets','ets/model/SubscriptionVault.ets','cpp/archive_engine.cpp']){
   if(fs.existsSync(path.join(prior,f)))assert(fs.readFileSync(path.join(prior,f)).equals(fs.readFileSync(path.join(root,f))),f+' must stay unchanged');
  }
  assert.equal(fs.readFileSync(path.join(root,'cpp/bridge.cpp'),'utf8'),fs.readFileSync(path.join(prior,'cpp/bridge.cpp'),'utf8').replaceAll('1.0.4','1.0.6').replaceAll('HT1040','HT1060'));
 }
 console.log('PASS V1.0.5: bounded HTTP/file import, invalid responses, partial writes, owned-only cleanup, theme persistence/rollback/system mode, stale deletion race, shared admission and preserved stable services.');
})().catch(e=>{console.error(e);process.exitCode=1});
