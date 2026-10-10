const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
function load(file) {
  const ctx = { exports: {}, require: () => ({}) };
  vm.createContext(ctx);
  vm.runInContext(ts.transpileModule(read(file), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText, ctx);
  return ctx.exports;
}
const policy = load('entry/src/main/ets/model/PlaybackPolicy.ets');
assert.equal(policy.relativeSeekTarget(19000, 10000, 60000), 29000);
assert.equal(policy.relativeSeekTarget(19000, -10000, 60000), 9000);
assert.equal(policy.relativeSeekTarget(2000, -10000, 60000), 0);
assert.equal(policy.relativeSeekTarget(55000, 10000, 60000), 59999);
assert.equal(policy.relativeSeekTarget(19000, 10000, 60000, 29000), 39000);
const display = load('entry/src/main/ets/model/NetworkDisplay.ets');
assert.deepEqual(JSON.parse(JSON.stringify(display.networkDisplay({listening:true,listenPort:49152,configuredPort:6882,dhtNodes:852,trackerReplies:5}))), {port:'49152',dht:'852',trackers:'5'});
assert.equal(display.networkDisplay({listening:false,listenPort:0,dhtNodes:0,trackerReplies:0}).port, '未监听');
assert.equal(display.deletionBanner('任务下载数据已删除'), '');
assert.equal(display.deletionBanner('任务已移除，但数据未能完全删除：busy'), '任务已移除，但数据未能完全删除：busy');
const player = read('entry/src/main/ets/components/Player.ets');
assert(!player.includes('roundControl('), 'Do not capture absolute timestamps or play/pause state in Builder value parameters');
assert(player.includes('this.skipBy(-10000)') && player.includes('this.skipBy(10000)'));
assert(player.includes("created.on('seekDone'"));
assert(player.includes('if (this.controls || this.trackPanel >= 0 || this.errorText.length > 0)'));
for (const icon of ['player_back10','player_forward10']) {
  assert(player.includes(`Image($r('app.media.${icon}')).width(32).height(32)\n`), 'SVG outline must not be overridden by fillColor');
  const svg = read(`entry/src/main/resources/base/media/${icon}.svg`);
  assert(!svg.includes('<text') && svg.includes('fill="none"'), 'Use vector numeral outlines, not SVG fonts');
}
// Execute the actual event methods with a native-player adapter and an AV1 adapter.
const parsed = ts.createSourceFile('Player.ts', player.replace('export struct Player', 'export class Player'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const declaration = parsed.statements.find(s => ts.isClassDeclaration(s));
const methods = declaration.members.filter(m => ['skipBy','control'].includes(m.name?.getText(parsed))).map(m => m.getText(parsed)).join('\n');
assert.equal(declaration.members.filter(m => ['skipBy','control'].includes(m.name?.getText(parsed))).length, 2);
const requests = [];
const ctx = {exports:{}, ...policy, Date, clearTimeout, hilog:{info(){}}, media:{SeekMode:{SEEK_CLOSEST:2}}, compatibility: async r => { requests.push({...r}); return {}; }};
vm.createContext(ctx);
vm.runInContext(ts.transpileModule('class Harness {'+methods+'}\nexports.Harness = Harness;', {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText, ctx);
function make(compatibilityMode) {
  const p = new ctx.exports.Harness();
  Object.assign(p, {disposed:false,playbackReady:true,errorText:'',playbackPosition:1000,duration:60000,seekTarget:-1,seekRequestedAt:0,compatibilityMode,compatToken:9,compatComplete:false,nativeState:'playing',tracks:[],selectedTracks:[],autoHide(){},async refreshCompatibility(){},player:{currentTime:19000,seek:(value,mode)=>requests.push({op:'nativeSeek',value,mode})}});
  return p;
}
(async()=>{
  const native=make(false);
  await native.skipBy(10000); assert.equal(requests.at(-1).value,29000, 'Use native currentTime at click, not stale UI time');
  await native.skipBy(10000); assert.equal(requests.at(-1).value,39000, 'Rapid taps accumulate');
  await native.skipBy(-10000); assert.equal(requests.at(-1).value,29000);
  native.seekTarget=-1;native.player.currentTime=2000;
  await native.skipBy(-10000); assert.equal(requests.at(-1).value,0);
  const av1=make(true);av1.playbackPosition=23000;
  await av1.skipBy(-10000); assert.equal(requests.at(-1).position,13000);assert.equal(requests.at(-1).token,9);
  av1.seekTarget=-1;av1.playbackPosition=59000;
  await av1.skipBy(10000);assert.equal(requests.at(-1).position,59999);
  const count=requests.length;av1.playbackReady=false;await av1.skipBy(-10000);assert.equal(requests.length,count);
  native.player.seek=()=>{throw Error('seek denied');};await native.skipBy(10000);assert.equal(native.seekTarget,-1);assert.equal(native.waiting,false);assert(native.warningText.includes('seek denied'));
  console.log('PASS V016 actual skip handlers/native+AV1 adapters, boundaries, rapid taps, failure, close visibility, icons, deletion banner, real network values');
})().catch(e=>{console.error(e);process.exitCode=1;});
