// SDK declaration type-check (non-UI models); ArkUI compilation remains mandatory.
const fs=require('fs'),path=require('path'),ts=require(process.argv[2]);
const sdk=path.resolve(path.dirname(process.argv[2]),'../../../../../api');
const root=path.resolve(__dirname,'../entry/src/main/ets/model');
const names=['SubscriptionPolicy','SubscriptionVault','SubscriptionService'];
const options={strict:false,skipLibCheck:true,noEmit:true,allowNonTsExtensions:true,experimentalDecorators:true,target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.ESNext,moduleResolution:ts.ModuleResolutionKind.NodeJs};
const host=ts.createCompilerHost(options),original=host.getSourceFile.bind(host);
host.getSourceFile=(file,language,onError)=>file.endsWith('.ets')?ts.createSourceFile(file,fs.readFileSync(file,'utf8'),language,true,ts.ScriptKind.TS):original(file,language,onError);
host.resolveModuleNames=(modules,containing)=>modules.map(name=>{
 let file;if(name.startsWith('@ohos.'))file=path.join(sdk,name+'.d.ts');else if(name.startsWith('.'))file=path.resolve(path.dirname(containing),name+'.ets');
 if(file&&fs.existsSync(file))return{resolvedFileName:file,extension:file.endsWith('.ets')?ts.Extension.Ts:ts.Extension.Dts};
 return ts.resolveModuleName(name,containing,options,host).resolvedModule;
});
const program=ts.createProgram(names.map(n=>path.join(root,n+'.ets')),options,host);
const errors=ts.getPreEmitDiagnostics(program).filter(d=>d.category===ts.DiagnosticCategory.Error&&d.file&&names.some(n=>d.file.fileName.endsWith(n+'.ets'))&&!(d.code===2304&&String(d.messageText).includes('Observed')));
for(const d of errors){const p=d.file.getLineAndCharacterOfPosition(d.start);console.log(`${path.basename(d.file.fileName)}:${p.line+1}:${p.character+1} TS${d.code} ${ts.flattenDiagnosticMessageText(d.messageText,'\n')}`);}
if(errors.length)process.exitCode=1;else console.log('PASS: subscription non-UI models checked against local SDK declarations (global decorators excluded).');

