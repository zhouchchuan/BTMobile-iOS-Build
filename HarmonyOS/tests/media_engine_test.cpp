#include "../entry/src/main/cpp/media_engine.hpp"
#include <fcntl.h>
#include <iostream>
using namespace btmmedia;
struct Counters {std::atomic<int> frames{0},nonzeroAudio{0};std::atomic<int64_t> lastPts{AV_NOPTS_VALUE};};
class Headless final:public Output {
    Counters& counters;std::thread sound;std::atomic<bool> stop{false};
public:
    explicit Headless(Counters& c):counters(c){}
    void initVideo()override{}
    void draw(AVFrame* f)override{if(f->width<=0||!f->data[0])throw std::runtime_error("empty video frame");counters.lastPts=f->best_effort_timestamp;++counters.frames;}
    void closeVideo()override{}
    void startAudio(std::function<void(void*,int)> fill,std::function<void()>)override{
        sound=std::thread([this,fill]{uint8_t buffer[3840];while(!stop){fill(buffer,sizeof buffer);if(std::any_of(std::begin(buffer),std::end(buffer),[](uint8_t c){return c!=0;}))++counters.nonzeroAudio;std::this_thread::sleep_for(std::chrono::milliseconds(20));}});
    }
    void stopAudio()override{stop=true;if(sound.joinable())sound.join();}
};
void check(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
template<class Predicate> Json waitFor(Engine& engine,Predicate ok,int ms=12000){auto end=monotonicMs()+ms;Json s;do{s=engine.status();if(!s["error"].get<std::string>().empty())throw std::runtime_error(s["error"].get<std::string>());if(ok(s))return s;std::this_thread::sleep_for(std::chrono::milliseconds(20));}while(monotonicMs()<end);throw std::runtime_error("timeout: "+s.dump());}
int main(int argc,char** argv){try{
    check(argc>=3,"fixture and mode required");Counters counters;int fd=open(argv[1],O_RDONLY);check(fd>=0,"open fixture");
    Engine engine(std::make_unique<Headless>(counters),fd,"");close(fd);engine.start();
    std::string mode=argv[2];
    if(mode=="reject") {auto end=monotonicMs()+4000;while(engine.status()["error"]==""&&monotonicMs()<end)std::this_thread::sleep_for(std::chrono::milliseconds(20));check(engine.status()["error"]!="","non-AV1 must be rejected");engine.stop();std::cout<<"PASS reject non-AV1 fallback\n";return 0;}
    waitFor(engine,[&](const Json& s){return s["ready"].get<bool>()&&counters.frames>=3&&s["position"].get<double>()>=200;});
    if(mode!="silent")check(counters.nonzeroAudio>0,"real decoded audio must be emitted");
    engine.pause(true);std::this_thread::sleep_for(std::chrono::milliseconds(80));double before=engine.status()["position"];
    std::this_thread::sleep_for(std::chrono::milliseconds(200));check(std::abs(engine.status()["position"].get<double>()-before)<40,"pause freezes timeline");
    int frameCount=counters.frames;engine.seek(1500);
    waitFor(engine,[&](const Json& s){return counters.frames>frameCount&&s["position"].get<double>()>=1490;});
    check(!engine.status()["playing"].get<bool>(),"seek preserves pause");
    if(mode=="seek10") {
        int previousTarget=1500;
        for(int target:{2000,12000,22000,12000}) {
            int rendered=counters.frames;int64_t pts=counters.lastPts;
            engine.seek(target);
            waitFor(engine,[&](const Json& s){return counters.frames>rendered&&std::abs(s["position"].get<double>()-target)<40;});
            check(!engine.status()["playing"].get<bool>(),"ten-second seek must preserve pause");
            check(target>previousTarget?counters.lastPts>pts:counters.lastPts<pts,"presented picture timestamp must really move with seek");
            previousTarget=target;
        }
        engine.pause(false);waitFor(engine,[](const Json& s){return s["position"].get<double>()>12100;});
        int rendered=counters.frames;engine.seek(22000);
        waitFor(engine,[&](const Json& s){return counters.frames>rendered&&s["position"].get<double>()>=21990;});
        check(engine.status()["playing"].get<bool>(),"seek while playing must keep playing");
        engine.stop();std::cout<<"PASS AV1 forward/backward 10s changes presented frame PTS, repeated seeks, paused/playing\n";return 0;
    }
    if(mode=="tracks") {
        auto ts=engine.status()["tracks"];int audio=-1,sub=-1;for(auto const& t:ts){if(t["track_type"]==0)audio=t["track_index"];if(t["track_type"]==2)sub=t["track_index"];}
        check(audio>=0&&sub>=0,"audio and subtitle tracks exposed");engine.selectTrack(audio);
        waitFor(engine,[&](const Json& s){return s["audioTrack"]==audio;});engine.selectTrack(sub);
        waitFor(engine,[&](const Json& s){return s["subtitleTrack"]==sub;});
    }
    engine.pause(false);waitFor(engine,[](const Json& s){return s["complete"].get<bool>();});
    check(counters.frames>=5,"real video decoded after seek");engine.stop();
    std::cout<<"PASS AV1 "<<mode<<" decoded frames="<<counters.frames<<" audio callbacks="<<counters.nonzeroAudio<<" pause/seek/EOF/cleanup\n";
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
