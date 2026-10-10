// Source/model checks only; these do not replace ArkUI compilation or device tests.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2]);
const sdkLoader = path.resolve(path.dirname(process.argv[2]), '../../..');
const options = JSON.parse(fs.readFileSync(path.join(sdkLoader,'tsconfig.json'),'utf8')).compilerOptions;
options.ets.components.push('TaskCard', 'SettingsPanel', 'Player');
const root = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const files = ['model/Native.ets', 'components/TaskCard.ets', 'components/SettingsPanel.ets', 'pages/Index.ets', 'entryability/EntryAbility.ets'];
for (const relative of files) {
  const text = fs.readFileSync(path.join(root,relative),'utf8');
  const parsed = ts.createSourceFile(relative,text,ts.ScriptTarget.Latest,true,ts.ScriptKind.ETS,options);
  const diagnostics = parsed.parseDiagnostics;
  assert.equal(diagnostics.length,0,relative + ': ' + diagnostics.map(x=>ts.flattenDiagnosticMessageText(x.messageText,'\n')).join('\n'));
}
const source = fs.readFileSync(path.join(root,'model/Native.ets'),'utf8');
const code = ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}}).outputText;
const sandbox = { exports:{}, Observed: value=>value, require: name=>({invoke:async()=>'{"ok":true}'}) };
vm.runInNewContext(code,sandbox);
const TaskState = sandbox.exports.TaskState;
const row = new TaskState();
const first = {id:'unchanged-id',name:'fixture',progress:0.29,done:29,total:100,checking:false,checkProgress:1,download:1000,upload:200,peers:0,paused:false,active:true,state:'下载中',error:''};
row.update(first);
const identity = row;
row.update({...first,progress:0.47,done:47,download:90000,upload:10000,peers:6});
assert.equal(row,identity); assert.equal(row.progress,0.47); assert.equal(row.download,90000); assert.equal(row.upload,10000); assert.equal(row.peers,6);
const index = fs.readFileSync(path.join(root,'pages/Index.ets'),'utf8');
assert(index.includes('row.update(value)'));
assert(index.includes('.swipeAction({ end: this.swipeRemove.bind(this, task.id) })'));
assert(index.includes("deleteData: deleteData"));
assert(index.includes('finally { this.extracting = false; }'));
assert(!index.includes('await this.syncBackground()'));
assert(fs.readFileSync(path.join(root,'components/TaskCard.ets'),'utf8').includes('@ObjectLink task: TaskState'));
console.log('PASS: 5 ArkTS files parsed; same-ID task model updates progress/rates/peers; swipe/removal/retry source invariants. Not a full UI build.');
