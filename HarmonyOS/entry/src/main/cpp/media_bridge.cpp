#include "media_output.hpp"
#include "media_probe.hpp"
#include <napi/native_api.h>
#include <hilog/log.h>
using btmmedia::Json;
static std::mutex playerMutex;
static std::unique_ptr<btmmedia::Engine> player;
static int serial=0;
static Json command(const Json& request) {
    std::string op=request.at("op");
    if(op=="probe")return btmmedia::MediaProbe().run(request.value("fd",-1),request.value("url",std::string()));
    std::lock_guard<std::mutex> lock(playerMutex);
    if(op=="start"){
        player.reset();++serial;
        auto surface=request.at("surface").get<std::string>();
        if(surface.empty()||surface.find_first_not_of("0123456789")!=surface.npos)throw std::runtime_error("视频窗口编号无效");
        player=std::make_unique<btmmedia::Engine>(std::make_unique<btmmedia::HarmonyOutput>(std::stoull(surface)),request.value("fd",-1),request.value("url",std::string()));
        player->start();OH_LOG_Print(LOG_APP,LOG_INFO,0x1202,"BTMobilePlayer","AV1 dav1d fallback started");return {{"token",serial}};
    }
    if(request.value("token",-1)!=serial||!player)return {{"stale",true}};
    if(op=="close"){player.reset();return {{"ok",true}};}
    if(op=="pause")player->pause(true);
    else if(op=="play")player->pause(false);
    else if(op=="seek")player->seek(request.at("position").get<int64_t>());
    else if(op=="track")player->selectTrack(request.at("track").get<int>());
    else if(op=="subtitleOff")player->selectTrack(-2);
    else if(op!="status")throw std::runtime_error("未知播放器操作");
    auto status=player->status();
    static int loggedErrorSerial=-1,loggedFrameSerial=-1;
    if(status["error"]!=""&&loggedErrorSerial!=serial){loggedErrorSerial=serial;OH_LOG_Print(LOG_APP,LOG_ERROR,0x1202,"BTMobilePlayer","AV1 output failed: %{public}s",status["error"].get<std::string>().c_str());}
    if(status["renderedFrames"].get<int64_t>()>0&&loggedFrameSerial!=serial){loggedFrameSerial=serial;OH_LOG_Print(LOG_APP,LOG_INFO,0x1202,"BTMobilePlayer","AV1 decoded and presented first frame");}
    return status;
}
struct Work {napi_async_work work; napi_deferred deferred;std::string request,result,error;};
static napi_value Invoke(napi_env env,napi_callback_info info) {
    napi_value args[1];size_t argc=1;napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    napi_valuetype type;if(argc!=1||napi_typeof(env,args[0],&type)!=napi_ok||type!=napi_string){napi_throw_type_error(env,nullptr,"JSON required");return nullptr;}
    size_t length=0;napi_get_value_string_utf8(env,args[0],nullptr,0,&length);if(length>16384){napi_throw_range_error(env,nullptr,"Request too large");return nullptr;}
    auto w=new Work();w->request.resize(length+1);napi_get_value_string_utf8(env,args[0],w->request.data(),length+1,&length);w->request.resize(length);
    napi_value promise,name;napi_create_promise(env,&w->deferred,&promise);napi_create_string_utf8(env,"AV1Player",NAPI_AUTO_LENGTH,&name);
    napi_create_async_work(env,nullptr,name,[](napi_env,void* data){auto w=static_cast<Work*>(data);try{w->result=command(Json::parse(w->request)).dump();}catch(const std::exception& e){w->error=e.what();}},[](napi_env env,napi_status status,void* data){
        auto w=static_cast<Work*>(data);napi_value value;
        if(status!=napi_ok||!w->error.empty()){napi_value text;napi_create_string_utf8(env,w->error.empty()?"播放操作取消":w->error.c_str(),NAPI_AUTO_LENGTH,&text);napi_create_error(env,nullptr,text,&value);napi_reject_deferred(env,w->deferred,value);}
        else{napi_create_string_utf8(env,w->result.c_str(),w->result.size(),&value);napi_resolve_deferred(env,w->deferred,value);}
        napi_delete_async_work(env,w->work);delete w;
    },w,&w->work);napi_queue_async_work(env,w->work);return promise;
}
static napi_value Init(napi_env env,napi_value exports){napi_property_descriptor d={"invoke",nullptr,Invoke,nullptr,nullptr,nullptr,napi_default,nullptr};napi_define_properties(env,exports,1,&d);return exports;}
static napi_module module={1,0,nullptr,Init,"btmedia",nullptr,{0}};
extern "C" __attribute__((constructor)) void RegisterBTMedia(){napi_module_register(&module);}
