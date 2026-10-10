#pragma once
// AV1-only fallback. It owns no torrent/session state and never writes media files.
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}
#include <nlohmann/json.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <regex>
#include <stdexcept>
#include <thread>
#include <vector>
#include <unistd.h>
#include <sys/stat.h>

namespace btmmedia {
using Json = nlohmann::json;
inline int64_t monotonicMs() { return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
inline std::string ffError(int value) { char text[AV_ERROR_MAX_STRING_SIZE]; av_strerror(value,text,sizeof text); return text; }
inline void requireFF(int value, const char* message) { if(value<0) throw std::runtime_error(std::string(message)+": "+ffError(value)); }
struct FrameFree { void operator()(AVFrame* f) const { av_frame_free(&f); } };
using Frame = std::unique_ptr<AVFrame,FrameFree>;
struct VideoFrame { Frame frame; double pts; int generation; };
struct AudioBlock { std::vector<uint8_t> data; size_t offset=0; double pts=0; };
struct Caption { double from=0,to=0; std::string text; };

class Output {
public:
    virtual ~Output() = default;
    virtual void initVideo() = 0; // Called and released exclusively on render thread.
    virtual void draw(AVFrame* frame) = 0;
    virtual void closeVideo() = 0;
    virtual void startAudio(std::function<void(void*,int)> fill, std::function<void()> interrupt) = 0;
    virtual void stopAudio() = 0;
};

class Engine {
    std::unique_ptr<Output> output;
    std::thread decoderThread,renderThread;
    std::atomic<bool> stopped{false},paused{false},eof{false},hasAudio{false},loaded{false},renderReady{false};
    std::atomic<int64_t> requestedSeek{-1};
    std::atomic<int> requestedTrack{-1};
    std::atomic<int> videoWidth{0},videoHeight{0};
    std::atomic<double> position{0},duration{0};
    std::atomic<int64_t> lastFrameAt{0},lastAudioAt{0};
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<VideoFrame> video;
    std::deque<AudioBlock> audio;
    std::deque<Caption> captions;
    size_t audioBytes=0,videoBytes=0;
    int generation=0;
    std::string error,warning;
    Json tracks=Json::array();
    std::atomic<int> audioTrack{-1},subtitleTrack{-1};
    int fd=-1;
    int64_t fileOffset=0,fileSize=0;
    std::string url;
    std::atomic<int64_t> ioDeadline{0};
    double seekFloor=0;

    static int readFd(void* opaque,uint8_t* data,int length) {
        auto& e=*static_cast<Engine*>(opaque);
        if(e.stopped) return AVERROR_EXIT;
        ssize_t count=pread(e.fd,data,length,e.fileOffset);
        if(count<0) return AVERROR(errno);
        e.fileOffset+=count; return count ? static_cast<int>(count) : AVERROR_EOF;
    }
    static int64_t seekFd(void* opaque,int64_t offset,int whence) {
        auto& e=*static_cast<Engine*>(opaque);
        if(whence==AVSEEK_SIZE) return e.fileSize;
        whence &= ~AVSEEK_FORCE;
        int64_t next=whence==SEEK_SET ? offset : whence==SEEK_CUR ? e.fileOffset+offset : whence==SEEK_END ? e.fileSize+offset : -1;
        if(next<0 || next>e.fileSize) return AVERROR(EINVAL);
        return e.fileOffset=next;
    }
    static int interrupted(void* opaque) {
        auto& e=*static_cast<Engine*>(opaque);
        return e.stopped || (e.ioDeadline>0 && monotonicMs()>e.ioDeadline);
    }
    void fail(const std::string& value) { std::lock_guard<std::mutex> lock(mutex); error=value; paused=true; wake.notify_all(); }
    AVCodecContext* openDecoder(AVStream* stream,bool av1=false) {
        const AVCodec* codec=av1 ? avcodec_find_decoder_by_name("libdav1d") : avcodec_find_decoder(stream->codecpar->codec_id);
        if(!codec) throw std::runtime_error("兼容播放器暂不支持此轨道编码");
        AVCodecContext* context=avcodec_alloc_context3(codec);
        if(!context) throw std::bad_alloc();
        try {
            requireFF(avcodec_parameters_to_context(context,stream->codecpar),"读取轨道参数失败");
            context->thread_count=std::clamp(static_cast<int>(std::thread::hardware_concurrency()),2,6);
            requireFF(avcodec_open2(context,codec,nullptr),"解码器启动失败");
            return context;
        } catch(...) {avcodec_free_context(&context);throw;}
    }
    double timestamp(int64_t pts,AVStream* stream,double origin,double fallback) {
        return pts==AV_NOPTS_VALUE ? fallback : pts*av_q2d(stream->time_base)-origin;
    }
    void clearQueues(double target) {
        std::lock_guard<std::mutex> lock(mutex);
        ++generation; video.clear(); audio.clear(); captions.clear(); audioBytes=0; videoBytes=0;
        position=target; lastFrameAt=0; lastAudioAt=0; eof=false; seekFloor=target;
        wake.notify_all();
    }
    static std::string subtitleText(const AVSubtitle& sub) {
        std::string text;
        for(unsigned i=0;i<sub.num_rects;++i) {
            auto r=sub.rects[i]; std::string line;
            if(r->text) line=r->text;
            else if(r->ass) {
                line=r->ass; size_t start=0;
                for(int n=0;n<8;++n) {auto comma=line.find(',',start);if(comma==line.npos)break;start=comma+1;}
                line=line.substr(start);
                line=std::regex_replace(line,std::regex("\\{[^}]*\\}"),"");
                line=std::regex_replace(line,std::regex("\\\\[Nn]"),"\n");
            }
            if(!text.empty()&&!line.empty())text+='\n'; text+=line;
        }
        return text;
    }
    void decode() {
        AVFormatContext* format=avformat_alloc_context();
        AVIOContext* io=nullptr;
        AVCodecContext *vcodec=nullptr,*acodec=nullptr,*scodec=nullptr;
        SwrContext* swr=nullptr;
        AVPacket* packet=av_packet_alloc();
        Frame frame(av_frame_alloc());
        int vi=-1,ai=-1,si=-1;
        double origin=0,videoNext=0,audioNext=0;
        try {
            if(!format||!packet||!frame)throw std::bad_alloc();
            format->interrupt_callback={interrupted,this}; ioDeadline=monotonicMs()+20000;
            if(fd>=0) {
                auto buffer=static_cast<uint8_t*>(av_malloc(65536));
                if(!buffer)throw std::bad_alloc();
                io=avio_alloc_context(buffer,65536,0,this,readFd,nullptr,seekFd);
                if(!io){av_free(buffer);throw std::bad_alloc();}
                format->pb=io;format->flags|=AVFMT_FLAG_CUSTOM_IO;
            }
            AVDictionary* options=nullptr;
            av_dict_set(&options,"protocol_whitelist",fd>=0 ? "file" : "http,tcp",0);
            av_dict_set(&options,"probesize","8388608",0);
            av_dict_set(&options,"analyzeduration","8000000",0);
            int opened=avformat_open_input(&format,fd>=0?nullptr:url.c_str(),nullptr,&options); av_dict_free(&options);
            requireFF(opened,"无法打开视频");
            requireFF(avformat_find_stream_info(format,nullptr),"无法读取视频轨道");
            vi=av_find_best_stream(format,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0);
            if(vi<0||format->streams[vi]->codecpar->codec_id!=AV_CODEC_ID_AV1)
                throw std::runtime_error("兼容解码仅用于 AV1；此文件并非 AV1 视频");
            vcodec=openDecoder(format->streams[vi],true);
            videoWidth=vcodec->width;videoHeight=vcodec->height;
            origin=format->start_time==AV_NOPTS_VALUE?0:double(format->start_time)/AV_TIME_BASE;
            duration=format->duration==AV_NOPTS_VALUE?0:double(format->duration)/AV_TIME_BASE;
            ai=av_find_best_stream(format,AVMEDIA_TYPE_AUDIO,-1,vi,nullptr,0);
            if(ai>=0) {
                try {acodec=openDecoder(format->streams[ai]);}
                catch(const std::exception& e){std::lock_guard<std::mutex> lock(mutex);warning=std::string("音轨不可用：")+e.what();ai=-1;}
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                for(unsigned i=0;i<format->nb_streams;++i) {
                    auto s=format->streams[i];auto type=s->codecpar->codec_type;
                    if(type!=AVMEDIA_TYPE_AUDIO && type!=AVMEDIA_TYPE_SUBTITLE)continue;
                    auto lang=av_dict_get(s->metadata,"language",nullptr,0);
                    tracks.push_back({{"track_index",i},{"track_type",type==AVMEDIA_TYPE_AUDIO?0:2},{"language",lang?lang->value:""},{"codec_mime",avcodec_get_name(s->codecpar->codec_id)}});
                }
            }
            audioTrack=ai; hasAudio=ai>=0; loaded=true; ioDeadline=0;
            wake.notify_all();
            auto receiveVideo=[&] {
                for(;;) {
                    int result=avcodec_receive_frame(vcodec,frame.get());
                    if(result==AVERROR(EAGAIN)||result==AVERROR_EOF)break;
                    requireFF(result,"AV1 解码失败");
                    videoWidth=frame->width;videoHeight=frame->height;
                    double pts=timestamp(frame->best_effort_timestamp,format->streams[vi],origin,videoNext);
                    auto rate=av_guess_frame_rate(format,format->streams[vi],frame.get());
                    videoNext=pts+(rate.num>0?av_q2d(av_inv_q(rate)):1.0/30);
                    if(pts+0.03<seekFloor) {av_frame_unref(frame.get());continue;}
                    Frame clone(av_frame_clone(frame.get()));if(!clone)throw std::bad_alloc();
                    size_t size=size_t(frame->width)*frame->height*4;
                    std::unique_lock<std::mutex> lock(mutex);
                    wake.wait(lock,[&]{return stopped || requestedSeek>=0 || (video.size()<12 && videoBytes<192*1024*1024);});
                    if(stopped||requestedSeek>=0){av_frame_unref(frame.get());break;}
                    videoBytes+=size;video.push_back({std::move(clone),pts,generation});
                    av_frame_unref(frame.get());wake.notify_all();
                }
            };
            auto receiveAudio=[&] {
                if(!acodec)return;
                for(;;) {
                    int result=avcodec_receive_frame(acodec,frame.get());
                    if(result==AVERROR(EAGAIN)||result==AVERROR_EOF)break;
                    requireFF(result,"音频解码失败");
                    if(!swr) {
                        AVChannelLayout stereo=AV_CHANNEL_LAYOUT_STEREO;
                        requireFF(swr_alloc_set_opts2(&swr,&stereo,AV_SAMPLE_FMT_S16,48000,&frame->ch_layout,static_cast<AVSampleFormat>(frame->format),frame->sample_rate,0,nullptr),"音频重采样初始化失败");
                        requireFF(swr_init(swr),"音频重采样初始化失败");
                    }
                    double pts=timestamp(frame->best_effort_timestamp,format->streams[ai],origin,audioNext);
                    int count=swr_get_out_samples(swr,frame->nb_samples);
                    if(count<0||count>480000)throw std::runtime_error("异常的音频帧长度");
                    AudioBlock block;block.data.resize(size_t(count)*4);block.pts=pts;
                    uint8_t* dest=block.data.data();
                    count=swr_convert(swr,&dest,count,const_cast<const uint8_t**>(frame->extended_data),frame->nb_samples);
                    requireFF(count,"音频转换失败");block.data.resize(size_t(count)*4);audioNext=pts+double(count)/48000;
                    if(audioNext<seekFloor){av_frame_unref(frame.get());continue;}
                    if(pts<seekFloor)block.offset=std::min(block.data.size(),size_t((seekFloor-pts)*48000)*4);
                    std::unique_lock<std::mutex> lock(mutex);
                    wake.wait(lock,[&]{return stopped||requestedSeek>=0||audioBytes<48000*4*2;});
                    if(stopped||requestedSeek>=0){av_frame_unref(frame.get());break;}
                    audioBytes+=block.data.size()-block.offset;audio.push_back(std::move(block));
                    av_frame_unref(frame.get());wake.notify_all();
                }
            };
            while(!stopped) {
                int track=requestedTrack.exchange(-1);
                if(track==-2) {avcodec_free_context(&scodec);si=-1;subtitleTrack=-1;std::lock_guard<std::mutex> lock(mutex);captions.clear();}
                if(track>=0&&track<int(format->nb_streams)) {
                    auto s=format->streams[track];
                    if(s->codecpar->codec_type==AVMEDIA_TYPE_AUDIO) {
                        auto next=openDecoder(s);avcodec_free_context(&acodec);acodec=next;ai=track;audioTrack=ai;hasAudio=true;swr_free(&swr);
                    } else if(s->codecpar->codec_type==AVMEDIA_TYPE_SUBTITLE) {
                        auto next=openDecoder(s);avcodec_free_context(&scodec);scodec=next;si=track;subtitleTrack=si;
                    }
                    requestedSeek=int64_t(position.load()*1000);
                }
                auto target=requestedSeek.exchange(-1);
                if(target>=0) {
                    ioDeadline=monotonicMs()+20000;
                    requireFF(avformat_seek_file(format,-1,INT64_MIN,int64_t((target/1000.0+origin)*AV_TIME_BASE),INT64_MAX,AVSEEK_FLAG_BACKWARD),"跳转失败");
                    avcodec_flush_buffers(vcodec);if(acodec)avcodec_flush_buffers(acodec);if(scodec)avcodec_flush_buffers(scodec);swr_free(&swr);
                    clearQueues(target/1000.0);videoNext=audioNext=target/1000.0;ioDeadline=0;
                }
                if(eof) {
                    std::unique_lock<std::mutex> lock(mutex);wake.wait_for(lock,std::chrono::milliseconds(50));continue;
                }
                ioDeadline=monotonicMs()+30000;
                int read=av_read_frame(format,packet);ioDeadline=0;
                if(read==AVERROR_EOF) {
                    avcodec_send_packet(vcodec,nullptr);receiveVideo();
                    if(acodec){avcodec_send_packet(acodec,nullptr);receiveAudio();}
                    eof=true;wake.notify_all();continue;
                }
                if(stopped)break; requireFF(read,"读取视频数据失败");
                if(packet->stream_index==vi) {int r=avcodec_send_packet(vcodec,packet);if(r==AVERROR(EAGAIN)){receiveVideo();r=avcodec_send_packet(vcodec,packet);}requireFF(r,"提交 AV1 帧失败");receiveVideo();}
                else if(packet->stream_index==ai&&acodec) {int r=avcodec_send_packet(acodec,packet);if(r==AVERROR(EAGAIN)){receiveAudio();r=avcodec_send_packet(acodec,packet);}requireFF(r,"提交音频帧失败");receiveAudio();}
                else if(packet->stream_index==si&&scodec) {
                    AVSubtitle sub{};int got=0;
                    if(avcodec_decode_subtitle2(scodec,&sub,&got,packet)>=0&&got) {
                        double pts=timestamp(packet->pts,format->streams[si],origin,position);
                        auto text=subtitleText(sub);
                        if(!text.empty()){std::lock_guard<std::mutex> lock(mutex);if(captions.size()<200)captions.push_back({pts+sub.start_display_time/1000.0,pts+sub.end_display_time/1000.0,text});}
                    }
                    avsubtitle_free(&sub);
                }
                av_packet_unref(packet);
            }
        } catch(const std::exception& e) {if(!stopped)fail(e.what());}
        av_packet_free(&packet);swr_free(&swr);avcodec_free_context(&vcodec);avcodec_free_context(&acodec);avcodec_free_context(&scodec);
        avformat_close_input(&format);if(io){av_freep(&io->buffer);avio_context_free(&io);}
    }
    void fillAudio(void* dest,int bytes) {
        memset(dest,0,bytes);
        if(stopped||paused||!renderReady||requestedSeek>=0)return;
        std::lock_guard<std::mutex> lock(mutex);
        int filled=0;
        while(filled<bytes&&!audio.empty()) {
            auto& block=audio.front();
            int count=std::min<size_t>(bytes-filled,block.data.size()-block.offset);
            memcpy(static_cast<uint8_t*>(dest)+filled,block.data.data()+block.offset,count);
            block.offset+=count;filled+=count;audioBytes-=count;
            position=std::max(position.load(),block.pts+double(block.offset)/192000);
            if(block.offset==block.data.size())audio.pop_front();
        }
        // Silence during starvation advances the clock so a video-filled queue can
        // drain and the demuxer can reach the next interleaved audio packet.
        if(filled>0)lastAudioAt=monotonicMs();
        if(filled<bytes && !eof)position=position.load()+double(bytes-filled)/192000;
        wake.notify_all();
    }
    void render() {
        bool audioStarted=false;
        int lastGeneration=-1;
        int64_t lastTick=monotonicMs();
        try {
            output->initVideo();
            while(!stopped) {
                std::unique_lock<std::mutex> lock(mutex);
                wake.wait_for(lock,std::chrono::milliseconds(5));
                if(!error.empty())break;
                auto now=monotonicMs();
                if(!loaded||video.empty()){lastTick=now;continue;}
                if(!renderReady) {
                    position=video.front().pts;renderReady=true;
                    if(hasAudio&&!audioStarted){lock.unlock();output->startAudio([this](void* p,int n){fillAudio(p,n);},[this]{paused=true;});audioStarted=true;lock.lock();}
                }
                bool first=lastGeneration!=generation;
                if(!hasAudio && !paused && !first)position=position.load()+double(now-lastTick)/1000;
                lastTick=now;
                if(paused&&!first)continue;
                if(!first&&video.front().pts>position+0.015)continue;
                VideoFrame item=std::move(video.front());video.pop_front();videoBytes-=size_t(item.frame->width)*item.frame->height*4;
                // Drop late pictures instead of slowing down the audio clock.
                bool late=!first && !video.empty() && item.pts<position-0.12;
                lastGeneration=generation;wake.notify_all();
                if(late)continue;
                lock.unlock();output->draw(item.frame.get());lastFrameAt=monotonicMs();
            }
        }catch(const std::exception& e){if(!stopped)fail(e.what());}
        output->stopAudio();output->closeVideo();
    }
public:
    Engine(std::unique_ptr<Output> sink,int sourceFd,std::string sourceUrl):output(std::move(sink)),url(std::move(sourceUrl)) {
        if(sourceFd>=0){fd=dup(sourceFd);struct stat st{};if(fd<0||fstat(fd,&st)||!S_ISREG(st.st_mode)){if(fd>=0)::close(fd);fd=-1;throw std::runtime_error("本地视频文件不可读");}fileSize=st.st_size;}
        else if(!std::regex_match(url,std::regex(R"(http://127\.0\.0\.1:[0-9]{1,5}/stream/[A-Za-z0-9/_-]+)")))throw std::runtime_error("兼容播放器只接受应用内本地视频");
    }
    ~Engine(){stop();if(fd>=0)::close(fd);}
    void start(){av_log_set_level(AV_LOG_ERROR);decoderThread=std::thread([this]{decode();});renderThread=std::thread([this]{render();});}
    void stop(){stopped=true;wake.notify_all();if(decoderThread.joinable())decoderThread.join();if(renderThread.joinable())renderThread.join();}
    void pause(bool value){paused=value;wake.notify_all();}
    void seek(int64_t ms){if(ms<0)ms=0;if(duration>0)ms=std::min(ms,std::max<int64_t>(0,int64_t(duration*1000)-1));requestedSeek=ms;wake.notify_all();}
    void selectTrack(int track){requestedTrack=track;requestedSeek=int64_t(position.load()*1000);wake.notify_all();}
    Json status(){
        std::lock_guard<std::mutex> lock(mutex);double pos=position;
        while(!captions.empty()&&captions.front().to<pos)captions.pop_front();
        std::string sub;for(auto const& c:captions)if(c.from<=pos&&c.to>=pos){sub=c.text;break;}
        bool complete=eof&&video.empty()&&audio.empty();
        bool waiting=!complete&&!paused&&(!renderReady||monotonicMs()-lastFrameAt>1200);
        return {{"position",std::max(0.0,pos*1000)},{"duration",duration.load()*1000},{"playing",!paused&&!complete&&error.empty()},
          {"waiting",waiting},{"complete",complete},{"error",error},{"warning",warning},{"tracks",tracks},{"subtitle",sub},
          {"ready",renderReady.load()},{"decoder","dav1d"},{"audioTrack",audioTrack.load()},{"subtitleTrack",subtitleTrack.load()},
          {"width",videoWidth.load()},{"height",videoHeight.load()}};
    }
};
} // namespace btmmedia
