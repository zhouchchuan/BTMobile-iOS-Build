// Display-only privacy and built-in About regression checks; not device UI evidence.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert/strict'),ts=require(process.argv[2]);
const root=path.resolve(__dirname,'../entry/src/main/ets');
const read=f=>fs.readFileSync(path.join(root,f),'utf8');
function model(f){const context={exports:{}};vm.runInNewContext(ts.transpileModule(read(f),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,context);return context.exports;}
const {maskPeerEndpoint:mask}=model('model/PeerDisplay.ets');
const cases=[
 ['1.2.3.4:6881','*.*.*.4:6881'],['192.168.50.121','*.*.*.121'],['0.0.0.0:0','*.*.*.0:0'],['255.255.255.255:65535','*.*.*.255:65535'],
 ['240e:b30:21e1:3c00:ab24:921f:b6ee:7018:6881','[*:*:*:3c00:ab24:921f:b6ee:7018]:6881'],
 ['[240e:b30:21e1:3c00:ab24:921f:b6ee:7018]:6881','[*:*:*:3c00:ab24:921f:b6ee:7018]:6881'],
 ['2001:db8::1:443','[*:*:*:0:0:0:0:1]:443'],['::1:6881','[*:*:*:0:0:0:0:1]:6881'],
 ['[::]:1','[*:*:*:0:0:0:0:0]:1'],['1:2:3:4:5:6:7:8:9','[*:*:*:4:5:6:7:8]:9'],
 ['fe80::abcd%wlan0:6881','[*:*:*:0:0:0:0:abcd]:6881'],
 ['::ffff:192.168.50.121:6881','[*:*:*:0:0:ffff:*.*.*.121]:6881'],
 ['[::ffff:192.168.50.121]:6881','[*:*:*:0:0:ffff:*.*.*.121]:6881']
];
for(const [input,expected] of cases)assert.equal(mask(input),expected,input);
for(const bad of ['', 'unknown-secret', '256.0.0.1:12', '1.2.3.4:65536', '1.2.3.4:-1', '[not-an-ip]:8', '2001:db8:::1:8', '1:2:3:4:5:6:7:8:9:10'])assert(!mask(bad).includes(bad)||!bad,bad);
for(let i=0;i<256;i++)assert.equal(mask(`${i}.12.34.56:1234`),'*.*.*.56:1234');
const details=read('components/TaskDetails.ets');assert(details.includes('Text(maskPeerEndpoint(peer.address)'));
assert(details.includes("peer.address + ':'")); // keep the raw key, never collapse distinct peers
const settings=read('components/SettingsPanel.ets');assert(!settings.includes('Text(this.defaults)'));assert(settings.includes('await this.onSync()'));assert(settings.includes('refreshDefaults()'));assert(settings.includes('自定义地址'));
const index=read('pages/Index.ets');assert(index.includes("Button('关于 BTmobie').width('100%').backgroundColor('#F39A56')"));assert(index.indexOf("Button('关于 BTmobie')")>index.indexOf("Text('订阅信息')"));assert(index.includes('this.aboutBackRequest++'));
const about=read('components/AboutPanel.ets');assert(about.includes('getRawFileContentSync'));assert(!/https?:|Web\(/.test(about));assert(about.includes('this.noticeTitle = \'\'; this.noticeText = \'\''));assert(about.includes("app.color.page_background"));
const content=model('model/AboutContent.ets');assert.equal(content.LICENSE_NOTICES.length,13);assert(content.ABOUT_SECTIONS.length>=4);
for(const notice of content.LICENSE_NOTICES)for(const file of notice.files)assert(!file.includes('..')&&!file.startsWith('/'));
const prior=path.resolve(__dirname,'../../harmony-v105/entry/src/main');
if(fs.existsSync(prior)){
 for(const f of ['ets/model/SubscriptionService.ets','ets/model/SubscriptionVault.ets','ets/model/BackgroundTransfer.ets','ets/model/Native.ets','ets/components/Player.ets','ets/components/ImageViewer.ets','cpp/archive_engine.cpp']) {
  if(fs.existsSync(path.join(prior,f)))assert.equal(fs.readFileSync(path.join(root,'..',f),'utf8'),fs.readFileSync(path.join(prior,f),'utf8'),f+' must remain unchanged');
 }
 assert.equal(fs.readFileSync(path.join(root,'../cpp/bridge.cpp'),'utf8'),fs.readFileSync(path.join(prior,'cpp/bridge.cpp'),'utf8').replaceAll('1.0.5','1.0.6').replaceAll('HT1050','HT1060'));
}
console.log('PASS V1.0.6: IPv4/IPv6/mapped/scope display masking and malformed input, 256 prefix variants, raw peer keys, hidden defaults with sync preserved, built-in About and license navigation, stable services unchanged.');
